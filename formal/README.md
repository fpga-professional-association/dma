# Formal Verification

Property checkers (SystemVerilog Assertions, immediate style) for the
correctness- and protocol-critical blocks. They are written in the portable
yosys-formal subset so they run **with the open-source toolchain and no external
SMT solver**, and also work under SymbiYosys with a solver for unbounded proofs.

| Harness          | DUT                | What is proven                                                        |
|------------------|--------------------|----------------------------------------------------------------------|
| `fv_fifo.sv`     | `dma_fifo`         | occupancy math, no overflow/underflow, flag consistency, **FIFO ordering + data integrity** (symbolic tracked element) |
| `fv_arbiter.sv`  | `dma_arbiter`      | single downstream command, **grant mutual exclusion**, response mutual exclusion, forwarded payload provenance |
| `fv_axi4.sv`     | `gmm_to_axi4`      | **AXI4 handshake stability** (VALID held with stable payload until READY), INCR/ARSIZE/AWSIZE, AWLEN/ARLEN, WLAST placement, AW/AR exclusivity, **sticky `err` tracks non-OKAY RRESP/BRESP & clears on abort** |
| `fv_ahb.sv`      | `gmm_to_ahb`       | **AHB-Lite legality**: no BUSY, INCR, control held across wait states, NONSEQ→SEQ sequencing, address increment; models a spec-legal **two-cycle `HRESP=ERROR`** response and proves the **sticky `err` flag is raised on HRESP=ERROR & clears on abort** (drain mode, `EARLY_ABORT=0`) |
| `fv_ahb_abort.sv`| `gmm_to_ahb` (`EARLY_ABORT=1`) | **AHB-Lite ERROR burst-cancel**: across the modelled two-cycle ERROR the pending transfer is dropped to `HTRANS=IDLE`, control only changes to IDLE on the ERROR (else held), and the sticky `err` flag is still raised |
| `fv_fifo_ind.sv` | `dma_fifo`         | **inductive (depth-independent)** occupancy bookkeeping: no overflow/underflow and `level <= DEPTH` proven at the deployment depth `FIFO_DEPTH=256` |
| `fv_data_mover.sv` | `dma_data_mover` | **burst boundary soundness**: every issued read/write command has `burstcount ∈ [1, MAX_BURST_BEATS]` and its byte window stays inside the aligned 1 KiB page (never crosses a 1 KiB/4 KiB boundary); per-port read/write exclusivity; full byteenable. Closes the package-level "no burst crosses a boundary" contract every adapter proof relies on |
| `fv_avalon.sv`   | `gmm_to_avalon`    | **passthrough equivalence**: every Avalon-MM master output equals its GMM source, every GMM response equals its Avalon source, and `err == 0` (verified baseline for the default-SYS adapter) |
| `fv_descriptor_fetch.sv` | `dma_descriptor_fetch` | **ring addressing**: read command targets `base + index*DESC_BYTES`, burst is exactly `DESC_BEATS` with full byteenable, master is read-only, command held stable across wait states, `valid` is a single-cycle pulse |

Each harness instantiates the DUT with **free** stimulus, constrains the
environment with `assume` (a well-behaved GMM master: read/write exclusive,
`burstcount` in `[1, MAX_BURST_BEATS]`, command/data held while back-pressured,
`write` held for the duration of a burst), and checks the DUT outputs with
`assert`. A standard one-cycle formal-reset model drives `rst_n`.

