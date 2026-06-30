#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#============================================================================
# run_formal.sh -- Bounded formal proofs using the open-source yosys built-in
# SAT engine (no external SMT solver required).
#
#   ./scripts/run_formal.sh [DEPTH]
#
# Each harness in formal/ is read in -formal mode, flattened, its memories and
# async resets lowered, then proven with `sat -prove-asserts` up to DEPTH cycles
# (default 22). A clean run prints "PASS" for every target.
#
# This script runs three families of checks (issue #7):
#   1. assertion proofs at the fast toy widths (DW=16, AW=8),
#   2. assertion proofs at the DEPLOYMENT widths via `chparam`,
#   3. cover-reachability checks (`wire cov_*` witnesses) so a passing proof is
#      not vacuously true under the environment assumptions.
#
# Cover cells break yosys' SAT engine directly, so they are removed before each
# `sat -prove-asserts` run; the cover-reachability pass instead removes the
# assertions and searches for a witness trace (model found == reachable).
#
# For UNBOUNDED proofs (k-induction, e.g. FIFO no-overflow at FIFO_DEPTH=256)
# install SymbiYosys + a solver and run the `mode prove` targets, e.g.
#   sby -f formal/fifo_prove.sby      (see formal/README.md, .github/workflows/formal-sby.yml)
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
  # --- issue #6: harnesses for previously sim-only / unproven blocks ---
  [fv_avalon]="rtl/adapters/gmm_to_avalon.sv"
  [fv_data_mover]="rtl/core/dma_fifo.sv rtl/core/dma_data_mover.sv"
  [fv_descriptor_fetch]="rtl/core/dma_descriptor_fetch.sv"
)

# Deployment-width / depth overrides re-proved alongside the toy-width targets.
# (FIFO no-overflow at the full 256-deep instance needs an inductive proof --
# see formal/fifo_prove.sby -- so only WIDTH is bumped for the bounded run.)
declare -A WIDE=(
  [fv_fifo]="-set WIDTH 64 -set DEPTH 8"
  [fv_arbiter]="-set AW 64 -set DW 64"
  [fv_axi4]="-set AW 32 -set DW 64"
  [fv_ahb]="-set AW 32 -set DW 64"
)

fail=0

prove_asserts () {   # $1=top  $2=chparam-args  $3=label
  local top="$1" chp="$2" label="$3" out
  printf "%-12s %-18s : " "$top" "$label"
  out=$(yosys -p "read_verilog -sv -formal -Irtl/pkg $PKG ${RTL[$top]} formal/${top}.sv; \
                  ${chp:+chparam $chp $top;} prep -top $top; flatten; memory_map; \
                  async2sync; opt -fast; chformal -cover -remove; \
                  sat -seq $DEPTH -prove-asserts -set-assumes -set-init-zero" 2>&1)
  if echo "$out" | grep -q "no model found: SUCCESS"; then
    echo "PASS  (bmc depth $DEPTH)"
  else
    echo "FAIL"; echo "$out" | grep -iE 'model found|ERROR' | tail -3; fail=1
  fi
}

prove_induct () {    # $1=top  $2=rtl  $3=chparam-args  $4=label
  local top="$1" rtl="$2" chp="$3" label="$4" out
  printf "%-12s %-18s : " "$top" "$label"
  # yosys' built-in SAT engine does unbounded temporal (k-)induction, so this is a
  # DEPTH-INDEPENDENT proof -- no external solver required.
  out=$(yosys -p "read_verilog -sv -formal -Irtl/pkg $PKG $rtl formal/${top}.sv; \
                  ${chp:+chparam $chp $top;} prep -top $top; flatten; memory_map; \
                  async2sync; opt -fast; chformal -cover -remove; \
                  sat -tempinduct -prove-asserts -set-assumes -seq 5" 2>&1)
  if echo "$out" | grep -q "Induction step proven: SUCCESS"; then
    echo "PASS  (k-induction, unbounded)"
  else
    echo "FAIL"; echo "$out" | grep -iE 'failed|ERROR' | tail -3; fail=1
  fi
}

cover_reach () {     # $1=top  $2=chparam-args
  local top="$1" chp="$2" w out
  # discover the `wire cov_*` witnesses declared in the harness
  for w in $(grep -oE 'wire +cov_[A-Za-z0-9_]+' "formal/${top}.sv" | awk '{print $2}' | sort -u); do
    printf "%-12s cover %-12s : " "$top" "$w"
    # remove asserts + covers (covers cannot be imported by sat); keep assumes so
    # the witness must be reachable UNDER the environment constraints.
    out=$(yosys -p "read_verilog -sv -formal -Irtl/pkg $PKG ${RTL[$top]} formal/${top}.sv; \
                    ${chp:+chparam $chp $top;} prep -top $top; flatten; memory_map; \
                    async2sync; opt -fast; chformal -cover -remove; chformal -assert -remove; \
                    sat -seq $DEPTH -set-assumes -set-init-zero -set-at $DEPTH $w 1" 2>&1)
    if echo "$out" | grep -qE 'finished - model found'; then
      echo "REACHABLE"
    else
      echo "UNREACHABLE (vacuity!)"; fail=1
    fi
  done
}

echo "=== bounded assertion proofs (toy widths) ==="
# issue #7 originals + issue #11 (fv_ahb_abort) + issue #6 (avalon/data_mover/descriptor_fetch)
for top in fv_fifo fv_arbiter fv_axi4 fv_ahb fv_ahb_abort \
           fv_avalon fv_data_mover fv_descriptor_fetch; do prove_asserts "$top" "" "toy widths"; done

echo "=== bounded assertion proofs (deployment widths) ==="
for top in fv_fifo fv_arbiter fv_axi4 fv_ahb; do prove_asserts "$top" "${WIDE[$top]}" "deploy widths"; done

echo "=== cover reachability (anti-vacuity) ==="
for top in fv_fifo fv_arbiter fv_axi4 fv_ahb; do cover_reach "$top" ""; done

echo "=== unbounded inductive proofs (depth-independent) ==="
# FIFO no-overflow / level-bound proven at the deployment depth FIFO_DEPTH=256,
# which bounded model checking can never reach (256 pushes to fill). See also
# formal/fifo_prove.sby for the equivalent SymbiYosys mode-prove target.
prove_induct fv_fifo_ind "rtl/core/dma_fifo.sv" "-set WIDTH 64 -set DEPTH 256" "FIFO @ DEPTH=256"

exit $fail
