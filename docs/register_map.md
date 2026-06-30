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
| 3   | STOP   | RW     | Write 1 to request a **graceful stop** (self-clearing). See below. |
| 31:4| —      | RO     | Reserved (0).                                          |

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
| 0x06 | HOST_BUS   | HOST/PCIe completion error (UR/CA/poison: `host_response != OKAY`) during a descriptor fetch or transfer |

`DESC_BASE_LO/HI` **must be 32-byte aligned** (a descriptor is 32 bytes); an
unaligned base is rejected at GO with `BAD_BASE` before any fetch is issued.

On a `SYS_BUS` error the descriptor is reported as `STATUS.ERROR` (not DONE) with
`ERR_INFO = SYS_BUS`, so software discards the affected transfer's data. The
adapter's bus error is sticky; issue `CTRL.ABORT` to clear it (and the
`sys_bus_error` output) before restarting.

A `HOST_BUS` error is the PCIe-side mirror of `SYS_BUS`: any HOST read beat that
returns a non-OK completion status (`host_response[1:0] != 00`, i.e. Unsupported
Request / Completer Abort / poisoned TLP) is captured. Because the HOST port
serves both descriptor fetches and host-side data reads, a `HOST_BUS` error can
arise during a fetch (the descriptor contents are then treated as unreliable and
the read error takes priority over the descriptor-content checks) or during an
H2C data read. The affected descriptor is reported as `STATUS.ERROR` (not DONE)
with `ERR_INFO = HOST_BUS` and surfaced on the top-level `host_bus_error` output;
issue `CTRL.ABORT` to clear it before restarting. (HOST *write* completion errors
on C2H are out of scope; the simple Avalon-MM HOST profile carries no write
response. A completion-timeout watchdog is likewise a documented follow-up.)

## CTRL.ABORT vs CTRL.STOP (hard reset vs graceful stop)

`CTRL.ABORT` is a **hard datapath reset** for error recovery: it flushes the
data FIFO, drops any in-flight HOST/SYS bus burst, clears the engine FSM and the
sticky SYS *and* HOST bus errors (clearing both `sys_bus_error` and
`host_bus_error`), and returns the engine to IDLE. A burst that was already
in flight on the bus is abandoned (truncated) — ABORT is **not** a graceful drain.

`CTRL.STOP` is the **graceful** counterpart (productized for issue #14). When the
engine is BUSY, writing `STOP=1` lets the descriptor *currently in flight* finish
cleanly — its in-flight bus burst is **not** truncated and its data integrity is
preserved — and then halts the ring **before** fetching the next descriptor,
leaving the FSM/FIFO coherent and the engine immediately restartable with `GO`.

* `STOP` is self-clearing and is only meaningful while BUSY; it is ignored if the
  engine is idle, and a fresh `GO` clears any stale request.
* A graceful stop terminates via the normal completion path: `STATUS.DONE` (and
  the DONE interrupt, if enabled) assert, with **`DESC_INDEX < DESC_COUNT`**. That
  inequality is how software distinguishes an early graceful stop from a full ring
  completion (where `DESC_INDEX == DESC_COUNT`).
* `ABORT` supersedes a pending `STOP`. If a SYS bus error occurs first, the
  descriptor reports `STATUS.ERROR` as usual and the pending stop is dropped.

Use `STOP` for an orderly quiesce (e.g. before reconfiguration); use `ABORT` only
for error recovery / forced teardown. Letting the ring run to completion remains
the simplest orderly stop when no early halt is required.

## Programming sequence

1. Build a ring of N descriptors in host memory (see `descriptor_format.md`).
2. Write `DESC_BASE_LO/HI` = ring physical address.
3. Write `DESC_COUNT` = N.
4. Optionally write `IRQ_ENABLE` and set `CTRL.IRQ_EN`.
5. Write `CTRL.GO = 1`.
6. Wait for `STATUS.DONE` (poll) or the `DONE` interrupt; check `STATUS.ERROR`.
7. Write 1 to `IRQ_STATUS` bits to clear, then go again for the next batch.
