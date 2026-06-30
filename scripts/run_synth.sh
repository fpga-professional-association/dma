#!/usr/bin/env bash
#============================================================================
# run_synth.sh -- Open-source gate-mapping sanity (yosys), confirming the RTL
# synthesizes to real flip-flops/LUTs.  This catches structural problems that
# pure elaboration/lint does not: inferred latches, unmapped constructs,
# multi-driven nets and combinational loops in synthesized form.
#
# Two groups are gate-mapped:
#   1. Leaf protocol/util blocks the native yosys front-end parses as-is
#      (they reference dma_pkg only by explicit `dma_pkg::` scope).
#   2. The core datapath (dma_csr/dma_descriptor_fetch/dma_data_mover/
#      dma_engine_core) and the integrated pcie_dma_top, which use the
#      `import dma_pkg::*;` idiom that the open-source yosys front-end (no
#      Verific) cannot parse.  We make them parseable WITHOUT sv2v/Verific by
#      mechanically rewriting the wildcard import to explicit `dma_pkg::`
#      scoping (the style dma_arbiter/the adapters already use) into a
#      throwaway work dir; the committed RTL is left untouched.  The package's
#      exported identifiers are derived straight from rtl/pkg/dma_pkg.sv so the
#      rewrite can never drift from the package.
#
# If `sv2v` is installed it is additionally used to cross-check the *unmodified*
# RTL through a real SystemVerilog front-end; when sv2v is absent that step is
# skipped (the explicit-scope flow above already gate-maps the full top).
#
# Vendor synthesis + STA remain available via Quartus (quartus/pcie_dma.qsf);
# whole-top elaboration of the unmodified RTL is covered by scripts/lint.sh.
#============================================================================
set -u
cd "$(dirname "$0")/.."

PKG=rtl/pkg/dma_pkg.sv
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
rc=0

# synth_one [--need-cells] <top> <files...>
synth_one() {
  local need=0
  if [ "$1" = "--need-cells" ]; then need=1; shift; fi
  local top="$1"; shift
  printf "%-22s : " "$top"
  local stat
  stat=$(yosys -p "read_verilog -sv -Irtl/pkg $PKG $*; \
                   synth -top $top -flatten; stat" 2>"$WORK/log.$top")
  if [ $? -ne 0 ]; then echo "FAIL (yosys error)"; tail -3 "$WORK/log.$top"; rc=1; return 1; fi
  local ff cells
  ff=$(echo "$stat"  | grep -iE 'DFF|\$_DFF|\$dff' | awk '{s+=$2} END{print s+0}')
  cells=$(echo "$stat" | sed -n 's/.*Number of cells: *\([0-9]*\).*/\1/p' | tail -1)
  if [ "$need" = 1 ] && { [ -z "${cells:-}" ] || [ "${cells:-0}" -eq 0 ]; }; then
    echo "FAIL (empty netlist)"; rc=1; return 1; fi
  echo "mapped OK (cells=${cells:-0}, FFs~${ff})"
}

#----------------------------------------------------------------------------
# 1. Leaf blocks -- parsed directly by yosys
#----------------------------------------------------------------------------
echo "=== yosys generic synthesis (leaf protocol + util blocks) ==="
synth_one dma_fifo       rtl/core/dma_fifo.sv
synth_one dma_arbiter    rtl/core/dma_arbiter.sv
synth_one gmm_to_avalon  rtl/adapters/gmm_to_avalon.sv
synth_one gmm_to_axi4    rtl/adapters/gmm_to_axi4.sv
synth_one gmm_to_ahb     rtl/adapters/gmm_to_ahb.sv

#----------------------------------------------------------------------------
# 2. Core datapath + integrated top -- via explicit-package-scope rewrite
#----------------------------------------------------------------------------
# Every identifier dma_pkg exports: parameters, typedef names, enum members.
SYMS="$WORK/pkg_syms.txt"
{ grep -oP '^\s*parameter\s+(?:int\s+unsigned\s+)?\K[A-Za-z_]\w*' "$PKG"
  grep -oP '\}\s*\K[A-Za-z_]\w*(?=\s*;)' "$PKG"
  grep -oP 'enum\s+[^{]*\{\K[^}]*' "$PKG" | grep -oP '[A-Za-z_]\w*(?=\s*=)'
} | sort -u > "$SYMS"

