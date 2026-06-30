# PCIe DMA Engine (SystemVerilog)

A scatter-gather PCIe DMA engine that moves blocks of data between **host memory**
(across the PCIe link) and a **local system bus**, driven by a ring of
descriptors set up by the host. The system-bus interface is selectable at
elaboration: **Avalon-MM**, **AXI4**, or **AHB-Lite**.

* Formally verified protocol adapters + FIFO + arbiter (SVA, runs on open-source
  yosys with no external solver).
* Cycle-accurate self-checking simulation across all three bus options, with and
  without bus back-pressure.
* Synthesizable (Verilator `-Wall` clean; Quartus project included).

```
        PCIe Hard IP                         pcie_dma_top
   ┌──────────────────┐        ┌───────────────────────────────────────┐
   │ BAR  ───RXM────────────►  │ CSR slave  ─► control / status / IRQ   │
   │ TXS  ◄──Avalon-MM──────   │ HOST master ─► descriptors + host data │
   │ MSI  ◄──irq────────────   │ SYS  master ─► Avalon-MM | AXI4 | AHB ──┼──► system bus
   └──────────────────┘        └───────────────────────────────────────┘
```

## Features

* Descriptor-ring scatter-gather (32-byte descriptors in host memory).
* Bidirectional: **H2C** (host→system) and **C2H** (system→host), per descriptor.
* Burst data mover with an elastic FIFO; bursts are bounded so they never exceed
  `MAX_BURST_BEATS` or cross a 1 KiB / 4 KiB boundary — every adapter stays
  trivially protocol-legal.
* Host-side register file (BAR): control, status, descriptor ring base/count,
  per-descriptor and ring-completion interrupts, error reporting.
* One internal "GMM" master profile (Avalon-MM pipelined) → the core is verified
  once and each external bus is an isolated, separately-verified adapter.

## Limitations

> **Whole-bus-word, aligned transfers only.** Every transfer moves data in
> complete bus words (`DATA_W/8` bytes — 8 bytes at the default `DATA_W=64`). The
> data mover drives all-ones byte-enables on every beat and converts a
> descriptor's byte `length` to whole beats, so sub-word (partial-strobe) and
> unaligned transfers cannot be expressed. The engine **rejects** any descriptor
> that would require them, before any data is moved:
>
> * `length` must be non-zero and a multiple of `DATA_W/8` — otherwise the
>   descriptor fails with `STATUS.ERROR` and `ERR_INFO = BAD_LEN (0x01)`.
> * `host_addr` and `sys_addr` must each be `DATA_W/8`-aligned — otherwise
>   `STATUS.ERROR` with `ERR_INFO = BAD_ALIGN (0x02)`.
>
> **Implication for integrators:** host and system buffers must be padded and
> aligned to `DATA_W/8` bytes. A buffer whose base or size is not a multiple of
> `DATA_W/8` cannot be DMA'd directly — round the base down / size up to a
> `DATA_W/8` boundary (ignoring the padding bytes), or stage through an aligned
> bounce buffer.
>
> **Path to byte-enable support (future work):** add first/last-beat byte-enable
> shaping in `dma_data_mover.sv`, relax the `BAD_LEN`/`BAD_ALIGN` checks in
> `dma_engine_core.sv`, and handle AHB (which has no write strobes) via narrowed
> `HSIZE` for the head/tail beats or read-modify-write. The AXI4 and Avalon
> adapters already forward `wstrb`/`byteenable`. See `docs/descriptor_format.md`,
> `docs/interfaces.md`, and `docs/register_map.md`.

## Directory layout

```
rtl/
  pkg/dma_pkg.sv              params, types, descriptor layout, CSR map
  core/                       dma_fifo, dma_arbiter, dma_csr, dma_descriptor_fetch,
                              dma_data_mover, dma_engine_core
  adapters/                   gmm_to_avalon, gmm_to_axi4, gmm_to_ahb
  top/pcie_dma_top.sv         configurable top (SYS_IF = AVALON | AXI4 | AHB)
formal/                       SVA harnesses + .sby (FIFO, arbiter, AXI4, AHB)
sim/                          self-checking testbench + Avalon/AXI/AHB memory models
quartus/                      .qpf/.qsf/.sdc Quartus project
scripts/                      run_sim.sh, lint.sh, run_synth.sh, run_formal.sh
docs/                         architecture, interfaces, register_map, descriptor_format
```

