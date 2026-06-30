# CSR Register Map

32-bit registers, word-addressed, reached by the host through a PCIe BAR.
Byte offset = word offset × 4.

| Word | Byte  | Name          | Access | Reset       | Description                                  |
|------|-------|---------------|--------|-------------|----------------------------------------------|
| 0x00 | 0x000 | CTRL          | RW     | 0           | Control                                      |
| 0x01 | 0x004 | STATUS        | RO     | 0           | Status                                       |
| 0x02 | 0x008 | DESC_BASE_LO  | RW     | 0           | Descriptor ring base, host addr [31:0]       |
| 0x03 | 0x00C | DESC_BASE_HI  | RW     | 0           | Descriptor ring base, host addr [63:32]      |
| 0x04 | 0x010 | DESC_COUNT    | RW     | 0           | Number of descriptors to process             |
| 0x05 | 0x014 | DESC_INDEX    | RO     | 0           | Count of descriptors completed               |
| 0x06 | 0x018 | IRQ_STATUS    | RW1C   | 0           | Pending IRQ flags (write 1 to clear)         |
| 0x07 | 0x01C | IRQ_ENABLE    | RW     | 0           | IRQ enable mask                              |
| 0x08 | 0x020 | ERR_INFO      | RO     | 0           | Error code (valid when STATUS.ERROR)         |
| 0x09 | 0x024 | VERSION       | RO     | 0x0D3A0101  | IP version ("DMA" v1.1)                       |
| 0x0A | 0x028 | SCRATCH       | RW     | 0           | Read/write test register                     |

## CTRL (0x00)

| Bit | Name   | Access | Description                                            |
|-----|--------|--------|--------------------------------------------------------|
| 0   | GO     | RW     | Write 1 to start processing the ring (auto-clears on accept). |
| 1   | ABORT  | RW     | Write 1 to abort/clear the engine (self-clearing).     |
| 2   | IRQ_EN | RW     | Global interrupt enable.                               |
| 31:3| —      | RO     | Reserved (0).                                          |

## STATUS (0x01)

| Bit | Name  | Description                                  |
|-----|-------|----------------------------------------------|
| 0   | BUSY  | Engine is processing the ring.               |
| 1   | DONE  | Ring completed (all DESC_COUNT done).        |
| 2   | ERROR | An error occurred (see ERR_INFO).            |
| 7:4 | STATE | Engine FSM state (debug).                    |

## IRQ_STATUS (0x06) / IRQ_ENABLE (0x07)

| Bit | Name  | Description                          |
|-----|-------|--------------------------------------|
| 0   | DONE  | Ring/descriptor completion interrupt |
| 1   | ERROR | Error interrupt                      |

`irq` output = `CTRL.IRQ_EN & |(IRQ_STATUS & IRQ_ENABLE)`.
IRQ_STATUS bits are set by hardware and cleared by writing 1 (RW1C).

## ERR_INFO (0x08)

| Code | Name       | Cause                                          |
|------|------------|------------------------------------------------|
| 0x00 | NONE       | No error                                       |
| 0x01 | BAD_LEN    | Descriptor length 0 or not a multiple of DATA_W/8 |
| 0x02 | BAD_ALIGN  | host_addr or sys_addr not DATA_W/8 aligned     |
| 0x03 | DESC_INV   | Descriptor C_VALID bit was 0                   |
| 0x04 | BAD_BASE   | DESC_BASE not DESC_BYTES (32-byte) aligned     |
| 0x05 | SYS_BUS    | SYS bus (AXI4 SLVERR/DECERR, AHB HRESP) error during the transfer |

`DESC_BASE_LO/HI` **must be 32-byte aligned** (a descriptor is 32 bytes); an
unaligned base is rejected at GO with `BAD_BASE` before any fetch is issued.

On a `SYS_BUS` error the descriptor is reported as `STATUS.ERROR` (not DONE) with
`ERR_INFO = SYS_BUS`, so software discards the affected transfer's data. The
adapter's bus error is sticky; issue `CTRL.ABORT` to clear it (and the
`sys_bus_error` output) before restarting.

## CTRL.ABORT semantics

`CTRL.ABORT` is a **hard datapath reset** for error recovery: it flushes the
data FIFO, drops any in-flight HOST/SYS bus burst, clears the engine FSM and the
sticky SYS bus error, and returns the engine to IDLE. A burst that was already
in flight on the bus is abandoned (truncated) — ABORT is not a graceful drain.
For an orderly stop, let the descriptor ring complete instead.

## Programming sequence

1. Build a ring of N descriptors in host memory (see `descriptor_format.md`).
2. Write `DESC_BASE_LO/HI` = ring physical address.
3. Write `DESC_COUNT` = N.
4. Optionally write `IRQ_ENABLE` and set `CTRL.IRQ_EN`.
5. Write `CTRL.GO = 1`.
6. Wait for `STATUS.DONE` (poll) or the `DONE` interrupt; check `STATUS.ERROR`.
7. Write 1 to `IRQ_STATUS` bits to clear, then go again for the next batch.
