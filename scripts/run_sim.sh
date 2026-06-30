#!/usr/bin/env bash
#============================================================================
# run_sim.sh -- compile + run the self-checking testbench for every system-bus
# option, with and without bus back-pressure (Icarus Verilog).
#
#   ./scripts/run_sim.sh            # all 6 configurations
#   ./scripts/run_sim.sh AXI4 STALLS
#============================================================================
set -u
cd "$(dirname "$0")/.."
mkdir -p sim/build

RTL="rtl/pkg/dma_pkg.sv \
     rtl/core/dma_fifo.sv rtl/core/dma_arbiter.sv rtl/core/dma_csr.sv \
     rtl/core/dma_descriptor_fetch.sv rtl/core/dma_data_mover.sv rtl/core/dma_engine_core.sv \
     rtl/core/reset_sync.sv \
     rtl/adapters/gmm_to_avalon.sv rtl/adapters/gmm_to_axi4.sv rtl/adapters/gmm_to_ahb.sv \
     rtl/top/pcie_dma_top.sv \
     sim/models/avalon_mem_model.sv sim/models/axi_mem_model.sv sim/models/ahb_mem_model.sv \
     sim/tb_pcie_dma.sv"

run() {
  local name="$1"; shift
  local defs=""
  for d in "$@"; do defs="$defs -D$d"; done
  iverilog -g2012 -Irtl/pkg $defs -s tb_pcie_dma -o sim/build/sim.vvp $RTL 2>sim/build/compile.log
  if [ $? -ne 0 ]; then echo "$name: COMPILE FAIL"; cat sim/build/compile.log; return 1; fi
  local out; out=$(vvp sim/build/sim.vvp 2>&1)
  if echo "$out" | grep -q "=== PASS"; then echo "$name: PASS"; else echo "$name: FAIL"; echo "$out" | tail -5; fi
}

if [ $# -gt 0 ]; then
  case "$1" in
    AVALON) shift; run "AVALON ${*}" "$@";;
    AXI4)   shift; run "AXI4 ${*}"   USE_AXI "$@";;
    AHB)    shift; run "AHB ${*}"    USE_AHB "$@";;
    *) echo "usage: $0 [AVALON|AXI4|AHB] [STALLS]"; exit 1;;
  esac
else
  run "AVALON        "
  run "AVALON +stalls" STALLS
  run "AXI4          " USE_AXI
  run "AXI4   +stalls" USE_AXI STALLS
  run "AHB           " USE_AHB
  run "AHB    +stalls" USE_AHB STALLS
  # issue #14: exercise the optional 2-FF reset synchronizer (RESET_SYNC=1)
  run "AVALON +rstsyn" RESET_SYNC_EN
fi
