# Platform Designer integration example

A worked example that wires the packaged `pcie_dma_top` component (see
[`../pcie_dma_hw.tcl`](../pcie_dma_hw.tcl)) into a Platform Designer / Qsys
system behind a PCIe Hard IP, demonstrating the documented drop-in topology.

```
        PCIe Hard IP                          pcie_dma_top (component)
   ┌──────────────────┐         ┌────────────────────────────────────────┐
   │ BAR ── RXM ───────────────►│ csr  (Avalon-MM slave)  control/status  │
   │ TXS ◄── Avalon-MM ─────────│ host (Avalon-MM master) desc + host data│
   │ MSI ◄── irq ───────────────│ irq  (interrupt sender)                 │
   └──────────────────┘         │ sys_avm (Avalon-MM master) ─────────────┼─► on-chip RAM
                                └────────────────────────────────────────┘
```

## Files

| File                    | Purpose                                                       |
|-------------------------|---------------------------------------------------------------|
| `pcie_dma_example.tcl`  | `qsys-script` that builds `pcie_dma_example.qsys`.            |

## Generate

The `pcie_dma_top` component must be on the IP search path first. The simplest
way is to run from this directory so `../pcie_dma_hw.tcl` is found, or add the
`quartus/` directory to `IP_SEARCH_PATHS` / `QSYS_PATH`.

```
qsys-script --script=pcie_dma_example.tcl
qsys-generate pcie_dma_example.qsys --synthesis=VERILOG
```

This emits a system with the DMA engine's `csr`, `host`, `irq`, and `sys_avm`
interfaces connected as shown above; `sys_avm` targets an on-chip RAM that
stands in for the local system bus.

## Device-specific wiring (PCIe Hard IP)

The PCIe Hard IP component name and the names of its BAR/RXM, TXS, and
MSI/interrupt interfaces are **device-family specific** (e.g.
`altera_pcie_a10_hip_avmm`, `altera_pcie_sv_hip_avmm`). In
`pcie_dma_example.tcl` the Hard IP instance and its connections are left as
clearly-marked commented templates; uncomment and rename them to match the
exact interface names your Hard IP variant reports. The DMA-side endpoints
(`dma.csr`, `dma.host`, `dma.irq`, `dma.sys_avm`) are fixed by the packaging
file and never change.

To swap the system-bus flavour, change the parameter:

```tcl
set_instance_parameter_value dma SYS_IF {AXI4}   ;# or AHB
```

When `SYS_IF` is `AXI4`, the component exposes `dma.sys_axi` (and `sys_avm` /
`sys_ahb` disappear); for `AHB` it exposes the `dma.sys_ahb` conduit. Connect
the matching interface to your system-bus fabric.

## Timing constraints

Use [`../pcie_dma_integration.sdc`](../pcie_dma_integration.sdc) (not the
standalone `../pcie_dma.sdc`) for the integrated flow. It covers both the
single-clock case and the separate-SYS-clock (dual-clock) case from
`docs/architecture.md`.
