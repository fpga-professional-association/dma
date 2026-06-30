# Descriptor Format

Descriptors live in **host memory** as a contiguous ring of 32-byte entries
starting at `{DESC_BASE_HI, DESC_BASE_LO}`. The engine processes `DESC_COUNT`
entries in order. All multi-byte fields are **little-endian**.

```
 byte offset
 0x00  ┌───────────────────────────────────────────────┐
       │ host_addr [63:0]   (PCIe-side byte address)    │
 0x08  ├───────────────────────────────────────────────┤
       │ sys_addr  [63:0]   (system-side byte address)  │   only SADDR_W bits used
 0x10  ├───────────────────────┬───────────────────────┤
       │ length [31:0] (bytes) │ control [31:0]         │
 0x18  ├───────────────────────┴───────────────────────┤
       │ reserved [63:0]   (must be 0)                  │
 0x20  └───────────────────────────────────────────────┘
```

## control field

| Bit | Name    | Description                                          |
|-----|---------|------------------------------------------------------|
| 0   | C_VALID | 1 = descriptor is owned by the engine and valid.     |
| 1   | C_DIR   | 0 = H2C (host→system), 1 = C2H (system→host).         |
| 2   | C_IRQ   | 1 = raise the completion IRQ after this descriptor.   |
| 3   | C_LAST  | 1 = last descriptor (engine may stop early).          |
| 31:4| —       | Reserved (0).                                        |

> **Note.** Bytes 24..31 are strictly reserved and must be written as 0. The
> engine performs **no in-band per-descriptor status writeback** (it never writes
> to `base + idx*32 + 24`, and `C_VALID` is read but never cleared in the ring).
> Software observes completion via the global `STATUS` register, the
> `REG_DESC_INDEX` completed-descriptor count, and the optional per-descriptor
> `C_IRQ` completion interrupt.

## Constraints

* The ring base `{DESC_BASE_HI, DESC_BASE_LO}` must be **32-byte aligned**
  (BAD_BASE otherwise, checked at GO).
* `length` must be non-zero and a multiple of `DATA_W/8` bytes
  (BAD_LEN otherwise).
* `host_addr` and `sys_addr` must be `DATA_W/8`-aligned (BAD_ALIGN otherwise).
* The engine processes descriptors `[0 .. DESC_COUNT-1]`. `C_LAST` lets a ring be
  terminated before `DESC_COUNT` is reached.

> **Whole-bus-word contract.** The `length` and address constraints above are not
> incidental: the data mover transfers only complete bus words (`DATA_W/8` bytes,
> 8 bytes at the default `DATA_W=64`) with all byte-lanes enabled — there is no
> partial-strobe / sub-word datapath today. Buffers must therefore be padded and
> aligned to `DATA_W/8`. The `BAD_LEN` / `BAD_ALIGN` codes (`register_map.md`)
> enforce this at run time before any data is moved. Sub-word / unaligned
> (byte-enable) support is tracked as future work — see the **Limitations**
> section of the top-level `README.md`.

## Assembly into `desc_t`

The fetch unit reads `DESC_BEATS = ceil(256 / DATA_W)` beats from host memory,
concatenates them little-endian into a 256-bit word `d`, then slices:

```
host_addr = d[ 63:  0]
sys_addr  = d[127: 64]   // low SADDR_W bits used
length    = d[159:128]
control   = d[191:160]
```
