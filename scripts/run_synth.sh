#!/usr/bin/env bash
#============================================================================
# run_synth.sh -- Open-source gate-mapping sanity (yosys) for the protocol- and
# data-path-critical blocks, confirming they synthesize to real flip-flops/LUTs.
#
# The full pcie_dma_top (and the CSR/fetch/mover/engine modules) use the
# SystemVerilog `import pkg::*` idiom, which the open-source yosys front-end does
# not parse without Verific. Those go through Quartus (quartus/pcie_dma.qsf);
# verilator --lint-only (scripts/lint.sh) elaborates the whole top. The blocks
# below reference the package by explicit scope and map cleanly with yosys.
#============================================================================
set -u
cd "$(dirname "$0")/.."

synth_one() {
  local top="$1"; shift
  printf "%-16s : " "$top"
  local stat
  stat=$(yosys -p "read_verilog -sv -Irtl/pkg rtl/pkg/dma_pkg.sv $*; \
                   synth -top $top -flatten; stat" 2>/tmp/synth_$top.log)
  if [ $? -ne 0 ]; then echo "FAIL"; tail -3 /tmp/synth_$top.log; return 1; fi
  local ff; ff=$(echo "$stat"  | grep -iE 'DFF|\$_DFF' | awk '{s+=$2} END{print s+0}')
  local cells; cells=$(echo "$stat" | sed -n 's/.*Number of cells: *\([0-9]*\).*/\1/p' | tail -1)
  echo "mapped OK (cells=${cells:-?}, FFs~${ff})"
}

echo "=== yosys generic synthesis (protocol + data-path blocks) ==="
synth_one dma_fifo       rtl/core/dma_fifo.sv
synth_one dma_arbiter    rtl/core/dma_arbiter.sv
synth_one gmm_to_avalon  rtl/adapters/gmm_to_avalon.sv
synth_one gmm_to_axi4    rtl/adapters/gmm_to_axi4.sv
synth_one gmm_to_ahb     rtl/adapters/gmm_to_ahb.sv
echo "(full top: quartus_sh --flow compile quartus/pcie_dma ; elaboration: scripts/lint.sh)"