In addition (issue #7) every harness now drives **`clr` (abort) as a free input**
and carries post-abort safety assertions (FIFO drains, arbiter drops the
in-flight transaction with no stray command/response, `err` clears), plus
`cover` witnesses (`wire cov_*`) — a full FIFO, completed read/write bursts, both
arbiter grants, an AHB NONSEQ→SEQ chain, the error path — whose reachability is
checked so a passing proof cannot be vacuously true.

## Run locally (no solver needed)

```
./scripts/run_formal.sh            # all check families, bmc depth 22
./scripts/run_formal.sh 40         # deeper bound
```

This uses yosys' **built-in SAT engine** and runs four families of checks:

1. **bounded assertion proofs at the toy widths** (`DW=16, AW=8`) — fast;
2. **bounded assertion proofs at the deployment widths** via `chparam`
   (`gmm_to_axi4`/`gmm_to_ahb` at `AW=32, DW=64`; `dma_arbiter` at `AW=64, DW=64`;
   `dma_fifo` at `WIDTH=64`);
3. **cover reachability** — each `wire cov_*` witness must be reachable *under the
   environment assumptions* (model found), ruling out vacuous passes;
4. **unbounded inductive proofs** — `sat -tempinduct` proves the FIFO
   no-overflow / `level <= DEPTH` invariants **depth-independently at the
   deployment depth `FIFO_DEPTH=256`** (`fv_fifo_ind.sv`), which bounded model
   checking can never reach (256 pushes to fill).

A single bounded target is, e.g.:

```
yosys -p "read_verilog -sv -formal -Irtl/pkg rtl/pkg/dma_pkg.sv \
            rtl/adapters/gmm_to_axi4.sv formal/fv_axi4.sv; \
          chparam -set AW 32 -set DW 64 fv_axi4; \
          prep -top fv_axi4; flatten; memory_map; async2sync; opt -fast; \
          chformal -cover -remove; \
          sat -seq 22 -prove-asserts -set-assumes -set-init-zero"
```

`-set-assumes` honours the environment assumptions and `-set-init-zero` starts
from a defined reset state. `chformal -cover -remove` drops the `$cover` cells,
which the SAT engine cannot import (the cover-reachability pass instead removes
the *assertions* and searches for a witness with `-set-at`).

## Unbounded proofs (SymbiYosys)

`*.sby` scripts are provided for [SymbiYosys](https://github.com/YosysHQ/sby).
With a solver installed (z3, boolector, yices, …):

```
sby -f formal/fifo_prove.sby       # mode prove: unbounded inductive FIFO @ DEPTH=256
sby -f formal/fifo.sby             # mode bmc  + cover, deployment width
sby -f formal/axi4.sby             # mode bmc  + cover, deployment widths
sby -f formal/ahb.sby
sby -f formal/ahb_abort.sby
sby -f formal/arbiter.sby
sby -f formal/avalon.sby
sby -f formal/data_mover.sby
sby -f formal/descriptor_fetch.sby
```

**Unbounded proofs require `[options] mode prove`** (temporal k-induction), not
just a different engine — under `mode bmc` SymbiYosys performs *bounded* model
checking regardless of which `[engines]` line is selected. `fifo_prove.sby`
shows the `mode prove` setup; `abc pdr` is an alternative unbounded (PDR/IC3)
engine. The bounded `*.sby` files re-prove at the **deployment widths** via a
`chparam` line in `[script]`.

These solver-based flows are exercised by the **`.github/workflows/formal-sby.yml`**
workflow (manual `workflow_dispatch`, `continue-on-error`), which installs
oss-cad-suite (yosys + sby + z3/boolector). It is deliberately *non-gating*:
the bounded SAT proofs in `scripts/run_formal.sh` remain the required CI check.

## Scope / notes

* The toy-width targets keep BMC fast; protocol compliance is width-independent,
  but the deployment-width targets (families 2 above and the `chparam` `.sby`
  lines) re-prove at the real `dma_pkg` widths so the claim is not just asserted.
* The FIFO no-overflow guarantee at the true `FIFO_DEPTH=256` is the one property
  BMC cannot reach; it is closed by **k-induction** (`fv_fifo_ind.sv`,
  `fifo_prove.sby`, and `sat -tempinduct` locally).
* The data-mover **burst-boundary** invariant, the **Avalon** passthrough and the
  **descriptor-fetch** addressing are now formally proven (issue #6), closing the
  package-level "no burst crosses a 1 KiB/4 KiB boundary" soundness gap that every
  adapter proof had previously only *assumed*.
* The new harnesses state their properties on the DUT **ports** only: the
  open-source yosys Verilog front-end does not resolve hierarchical references
  into a submodule instance (`dut.<internal>` is silently treated as a fresh
  free wire), so internal-signal assertions would be vacuous. The bus command
  (address/burstcount) and the control outputs are exactly the protocol-critical
  observables. `dma_data_mover` and `dma_descriptor_fetch` reference the package
  by explicit `dma_pkg::` scope (like the adapters) instead of `import dma_pkg::*`
  so the portable front-end can parse them; behaviour is unchanged.
* Still **simulation-only** (follow-up): the CSR RW1C/pulse logic (its headline
  set-wins-over-clear property lives in an internal register that the port-only
  style cannot observe) and the descriptor-ring walk FSM in `dma_engine_core`
  (which `import`s the package and is too large for tractable portable BMC). These
  remain exercised by the cycle-accurate self-checking simulation (`sim/`, all
  three bus options, with and without back-pressure), the primary functional proof.
