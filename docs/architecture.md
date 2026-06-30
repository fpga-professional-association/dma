# Architecture

A scatter-gather PCIe DMA engine. It moves blocks of data between **host memory**
(reached across the PCIe link) and a **local system bus**, driven by a ring of
descriptors that the host sets up in its own memory.

```
                 PCIe Hard IP (Altera)                      FPGA fabric
        ┌───────────────────────────────┐
 host   │  RX master (BAR)  ─────────────┼────► CSR slave ─────────┐
 PCIe   │                                │                         │
 link  ─┤  TX slave (TXS, Avalon-MM) ◄───┼──── HOST GMM master ◄──┐ │
        │                                │      (desc fetch +     │ │
        │  MSI / IRQ  ◄──────────────────┼──── irq               │ │
        └───────────────────────────────┘      data host side)   │ │
                                                                  │ │
   ┌──────────────────────────── pcie_dma_top ────────────────────┼─┼────────────┐
   │                                                              │ │            │
   │   ┌─────────── dma_engine_core ───────────┐                  │ │            │
   │   │  dma_csr ──ctrl/status──┐              │◄─────────────────┘ │ (CSR)      │
   │   │                         ▼              │                    │            │
   │   │   dma_descriptor_fetch ──desc──► dma_data_mover ─HOST GMM──►┘            │
   │   │            │                       │  │                                  │
   │   │            └── HOST GMM req ──► dma_arbiter ──► HOST GMM master           │
   │   │                                    │  │                                  │
   │   │                          (FIFO between read & write sides)               │
   │   │                                    │  └── SYS GMM master ──┐             │
   │   └────────────────────────────────────┘                      ▼             │
   │                                              ┌─── gmm_to_{avalon|axi4|ahb} ──┼──► system bus
   │                                              │   (selected by SYS_IF param)  │
   │                                              └───────────────────────────────┘
   └───────────────────────────────────────────────────────────────────────────┘
```

## Data flow

A descriptor selects a direction:

* **H2C** (`C_DIR=0`, host→system): read `host_addr` on the HOST port, write
  `sys_addr` on the SYS port.
* **C2H** (`C_DIR=1`, system→host): read `sys_addr` on the SYS port, write
  `host_addr` on the HOST port.

The `dma_data_mover` is direction-agnostic: it owns a *read role* and a *write
role*, each a GMM master, with a `dma_fifo` between them. A direction mux binds
the read/write roles to the HOST/SYS ports per descriptor. The read side issues
bounded bursts only when enough FIFO space is reserved; the write side drains the
FIFO, issuing bursts when enough beats are queued (or at end-of-transfer).

## Blocks

| Module                  | Role                                                            |
|-------------------------|----------------------------------------------------------------|
| `dma_pkg`               | Params, types, descriptor layout, CSR map.                     |
| `dma_csr`               | Host-facing register file; exports control, imports status/IRQ.|
| `dma_descriptor_fetch`  | Walks the host descriptor ring; decodes 32 B descriptors.      |
| `dma_data_mover`        | Read-burst → FIFO → write-burst engine; length accounting.     |
| `dma_fifo`              | Synchronous power-of-two FIFO with reserve/level signalling.   |
| `dma_arbiter`           | Shares the HOST GMM port between descriptor fetch and mover.   |
| `reset_sync`            | Optional 2-FF reset synchronizer (`RESET_SYNC=1`); see IR-1.   |
| `dma_engine_core`       | Wires the above into one core with two GMM ports + CSR.        |
| `gmm_to_avalon`         | SYS-port adapter: Avalon-MM (passthrough).                     |
| `gmm_to_axi4`           | SYS-port adapter: AXI4 master.                                 |
| `gmm_to_ahb`            | SYS-port adapter: AHB-Lite master.                             |
| `pcie_dma_top`          | Selects the SYS adapter via `SYS_IF`; exposes named bus ports. |

## Engine FSM (descriptor ring walk)

```
IDLE ──CTRL.GO──► FETCH ──desc ready──► RUN ──xfer done──► (more descrs?)
  ▲                  │ desc invalid          │                 │ yes → FETCH
  │                  └──► ERROR ◄─────────────┘ bad len/align   │ no  → DONE ──► IDLE
  └──────────────────────────── ABORT / clear ─────────────────┘
```