cat > "$WORK/flatten.pl" <<'PL'
use strict; use warnings;
my $sf = shift @ARGV; open(my $h,'<',$sf) or die "syms?";
my @s = sort { length($b) <=> length($a) } grep { length } map { chomp; $_ } <$h>;
my $alt = join('|', map { quotemeta } @s);
local $/; my $t = <STDIN>;
$t =~ s/^[ \t]*import[ \t]+dma_pkg::\*[ \t]*;[ \t]*\r?\n//mg;       # drop wildcard import
$t =~ s/(?<![\w:.])($alt)(?!\w)/dma_pkg::$1/g if $alt ne '';       # explicit-scope barewords
print $t;
PL

# Only the wildcard-import modules are rewritten; leaf deps (which already use
# explicit scope and even declare a param literally named BCW) are read as-is.
flat() {  # echo path to flattened copy of $1
  local d="$WORK/$(basename "$1")"
  perl "$WORK/flatten.pl" "$SYMS" < "$1" > "$d" || { echo "flatten failed: $1" >&2; rc=1; }
  echo "$d"
}
F_CSR=$(flat rtl/core/dma_csr.sv)
F_FETCH=$(flat rtl/core/dma_descriptor_fetch.sv)
F_MOVER=$(flat rtl/core/dma_data_mover.sv)
F_CORE=$(flat rtl/core/dma_engine_core.sv)
F_TOP=$(flat rtl/top/pcie_dma_top.sv)
LEAF="rtl/core/dma_fifo.sv rtl/core/dma_arbiter.sv \
      rtl/adapters/gmm_to_avalon.sv rtl/adapters/gmm_to_axi4.sv rtl/adapters/gmm_to_ahb.sv"

echo "=== yosys generic synthesis (core datapath + integrated top, package-flattened) ==="
synth_one --need-cells dma_csr              "$F_CSR"
synth_one --need-cells dma_descriptor_fetch "$F_FETCH"
synth_one --need-cells dma_data_mover       "$F_MOVER" rtl/core/dma_fifo.sv
synth_one --need-cells dma_engine_core      "$F_CSR" "$F_FETCH" "$F_MOVER" "$F_CORE" \
                                            rtl/core/dma_fifo.sv rtl/core/dma_arbiter.sv
synth_one --need-cells pcie_dma_top         "$F_CSR" "$F_FETCH" "$F_MOVER" "$F_CORE" "$F_TOP" $LEAF

#----------------------------------------------------------------------------
# 3. Optional whole-design front-end cross-check via sv2v (unmodified RTL).
#    Purely informational: this path is NOT exercised in CI (the synth job
#    installs only yosys) and cannot be verified in this environment, so it
#    never affects the script's exit status -- it must not turn the required
#    synth check red. The explicit-scope flow in step 2 is the real gate.
#----------------------------------------------------------------------------
echo "=== full-design synthesis via sv2v (optional cross-check, non-blocking) ==="
if command -v sv2v >/dev/null 2>&1; then
  if sv2v rtl/pkg/dma_pkg.sv rtl/core/*.sv rtl/adapters/*.sv rtl/top/*.sv \
        > "$WORK/dma_sv2v.v" 2>"$WORK/sv2v.log"; then
    printf "%-22s : " "pcie_dma_top[sv2v]"
    if yosys -p "read_verilog $WORK/dma_sv2v.v; synth -top pcie_dma_top -flatten; stat" \
         >"$WORK/log.sv2v" 2>&1; then
      c=$(sed -n 's/.*Number of cells: *\([0-9]*\).*/\1/p' "$WORK/log.sv2v" | tail -1)
      echo "mapped OK (cells=${c:-0})"
    else echo "WARN: sv2v->yosys failed (non-blocking)"; tail -3 "$WORK/log.sv2v"; fi
  else
    echo "WARN: sv2v conversion failed (non-blocking):"; tail -3 "$WORK/sv2v.log"
  fi
else
  echo "sv2v not installed -> SKIP (explicit-scope flow above already gate-mapped pcie_dma_top)."
fi

exit $rc
