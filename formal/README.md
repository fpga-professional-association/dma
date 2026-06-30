# Formal Verification

Property checkers (SystemVerilog Assertions, immediate style) for the
correctness- and protocol-critical blocks. They are written in the portable
yosys-formal subset so they run **with the open-source toolchain and no external
SMT solver**, and also work under SymbiYosys with a solver for unbounded proofs.

| Harness          | DUT                | What is proven                                                        |
|------------------|--------------------|----------------------------------------------------------------------|
| `fv_fifo.sv`     | `dma_fifo`         | occupancy math, no overflow/underflow, flag consistency, **FIFO ordering + data integrity** (symbolic tracked element) |
| `fv_arbiter.sv`  | `dma_arbiter`      | single downstream command, **grant mutual exclusion**, response mutual exclusion, forwarded payload provenance |
| `fv_axi4.sv`     | `gmm_to_axi4`      | **AXI4 handshake stability** (VALID held with stable payload until READY), INCR/ARSIZE/AWSIZE, AWLEN/ARLEN, WLAST placement, AW/AR exclusivity |
| `fv_ahb.sv`      | `gmm_to_ahb`       | **AHB-Lite legality**: no BUSY, INCR, control held across wait states, NONSEQ→SEQ sequencing, address increment |

Each harness instantiates the DUT with **free** stimulus, constrains the
environment with `assume` (a well-behaved GMM master: read/write exclusive,
`burstcount` in `[1, MAX_BURST_BEATS]`, command/data held while back-pressured,
`write` held for the duration of a burst), and checks the DUT outputs with
`assert`. A standard one-cycle formal-reset model drives `rst_n`.

## Run locally (no solver needed)

```
./scripts/run_formal.sh            # bmc depth 22 on all four targets
./scripts/run_formal.sh 40         # deeper bound
```

This uses yosys' built-in SAT engine:

```
yosys -p "read_verilog -sv -formal -Irtl/pkg rtl/pkg/dma_pkg.sv \
            rtl/adapters/gmm_to_axi4.sv formal/fv_axi4.sv; \
          prep -top fv_axi4; flatten; memory_map; async2sync; opt -fast; \
          sat -seq 22 -prove-asserts -set-assumes -set-init-zero"
```

`-set-assumes` honours the environment assumptions and `-set-init-zero` starts
from a defined reset state.

## Unbounded proofs (SymbiYosys)

`*.sby` scripts are provided for [SymbiYosys](https://github.com/YosysHQ/sby).
With a solver installed (z3, boolector, yices, …):

```
sby -f formal/fifo.sby
sby -f formal/axi4.sby
sby -f formal/ahb.sby
sby -f formal/arbiter.sby
```

The `.sby` files default to `smtbmc z3`; switch the `[engines]` line to
`aiger suprove` or `abc pdr` for unbounded k-induction / PDR proofs.

## Scope / notes

* Proofs run at small data/address widths (`DW=16, AW=8`) — protocol compliance
  is width-independent, and small widths keep BMC fast. Override with `chparam`
  or the harness parameters to re-prove at the deployment widths.
* The data-mover and CSR FSMs are exercised by the cycle-accurate self-checking
  simulation (`sim/`, all three bus options, with and without back-pressure),
  which is the primary functional proof; the formal layer pins down the FIFO and
  the three bus protocols where hand proofs are hardest.
