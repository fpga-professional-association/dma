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
quartus/                      .qpf/.qsf/.sdc Quartus project; pcie_dma_hw.tcl
                              (Platform Designer component) + example/ + SDCs
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

### Platform Designer (Qsys) component

`quartus/pcie_dma_hw.tcl` packages `pcie_dma_top` as a Platform Designer
component ("PCIe Scatter-Gather DMA Engine" in the IP Catalog). It exposes the
`csr` Avalon-MM slave, the `host` Avalon-MM master (PCIe TXS), the `irq`
interrupt sender, the `sys_bus_error` conduit, and one SYS master selected by
the `SYS_IF` parameter — `sys_avm` (Avalon-MM), `sys_axi` (AXI4), or `sys_ahb`
(AHB conduit). An elaboration callback exposes exactly the SYS interface
matching `SYS_IF` and terminates the other two.

* Worked example wiring the component behind a PCIe Hard IP:
  `quartus/example/` (`pcie_dma_example.tcl` + notes).
* Integration timing template: `quartus/pcie_dma_integration.sdc` (uses the
  Hard IP application clock and covers the single-clock and separate-SYS-clock
  cases; use it instead of the standalone `pcie_dma.sdc`).

Point Platform Designer at the `quartus/` directory (or add it to the IP search
path) and the component appears in the IP Catalog. The artifacts are validated
against the RTL ports/parameters but require Quartus/Platform Designer (not part
of the open-source flow) to elaborate.

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
