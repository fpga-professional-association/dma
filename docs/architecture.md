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
GMM contract is designed to drop into such a bridge unchanged. See **IR-2** below
for the concrete pattern and the SDC constraints it requires.

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
"G" in `sim/tb_pcie_dma.sv` across all bus options.

### IR-5 Descriptor ring base alignment — enforced in hardware

`DESC_BASE` must be 32-byte (`DESC_BYTES`) aligned; this is enforced at GO
(`ERR_BAD_BASE`) and also guarantees descriptor fetches never cross a 4 KiB PCIe
boundary. No integrator action required beyond supplying an aligned base.