`DESC_COUNT` descriptors are processed starting at `{DESC_BASE_HI,DESC_BASE_LO}`.
Completion sets `STATUS.DONE` and (if enabled) raises `IRQ_DONE`. A bad
descriptor (length 0, misaligned, or `C_VALID=0`) sets `STATUS.ERROR`,
`ERR_INFO`, and raises `IRQ_ERROR`.

## Why a "GMM" internal bus

Keeping one internal Avalon-MM-pipelined master profile means the core is
verified once, and each external bus flavour is an isolated, separately
formally-verified adapter. Adding a new bus = adding one adapter.

## Clocking / CDC note

This reference runs the whole engine on one clock (`clk`), matching the common
case where the user system bus and the PCIe Hard IP application clock are the
same `coreclkout_hip`. If the SYS bus runs on a different clock, instantiate the
`gmm_to_*` adapter behind a dual-clock Avalon-MM/AXI clock-crossing bridge; the
GMM contract is designed to drop into such a bridge unchanged.
`quartus/pcie_dma_integration.sdc` provides the matching constraint template
(single-clock and the asynchronous separate-SYS-clock case), and
`quartus/pcie_dma_hw.tcl` packages the core as a Platform Designer component for
this flow (see `quartus/example/`). See **IR-2** below for the concrete CDC pattern.

## Integrator responsibilities (tracked)

The behaviours below are intrinsic to a single-clock reference IP. Each is listed
as an explicitly tracked item with a defined status so it is not lost as a
free-text aside. *Productized* items ship in-repo behind a parameter/CTRL bit and
default to the historical behaviour; *documented* items remain the integrator's
responsibility with the recommended pattern given here.

### IR-1 Reset synchronization — **productized** (optional)

`rst_n` is active-low with *synchronous deassertion*; by default it is used
directly by the flops, so the integrator must guarantee synchronous deassert per
clock domain. To productize this, `rtl/core/reset_sync.sv` provides a 2-FF
reset synchronizer (async assert, clk-synchronous deassert). Set the
`pcie_dma_top` parameter `RESET_SYNC=1` to route the core and the selected
adapter through it; `RESET_SYNC=0` (default) keeps the direct-`rst_n` datapath
bit-for-bit unchanged. The SDC `set_false_path -from [get_ports rst_n]`
(`quartus/pcie_dma.sdc`) remains correct in both modes — it covers the
asynchronous input to the first synchronizer flop; the synchronized deassertion
(removal/recovery) is then a normal timed path inside the `clk` domain.
Demonstrated by the `RESET_SYNC=1` lint pass (`scripts/lint.sh`), a `reset_sync`
gate-map target (`scripts/run_synth.sh`), and the `AVALON +rstsyn` simulation
config (`scripts/run_sim.sh`).

### IR-2 Dual-clock SYS CDC bridge — **documented** (integrator-provided)

The engine is single-clock; there is no clock-crossing bridge in-repo. If the
SYS bus runs on a clock other than `clk`, insert a dual-clock bridge **between
the GMM SYS master and the `gmm_to_*` adapter** (the adapter ports carry
`clk`/`rst_n`/`clr` precisely so it can be re-clocked as a drop-in unit):

* **Avalon-MM:** instantiate a Platform Designer *Avalon-MM Clock Crossing
  Bridge* on the SYS path; it preserves the pipelined/burst GMM contract
  (`docs/interfaces.md §1`) unchanged.
* **AXI4:** place an AXI clock-converter (e.g. an AXI register slice + async
  FIFO) on the AXI master; keep a single outstanding transaction per direction
  to match the adapter (`docs/interfaces.md §3`).
* **SDC:** declare the two clocks asynchronous with
  `set_clock_groups -asynchronous -group {clk} -group {sys_clk}` so the timer
  does not attempt to time the crossing, and constrain the bridge's own internal
  CDC per its datasheet. Do **not** widen bursts beyond `MAX_BURST_BEATS`; the
  boundary guarantee (`docs/interfaces.md §1`) keeps the bridge trivially legal.

### IR-3 Posted-write commitment fence — **documented** (integrator-provided)

