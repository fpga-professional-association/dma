#============================================================================
# pcie_dma_hw.tcl -- Platform Designer (Qsys) component description for
#                    pcie_dma_top, the configurable PCIe scatter-gather DMA
#                    engine.
#
# Drop this file (and the rtl/ tree it references) somewhere on the Quartus
# IP search path, or point Platform Designer at the quartus/ directory, and
# "PCIe Scatter-Gather DMA Engine" appears in the IP Catalog. The documented
# integration topology is:
#
#     PCIe Hard IP  BAR / RXM  --->  csr   (Avalon-MM slave)
#     PCIe Hard IP  TXS        <---  host  (Avalon-MM master)
#     PCIe Hard IP  MSI / IRQ  <---  irq   (interrupt sender)
#     local system bus         <---  sys_* (Avalon-MM | AXI4 | AHB master)
#
# The system-bus flavour is chosen with the SYS_IF parameter. All three SYS
# port groups are static on the HDL top level (see rtl/top/pcie_dma_top.sv);
# the elaboration callback exposes exactly the one matching SYS_IF and
# terminates the other two, so the component presents a single, correct SYS
# master for each setting (AVALON / AXI4 / AHB).
#
# This file describes only interfaces and parameters; it does NOT require a
# specific device or PCIe Hard IP. See quartus/example/ for a worked system.
#============================================================================

package require -exact qsys 18.0

#----------------------------------------------------------------------------
# Module
#----------------------------------------------------------------------------
set_module_property NAME                  pcie_dma_top
set_module_property DISPLAY_NAME          "PCIe Scatter-Gather DMA Engine"
set_module_property VERSION               1.1
set_module_property GROUP                 "PCIe / DMA"
set_module_property AUTHOR                "fpga-professional-association"
set_module_property DESCRIPTION           "Descriptor-ring scatter-gather DMA between host memory (PCIe) and a local system bus (Avalon-MM / AXI4 / AHB)."
set_module_property EDITABLE              false
set_module_property INTERNAL              false
set_module_property ELABORATION_CALLBACK  elaborate

#----------------------------------------------------------------------------
# Fixed widths -- mirror the constants in rtl/pkg/dma_pkg.sv. These are HDL
# localparams (not module parameters), so Platform Designer cannot read them;
# we restate them here only to size the interface ports. Keep in sync with the
# package if those constants ever change.
#   DATA_W=64  BE_W=8  HADDR_W=64  SADDR_W=32  CSR_ADDR_W=8  CSR_DATA_W=32
#   MAX_BURST_BEATS=16 -> BCW = $clog2(16)+1 = 5
#----------------------------------------------------------------------------
set DATA_W      64
set BE_W         8
set HADDR_W     64
set SADDR_W     32
set CSR_ADDR_W   8
set CSR_DATA_W  32
set BCW          5

#----------------------------------------------------------------------------
# HDL parameter: system-bus interface select
#----------------------------------------------------------------------------
add_parameter          SYS_IF STRING "AVALON"
set_parameter_property SYS_IF DISPLAY_NAME        "System-bus interface"
set_parameter_property SYS_IF DESCRIPTION         "Local system-bus master flavour exported on the SYS port."
set_parameter_property SYS_IF ALLOWED_RANGES      {AVALON AXI4 AHB}
set_parameter_property SYS_IF HDL_PARAMETER       true
set_parameter_property SYS_IF AFFECTS_ELABORATION true

#----------------------------------------------------------------------------
# Filesets (synthesis + Verilog simulation). The package must compile first.
#----------------------------------------------------------------------------
add_fileset          QUARTUS_SYNTH QUARTUS_SYNTH gen_files "Synthesis"
set_fileset_property QUARTUS_SYNTH TOP_LEVEL pcie_dma_top
set_fileset_property QUARTUS_SYNTH ENABLE_RELATIVE_INCLUDE_PATHS false

add_fileset          SIM_VERILOG SIM_VERILOG gen_files "Verilog simulation"
set_fileset_property SIM_VERILOG TOP_LEVEL pcie_dma_top

proc gen_files { entity } {
    add_fileset_file dma_pkg.sv             SYSTEM_VERILOG PATH ../rtl/pkg/dma_pkg.sv
    add_fileset_file dma_fifo.sv            SYSTEM_VERILOG PATH ../rtl/core/dma_fifo.sv
    add_fileset_file dma_arbiter.sv         SYSTEM_VERILOG PATH ../rtl/core/dma_arbiter.sv
    add_fileset_file dma_csr.sv             SYSTEM_VERILOG PATH ../rtl/core/dma_csr.sv
    add_fileset_file dma_descriptor_fetch.sv SYSTEM_VERILOG PATH ../rtl/core/dma_descriptor_fetch.sv
    add_fileset_file dma_data_mover.sv      SYSTEM_VERILOG PATH ../rtl/core/dma_data_mover.sv
    add_fileset_file dma_engine_core.sv     SYSTEM_VERILOG PATH ../rtl/core/dma_engine_core.sv
    add_fileset_file gmm_to_avalon.sv       SYSTEM_VERILOG PATH ../rtl/adapters/gmm_to_avalon.sv
    add_fileset_file gmm_to_axi4.sv         SYSTEM_VERILOG PATH ../rtl/adapters/gmm_to_axi4.sv
    add_fileset_file gmm_to_ahb.sv          SYSTEM_VERILOG PATH ../rtl/adapters/gmm_to_ahb.sv
    add_fileset_file pcie_dma_top.sv        SYSTEM_VERILOG PATH ../rtl/top/pcie_dma_top.sv TOP_LEVEL_FILE
}