## Configuration

Select the system-bus flavour with the `SYS_IF` parameter on `pcie_dma_top`:

```systemverilog
pcie_dma_top #(.SYS_IF("AXI4")) u_dma ( ... );   // or "AVALON" / "AHB"
```

Key parameters live in `rtl/pkg/dma_pkg.sv` (`DATA_W`, `HADDR_W`, `SADDR_W`,
`MAX_BURST_BEATS`, `FIFO_DEPTH`, …).

## Build & verify (open-source tooling)

| Task                     | Command                              | Tool        |
|--------------------------|--------------------------------------|-------------|
| Lint / elaborate (×3 IF) | `./scripts/lint.sh`                  | Verilator   |
| Simulate (6 configs)     | `./scripts/run_sim.sh`               | Icarus      |
| Formal proofs            | `./scripts/run_formal.sh`            | yosys (SAT) |
| Generic gate mapping     | `./scripts/run_synth.sh`             | yosys       |

```
$ ./scripts/run_sim.sh
AVALON        : PASS
AVALON +stalls: PASS
AXI4          : PASS
AXI4   +stalls: PASS
AHB           : PASS
AHB    +stalls: PASS

$ ./scripts/run_formal.sh
fv_fifo      : PASS  (bmc depth 22)
fv_arbiter   : PASS  (bmc depth 22)
fv_axi4      : PASS  (bmc depth 22)
fv_ahb       : PASS  (bmc depth 22)
```

## Quartus (vendor synthesis)

```
cd quartus
quartus_sh --flow compile pcie_dma          # uses pcie_dma.qsf
```

Change the bus option with `set_parameter -name SYS_IF "AXI4"` in `pcie_dma.qsf`.
`pcie_dma_top` is an IP core: integrate it as a Platform Designer / Qsys
component behind the PCIe Hard IP (HOST master → TXS, CSR slave ← BAR/RXM), or
fit it standalone (the included `virtual_pins.tcl` makes the bus ports virtual).

Simulation in Questa-Intel / ModelSim-Intel: compile `rtl/` + `sim/` and run
`tb_pcie_dma` with `+define+USE_AXI` / `+define+USE_AHB` / `+define+STALLS`.

## Programming model

See `docs/register_map.md` and `docs/descriptor_format.md`. In short:

1. Build a ring of 32-byte descriptors in host memory.
2. Write `DESC_BASE_LO/HI`, `DESC_COUNT`, optionally `IRQ_ENABLE`.
3. Write `CTRL.GO`.
4. Wait for `STATUS.DONE` (or the completion IRQ); check `STATUS.ERROR`.

## Verification summary

* **Simulation** — `tb_pcie_dma` builds a 2-descriptor ring exercising H2C and
  C2H, multi-burst transfers, a 1 KiB-boundary-crossing burst, and the
  completion interrupt; self-checks both destinations. Also covers the error
  paths (invalid descriptor, bad length/alignment), `count==0`, **abort
  mid-transfer** (regression for FIFO-flush / arbiter-deadlock), and (AHB)
  **SYS bus-error reporting**. With AXI back-pressure the slave model gates
  `AWREADY` on `WVALID`, exercising the adapter's concurrent AW/W presentation.
  Passes for Avalon/AXI4/AHB with and without pseudo-random slave back-pressure.
* **Formal** — bounded proofs (BMC depth 22, yosys SAT) of FIFO ordering/data
  integrity & safety, arbiter mutual exclusion, AXI4 handshake/burst compliance,
  and AHB-Lite legality. See `formal/README.md`.
* **Synthesis** — Verilator `-Wall` clean for all three configurations; protocol
  blocks gate-map with yosys; Quartus project provided.
* **Adversarial review** — the RTL/formal/TB were put through a multi-agent
  review (7 dimensions, each finding independently verified); the confirmed
  defects — incomplete abort (FIFO/arbiter), AXI4 AW-before-W serialization,
  duplicate package compilation, SYS-bus error reporting, descriptor-base
  alignment, and the dead-code / SDC nits — have been fixed and regression-tested.