A descriptor's completion (`STATUS.DONE` / IRQ) is asserted when the data mover
has handed the **last beat** to the adapter — on AXI4 this is before the `B`
response, on AHB before the final data phase fully retires. The engine does not
gate DONE on write commitment. If software must observe write *commitment* on the
SYS side (or the converse for C2H host writes via PCIe), insert a **read-back /
fence** on that bus after DONE (e.g. read any address on the target after the
completion interrupt). Note that a non-OK response arriving in this window is
still captured and turns the descriptor into `STATUS.ERROR = SYS_BUS`, so a
failed posted write is never silently dropped — only the *timing* of the DONE
edge relative to commitment is the integrator's concern.

### IR-4 Graceful stop vs hard ABORT — **productized** (graceful stop added)

`CTRL.ABORT` is a hard datapath reset that truncates an in-flight burst (error
recovery only). For an orderly stop, `CTRL.STOP` (issue #14) lets the in-flight
descriptor finish cleanly and halts the ring before the next descriptor, leaving
the FSM/FIFO coherent and restartable; `STATUS.DONE` then asserts with
`DESC_INDEX < DESC_COUNT`. Full semantics and the ABORT/STOP contrast are in
`docs/register_map.md` (*CTRL.ABORT vs CTRL.STOP*); demonstrated by sim section
"J" in `sim/tb_pcie_dma.sv` across all bus options.

### IR-5 Descriptor ring base alignment — enforced in hardware

`DESC_BASE` must be 32-byte (`DESC_BYTES`) aligned; this is enforced at GO
(`ERR_BAD_BASE`) and also guarantees descriptor fetches never cross a 4 KiB PCIe
boundary. No integrator action required beyond supplying an aligned base.

### IR-6 HOST/PCIe bus error reporting — **productized** (in hardware)

The HOST GMM port carries an optional per-beat completion status
(`host_response[1:0]`, Avalon-MM `response`) mirroring the PCIe Hard IP TXS
status. Any non-OK code on a HOST *read* beat (Unsupported Request / Completer
Abort / poisoned TLP) is captured into a sticky `host_err_latched` flop in
`dma_engine_core` — the PCIe-side parallel of `sys_err_latched`. Because the HOST
port serves both descriptor fetches and H2C data reads, the latch is re-armed at
the start of each fetch and each move, checked in `E_FETCH_WAIT` (read error →
descriptor unreliable, priority over content checks) and `E_RUN`, turning the
descriptor into `STATUS.ERROR = HOST_BUS` and asserting the top-level
`host_bus_error` output. HOST *write* completion errors (C2H) and a completion
watchdog are out of scope (the simple Avalon-MM HOST profile has no write
response); a read that never returns relies on the integrator/testbench timeout.

### IR-7 No in-band per-descriptor status writeback — by design

Descriptor bytes 24..31 are strictly reserved (must be 0); the engine never
writes completion/error status back into the host ring and never clears
`C_VALID`. Software observes completion exclusively through the global `STATUS`
register, the `REG_DESC_INDEX` completed-descriptor count, and the optional
per-descriptor `C_IRQ` interrupt.

## Verification: portable vs. optional tier (issue #3)

`sim/tb_pcie_dma.sv` runs two stimulus tiers. The **portable tier** runs under
the existing Icarus CI: the directed scenarios *plus* a constrained-random
descriptor-ring generator built on `$urandom`/`$urandom_range`. It produces long
rings (randomized depth 32–48), with per-descriptor randomized direction, legal
aligned length/offset (including 1 KiB-boundary crossers and exact max bursts),
and `C_IRQ`; it scores every transfer against a golden reference, reads back
`REG_DESC_INDEX`, exercises both count-based and `C_LAST` ring termination, and
keeps manual functional-coverage tallies (Icarus has no covergroups). The RNG is
seeded once from `+SEED=<n>` (fixed default), and the generated geometry is
independent of the selected SYS bus, so the run is deterministic and identical
across all six `run_sim.sh` configurations; `run_sim.sh` sweeps a small fixed set
of seeds (`SIM_SEEDS`, default `1 2 3`) and now exits non-zero on any failure.

The **optional tier** needs a coverage/SVA-capable simulator (Questa/VCS/Xcelium,
or Verilator with limited SVA) and is tracked as follow-up: SystemVerilog
covergroups, and factoring the `formal/fv_*` protocol checks into standalone
monitor modules `bind`-ed onto the DUT so the same assertions run on every
simulation trace. These are deliberately *not* wired into the Icarus CI job,
which cannot elaborate covergroups or concurrent SVA.
