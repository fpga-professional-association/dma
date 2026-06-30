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

## Integration notes / known limitations

* **Reset.** `rst_n` is treated as active-low and *synchronously deasserted*; it
  is used directly by the flops. In a real system synchronize it per clock
  domain with a 2-FF reset synchronizer driving `rst_n` (the SDC already
  `set_false_path`s the reset). Recovery/removal is a false path.
* **Posted writes.** A descriptor's completion (`STATUS.DONE` / IRQ) is asserted
  when the data mover has handed the last beat to the adapter, which on AXI4 is
  before the `B` response and on AHB before the final data phase fully retires.
  If software must observe write *commitment* on the SYS side (or the converse
  for C2H host writes via PCIe), insert a read-back/fence on that bus after DONE.
  A non-OK response that arrives in this window is still captured and turns the
  descriptor into `STATUS.ERROR=SYS_BUS` (so it is never silently dropped).
* **Abort** truncates an in-flight bus burst (see `docs/register_map.md`); it is
  for error recovery, not graceful stop.
* **Descriptor ring base** must be 32-byte (`DESC_BYTES`) aligned; enforced at GO
  (`ERR_BAD_BASE`). This also guarantees descriptor fetches never cross a 4 KiB
  PCIe boundary.
* **No in-band per-descriptor status writeback.** Descriptor bytes 24..31 are
  strictly reserved (must be 0); the engine never writes completion/error status
  back into the host ring and never clears `C_VALID`. Software signals/observes
  completion exclusively through the global `STATUS` register, the
  `REG_DESC_INDEX` completed-descriptor count, and the optional per-descriptor
  `C_IRQ` interrupt.
