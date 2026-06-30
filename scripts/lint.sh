#!/usr/bin/env bash
#============================================================================
# lint.sh -- Verilator -Wall lint of the synthesizable RTL, for each system-bus
# configuration. A clean run prints nothing per config and exits 0.
#============================================================================
set -u
cd "$(dirname "$0")/.."

RTL="rtl/pkg/dma_pkg.sv \
     rtl/core/dma_fifo.sv rtl/core/dma_arbiter.sv rtl/core/dma_csr.sv \
     rtl/core/dma_descriptor_fetch.sv rtl/core/dma_data_mover.sv rtl/core/dma_engine_core.sv \
     rtl/adapters/gmm_to_avalon.sv rtl/adapters/gmm_to_axi4.sv rtl/adapters/gmm_to_ahb.sv \
     rtl/top/pcie_dma_top.sv"

rc=0
for cfg in AVALON AXI4 AHB; do
  printf "lint %-7s : " "$cfg"
  # -Wno-UNUSED is intentionally NOT waived project-wide: legitimately-unused
  # signals (the unselected SYS-bus ports, reserved descriptor bits, AXI id/resp
  # fields) carry narrowly-scoped /* verilator lint_off UNUSEDSIGNAL */ pragmas in
  # the RTL instead. -Wno-PINCONNECTEMPTY/-Wno-DECLFILENAME remain as documented.
  if verilator --lint-only -sv -Wall -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY \
       -GSYS_IF="\"$cfg\"" -Irtl/pkg --top-module pcie_dma_top $RTL 2>/tmp/lint_$cfg.log; then
    echo "clean"
  else
    echo "WARNINGS/ERRORS"; cat /tmp/lint_$cfg.log; rc=1
  fi
done
exit $rc
