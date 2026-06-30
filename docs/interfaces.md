# Interface Contracts

This document is the normative timing/signal contract for every bus boundary in
the design. Adapters and simulation memory models **must** conform exactly.

All ports are synchronous to a single rising-edge clock `clk` with an active-low,
synchronously-deasserted reset `rst_n`. The integrator guarantees synchronous
deassertion, or sets `pcie_dma_top` `RESET_SYNC=1` to use the built-in 2-FF
`reset_sync` (see `docs/architecture.md` IR-1). Running the SYS bus on a separate
clock requires a dual-clock bridge (IR-2).

---

## 1. Generic Memory-Mapped master interface ("GMM")

The DMA core speaks **GMM** on both its host (PCIe) port and its system port.
GMM is the **Avalon-MM pipelined, burst-capable** profile, so the GMM→Avalon
adapter is a near-passthrough while the AXI4 and AHB adapters do real protocol
translation.

### Signals (master → slave unless noted)

| Signal          | Dir | Width      | Meaning                                            |
|-----------------|-----|------------|----------------------------------------------------|
| `address`       | M→S | `AW`       | Byte address, aligned to `DATA_W/8`                |
| `read`          | M→S | 1          | Read command request                               |
| `write`         | M→S | 1          | Write command request                              |
| `writedata`     | M→S | `DATA_W`   | Write payload (one beat)                           |
| `byteenable`    | M→S | `DATA_W/8` | Active-high byte lanes for the current write beat  |
| `burstcount`    | M→S | `BCW`      | Number of beats in this burst (1..MAX_BURST_BEATS) |
| `waitrequest`   | S→M | 1          | Slave back-pressure; command/beat not accepted     |
| `readdata`      | S→M | `DATA_W`   | Read response payload (one beat)                   |
| `readdatavalid` | S→M | 1          | `readdata` is valid this cycle                     |

`read` and `write` are mutually exclusive (never both 1).

### Timing rules

**Command acceptance.** A read command, the first write beat, and every
subsequent write beat are *accepted* on a rising clock edge where
`(read | write) && !waitrequest`. While `waitrequest==1` the master holds all
command/data outputs stable.

**Read burst.** The master issues **one** read command with `burstcount = N` and
the start `address`. The slave later returns exactly `N` beats, each flagged by
`readdatavalid==1` (beats may be spaced arbitrarily; `readdata` is only valid on
the flagged cycles). Return order is strictly sequential from the start address.
The master must always be able to sink `readdatavalid` (no read back-pressure),
which the core guarantees by reserving FIFO space before issuing the command.

**Write burst.** The master asserts `write` with `burstcount = N` and the start
`address` on the first beat. It keeps `write` asserted and presents successive
`writedata`/`byteenable` for the remaining beats. `burstcount` and `address` are
held stable for the entire burst (slave auto-increments internally). Exactly `N`
beats are accepted (each when `!waitrequest`); the burst ends after the Nth.

**Boundary guarantee.** The data mover constrains every burst so that
`MAX_BURST_BEATS * (DATA_W/8) <= 1 KiB` and the start address is aligned such
that the burst never crosses a 4 KiB boundary. Therefore adapters never need to
split a burst for AXI 4 KiB or AHB 1 KiB rules.

---

## 2. CSR slave interface (host BAR access)

A lightweight single-beat Avalon-MM slave, no bursts. Driven by the PCIe Hard IP
RX master (BAR writes/reads from the host).

| Signal          | Dir | Width        | Meaning                          |
|-----------------|-----|--------------|----------------------------------|
| `csr_address`   | M→S | `CSR_ADDR_W` | Word address                     |
| `csr_read`      | M→S | 1            | Read strobe                      |
| `csr_write`     | M→S | 1            | Write strobe                     |
| `csr_writedata` | M→S | 32           | Write data                       |
| `csr_readdata`  | S→M | 32           | Read data (valid with `rvalid`)  |
| `csr_readdatavalid` | S→M | 1        | `csr_readdata` valid             |
| `csr_waitrequest`   | S→M | 1        | Tied 0 (always ready)            |

Reads have fixed 1-cycle latency: `csr_readdatavalid` asserts the cycle after an
accepted `csr_read`.

---

## 3. AXI4 master (system-port option `SYS_IF="AXI4"`)

Full AXI4 with independent AW/W/B and AR/R channels. The adapter:
* Drives `AWLEN/ARLEN = N-1`, `AWSIZE/ARSIZE = log2(DATA_W/8)`, `AWBURST/ARBURST = INCR (2'b01)`.
* Holds VALID asserted with stable payload until the matching READY; never
  deasserts VALID before handshake (AXI requirement).
* Asserts `WLAST` on the Nth write beat, expects `RLAST` on the Nth read beat.
* Uses a single outstanding transaction per direction (`AWID/ARID = 0`).
* Always accepts `B`/`R` (`BREADY/RREADY` driven from FIFO/credit availability).

## 4. AHB master (system-port option `SYS_IF="AHB"`)

AHB-Lite master. The adapter:
* Uses `HBURST = INCR (3'b001)` (unspecified length) sequenced as
  `HTRANS = NONSEQ` for the first beat then `SEQ` for the rest; `IDLE` otherwise.
* `HSIZE = log2(DATA_W/8)`, `HADDR` increments by `DATA_W/8` each beat.
* Honors `HREADY` (address/data phase pipeline): advances only when `HREADY==1`.
* Checks `HRESP`; a non-OKAY response raises the engine error flag.

## 5. Avalon-MM master (system-port option `SYS_IF="AVALON"`)

GMM is already the Avalon-MM pipelined profile, so the adapter is a registered
passthrough that simply exposes the signals under their Avalon names.
