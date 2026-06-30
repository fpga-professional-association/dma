#!/usr/bin/env bash
#============================================================================
# run_formal.sh -- Bounded formal proofs using the open-source yosys built-in
# SAT engine (no external SMT solver required).
#
#   ./scripts/run_formal.sh [DEPTH]
#
# Each harness in formal/ is read in -formal mode, flattened, its memories and
# async resets lowered, then proven with `sat -prove-asserts` up to DEPTH cycles
# (default 22). A clean run prints "SUCCESS" for every target.
#
# For unbounded proofs (k-induction) or deeper bounds, install SymbiYosys + a
# solver (z3/boolector) and run e.g.  `sby -f formal/axi4.sby`.
#============================================================================
set -u
cd "$(dirname "$0")/.."
DEPTH="${1:-22}"
PKG=rtl/pkg/dma_pkg.sv

declare -A RTL=(
  [fv_fifo]="rtl/core/dma_fifo.sv"
  [fv_arbiter]="rtl/core/dma_arbiter.sv"
  [fv_axi4]="rtl/adapters/gmm_to_axi4.sv"
  [fv_ahb]="rtl/adapters/gmm_to_ahb.sv"
  [fv_ahb_abort]="rtl/adapters/gmm_to_ahb.sv"   # issue #11: ERROR burst-cancel
)

fail=0
for top in fv_fifo fv_arbiter fv_axi4 fv_ahb fv_ahb_abort; do
  printf "%-12s : " "$top"
  out=$(yosys -p "read_verilog -sv -formal -Irtl/pkg $PKG ${RTL[$top]} formal/${top}.sv; \
                  prep -top $top; flatten; memory_map; async2sync; opt -fast; \
                  sat -seq $DEPTH -prove-asserts -set-assumes -set-init-zero" 2>&1)
  if echo "$out" | grep -q "no model found: SUCCESS"; then
    echo "PASS  (bmc depth $DEPTH)"
  else
    echo "FAIL"
    echo "$out" | grep -iE 'model found|ERROR' | tail -3
    fail=1
  fi
done
exit $fail