#----------------------------------------------------------------------------
# Clock sink
#----------------------------------------------------------------------------
add_interface          clk clock end
set_interface_property clk clockRate 0
add_interface_port     clk clk clk Input 1

#----------------------------------------------------------------------------
# Reset sink (active-low, synchronously deasserted)
#----------------------------------------------------------------------------
add_interface          reset reset end
set_interface_property reset associatedClock   clk
set_interface_property reset synchronousEdges  DEASSERT
add_interface_port     reset rst_n reset_n Input 1

#----------------------------------------------------------------------------
# CSR: Avalon-MM slave (host BAR / RXM register access)
#----------------------------------------------------------------------------
add_interface          csr avalon end
set_interface_property csr associatedClock                 clk
set_interface_property csr associatedReset                 reset
set_interface_property csr addressUnits                    WORDS
set_interface_property csr addressAlignment                DYNAMIC
set_interface_property csr maximumPendingReadTransactions  1
set_interface_property csr isMemoryDevice                  false
set_interface_property csr isNonVolatileStorage            false
add_interface_port     csr csr_address       address       Input  $CSR_ADDR_W
add_interface_port     csr csr_read          read          Input  1
add_interface_port     csr csr_write         write         Input  1
add_interface_port     csr csr_writedata     writedata     Input  $CSR_DATA_W
add_interface_port     csr csr_readdata      readdata      Output $CSR_DATA_W
add_interface_port     csr csr_readdatavalid readdatavalid Output 1
add_interface_port     csr csr_waitrequest   waitrequest   Output 1

#----------------------------------------------------------------------------
# HOST: Avalon-MM master (PCIe TXS path -- descriptor fetch + host data)
#----------------------------------------------------------------------------
add_interface          host avalon start
set_interface_property host associatedClock  clk
set_interface_property host associatedReset  reset
set_interface_property host addressUnits     SYMBOLS
set_interface_property host burstcountUnits  WORDS
set_interface_property host linewrapBursts   false
add_interface_port     host host_address       address       Output $HADDR_W
add_interface_port     host host_read          read          Output 1
add_interface_port     host host_write         write         Output 1
add_interface_port     host host_writedata     writedata     Output $DATA_W
add_interface_port     host host_byteenable    byteenable    Output $BE_W
add_interface_port     host host_burstcount    burstcount    Output $BCW
add_interface_port     host host_waitrequest   waitrequest   Input  1
add_interface_port     host host_readdata      readdata      Input  $DATA_W
add_interface_port     host host_readdatavalid readdatavalid Input  1

#----------------------------------------------------------------------------
# SYS option A: Avalon-MM master  (SYS_IF == "AVALON")
#----------------------------------------------------------------------------
add_interface          sys_avm avalon start
set_interface_property sys_avm associatedClock  clk
set_interface_property sys_avm associatedReset  reset
set_interface_property sys_avm addressUnits     SYMBOLS
set_interface_property sys_avm burstcountUnits  WORDS
set_interface_property sys_avm linewrapBursts   false
add_interface_port     sys_avm avm_address       address       Output $SADDR_W
add_interface_port     sys_avm avm_read          read          Output 1
add_interface_port     sys_avm avm_write         write         Output 1
add_interface_port     sys_avm avm_writedata     writedata     Output $DATA_W
add_interface_port     sys_avm avm_byteenable    byteenable    Output $BE_W
add_interface_port     sys_avm avm_burstcount    burstcount    Output $BCW
add_interface_port     sys_avm avm_waitrequest   waitrequest   Input  1
add_interface_port     sys_avm avm_readdata      readdata      Input  $DATA_W
add_interface_port     sys_avm avm_readdatavalid readdatavalid Input  1

