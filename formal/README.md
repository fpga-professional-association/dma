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
| `fv_ahb.sv`      | `gmm_to_ahb`       | **AHB-Lite legality**: no BUSY, INCR, control held across wait states, NONSEQ→SEQ sequencing, address increment, **sticky `err` on HRESP=ERROR & clears on abort** |
| `fv_fifo_ind.sv` | `dma_fifo`         | **inductive (depth-independent)** occupancy bookkeeping: no overflow/underflow and `level <= DEPTH` proven at the deployment depth `FIFO_DEPTH=256` |

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
sby -f formal/arbiter.sby
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
* The data-mover and CSR FSMs are exercised by the cycle-accurate self-checking
  simulation (`sim/`, all three bus options, with and without back-pressure),
  which is the primary functional proof; the formal layer pins down the FIFO and
  the three bus protocols where hand proofs are hardest.
