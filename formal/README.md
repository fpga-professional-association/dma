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
| `fv_data_mover.sv` | `dma_data_mover` | **burst boundary soundness**: every issued read/write command has `burstcount ∈ [1, MAX_BURST_BEATS]` and its byte window stays inside the aligned 1 KiB page (never crosses a 1 KiB/4 KiB boundary); per-port read/write exclusivity; full byteenable. Closes the package-level "no burst crosses a boundary" contract every adapter proof relies on |
| `fv_avalon.sv`   | `gmm_to_avalon`    | **passthrough equivalence**: every Avalon-MM master output equals its GMM source, every GMM response equals its Avalon source, and `err == 0` (verified baseline for the default-SYS adapter) |
| `fv_descriptor_fetch.sv` | `dma_descriptor_fetch` | **ring addressing**: read command targets `base + index*DESC_BYTES`, burst is exactly `DESC_BEATS` with full byteenable, master is read-only, command held stable across wait states, `valid` is a single-cycle pulse |

Each harness instantiates the DUT with **free** stimulus, constrains the
environment with `assume` (a well-behaved GMM master: read/write exclusive,
`burstcount` in `[1, MAX_BURST_BEATS]`, command/data held while back-pressured,
`write` held for the duration of a burst), and checks the DUT outputs with
`assert`. A standard one-cycle formal-reset model drives `rst_n`.

## Run locally (no solver needed)

```
./scripts/run_formal.sh            # bmc depth 22 on all targets
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
sby -f formal/avalon.sby
sby -f formal/data_mover.sby
sby -f formal/descriptor_fetch.sby
```

The `.sby` files default to `smtbmc z3`; switch the `[engines]` line to
`aiger suprove` or `abc pdr` for unbounded k-induction / PDR proofs.

## Scope / notes

* Proofs run at small data/address widths (`DW=16, AW=8`) — protocol compliance
  is width-independent, and small widths keep BMC fast. Override with `chparam`
  or the harness parameters to re-prove at the deployment widths.
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