#----------------------------------------------------------------------------
# SYS option B: AXI4 master  (SYS_IF == "AXI4")
#----------------------------------------------------------------------------
add_interface          sys_axi axi4 start
set_interface_property sys_axi associatedClock          clk
set_interface_property sys_axi associatedReset          reset
set_interface_property sys_axi readIssuingCapability    1
set_interface_property sys_axi writeIssuingCapability   1
set_interface_property sys_axi combinedIssuingCapability 1
# write address channel
add_interface_port     sys_axi axi_awid     awid     Output 1
add_interface_port     sys_axi axi_awaddr   awaddr   Output $SADDR_W
add_interface_port     sys_axi axi_awlen    awlen    Output 8
add_interface_port     sys_axi axi_awsize   awsize   Output 3
add_interface_port     sys_axi axi_awburst  awburst  Output 2
add_interface_port     sys_axi axi_awcache  awcache  Output 4
add_interface_port     sys_axi axi_awprot   awprot   Output 3
add_interface_port     sys_axi axi_awvalid  awvalid  Output 1
add_interface_port     sys_axi axi_awready  awready  Input  1
# write data channel
add_interface_port     sys_axi axi_wdata    wdata    Output $DATA_W
add_interface_port     sys_axi axi_wstrb    wstrb    Output $BE_W
add_interface_port     sys_axi axi_wlast    wlast    Output 1
add_interface_port     sys_axi axi_wvalid   wvalid   Output 1
add_interface_port     sys_axi axi_wready   wready   Input  1
# write response channel
add_interface_port     sys_axi axi_bid      bid      Input  1
add_interface_port     sys_axi axi_bresp    bresp    Input  2
add_interface_port     sys_axi axi_bvalid   bvalid   Input  1
add_interface_port     sys_axi axi_bready   bready   Output 1
# read address channel
add_interface_port     sys_axi axi_arid     arid     Output 1
add_interface_port     sys_axi axi_araddr   araddr   Output $SADDR_W
add_interface_port     sys_axi axi_arlen    arlen    Output 8
add_interface_port     sys_axi axi_arsize   arsize   Output 3
add_interface_port     sys_axi axi_arburst  arburst  Output 2
add_interface_port     sys_axi axi_arcache  arcache  Output 4
add_interface_port     sys_axi axi_arprot   arprot   Output 3
add_interface_port     sys_axi axi_arvalid  arvalid  Output 1
add_interface_port     sys_axi axi_arready  arready  Input  1
# read data channel
add_interface_port     sys_axi axi_rid      rid      Input  1
add_interface_port     sys_axi axi_rdata    rdata    Input  $DATA_W
add_interface_port     sys_axi axi_rresp    rresp    Input  2
add_interface_port     sys_axi axi_rlast    rlast    Input  1
add_interface_port     sys_axi axi_rvalid   rvalid   Input  1
add_interface_port     sys_axi axi_rready   rready   Output 1

#----------------------------------------------------------------------------
# SYS option C: AHB-Lite master  (SYS_IF == "AHB")
#
# Platform Designer has no native AHB abstraction, so the AHB master is
# exported as a conduit. Connect it to the AHB fabric by exporting this
# conduit to the system boundary (or to an AHB bridge that presents a
# conduit). Roles use the standard AHB signal names.
#----------------------------------------------------------------------------
add_interface          sys_ahb conduit end
set_interface_property sys_ahb associatedClock clk
set_interface_property sys_ahb associatedReset reset
add_interface_port     sys_ahb haddr   haddr   Output $SADDR_W
add_interface_port     sys_ahb hburst  hburst  Output 3
add_interface_port     sys_ahb hsize   hsize   Output 3
add_interface_port     sys_ahb htrans  htrans  Output 2
add_interface_port     sys_ahb hwrite  hwrite  Output 1
add_interface_port     sys_ahb hwdata  hwdata  Output $DATA_W
add_interface_port     sys_ahb hrdata  hrdata  Input  $DATA_W
add_interface_port     sys_ahb hready  hready  Input  1
add_interface_port     sys_ahb hresp   hresp   Input  1

#----------------------------------------------------------------------------
# IRQ: interrupt sender (-> PCIe Hard IP MSI / interrupt controller)
#----------------------------------------------------------------------------
add_interface          irq interrupt end
set_interface_property irq associatedClock          clk
set_interface_property irq associatedReset          reset
set_interface_property irq associatedAddressablePoint csr
add_interface_port     irq irq irq Output 1

#----------------------------------------------------------------------------
# sys_bus_error: conduit (sticky SYS-bus error flag, ERR_SYS in ERR_INFO)
#----------------------------------------------------------------------------
add_interface          sys_bus_error conduit end
set_interface_property sys_bus_error associatedClock clk
set_interface_property sys_bus_error associatedReset reset
add_interface_port     sys_bus_error sys_bus_error error Output 1

#----------------------------------------------------------------------------
# Elaboration: expose exactly the SYS master matching SYS_IF; terminate the
# other two. Disabled interfaces have their ports automatically terminated by
# Platform Designer (inputs tied, outputs left dangling), matching the HDL
# generate block which drives the unused SYS groups to '0.
#----------------------------------------------------------------------------
proc elaborate {} {
    set sys_if [get_parameter_value SYS_IF]
    switch -exact -- $sys_if {
        AXI4 {
            set_interface_property sys_avm ENABLED false
            set_interface_property sys_ahb ENABLED false
        }
        AHB {
            set_interface_property sys_avm ENABLED false
            set_interface_property sys_axi ENABLED false
        }
        default {
            set_interface_property sys_axi ENABLED false
            set_interface_property sys_ahb ENABLED false
        }
    }
}
