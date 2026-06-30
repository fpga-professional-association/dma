#============================================================================
# pcie_dma_example.tcl -- worked Platform Designer system that wires the
# packaged pcie_dma_top component behind an Avalon-MM PCIe Hard IP, matching
# the documented topology:
#
#     PCIe Hard IP  RXM / BAR  --->  dma.csr    (register access from host)
#     PCIe HOST     dma.host   --->  PCIe TXS   (descriptor fetch + host data)
#     PCIe HOST     dma.irq    --->  Hard IP MSI/interrupt
#     dma.sys_avm              --->  on-chip RAM (the "local system bus")
#
# Generate the system with:
#     qsys-script --script=pcie_dma_example.tcl
#     qsys-generate pcie_dma_example.qsys --synthesis=VERILOG
#
# Prerequisite: the pcie_dma_top component must be on the IP search path. Run
# from quartus/example/ so "../" reaches quartus/pcie_dma_hw.tcl, or add
# quartus/ to QSYS_PATH / the project IP_SEARCH_PATHS.
#
# NOTE: the PCIe Hard IP component name and its interface (BAR/RXM/TXS/MSI)
# port names are device-family specific. The instance below uses the generic
# Avalon-MM Hard IP role names; replace `<pcie_hip_component>` and adjust the
# connection endpoints to the exact names reported by `ip-catalog` /
# `qsys-script -cmd "get_instance_interfaces"` for your target family
# (e.g. altera_pcie_a10_hip_avmm, altera_pcie_sv_hip_avmm). The DMA-side
# endpoints (dma.csr / dma.host / dma.irq / dma.sys_avm) are exactly as
# packaged in ../pcie_dma_hw.tcl and do not change.
#============================================================================

package require -exact qsys 18.0

create_system pcie_dma_example
set_project_property DEVICE_FAMILY {Cyclone V}
set_project_property DEVICE        5CGXFC9D6F27C7

#----------------------------------------------------------------------------
# Clock / reset sources for the example fabric. In a real design these come
# from the PCIe Hard IP application clock (coreclkout_hip) + reset status; a
# clock_source/reset bridge is used here so the script is self-contained.
#----------------------------------------------------------------------------
add_instance clk altera_clock_bridge
set_instance_parameter_value clk EXPLICIT_CLOCK_RATE {125000000.0}

add_instance rst altera_reset_bridge
set_instance_parameter_value rst ACTIVE_LOW_RESET {1}
set_instance_parameter_value rst SYNCHRONOUS_EDGES {deassert}

#----------------------------------------------------------------------------
# DMA engine (Avalon-MM system bus for this example)
#----------------------------------------------------------------------------
add_instance dma pcie_dma_top
set_instance_parameter_value dma SYS_IF {AVALON}

#----------------------------------------------------------------------------
# Local "system bus" target: an on-chip RAM the DMA reads/writes.
#----------------------------------------------------------------------------
add_instance sysram altera_avalon_onchip_memory2
set_instance_parameter_value sysram dataWidth {64}
set_instance_parameter_value sysram totalMemorySize {65536}

#----------------------------------------------------------------------------
# PCIe Hard IP (Avalon-MM). Replace component + endpoints per device family.
#----------------------------------------------------------------------------
# add_instance pcie <pcie_hip_component>
# set_instance_parameter_value pcie <...device/lane/BAR settings...>

#----------------------------------------------------------------------------
# Clock / reset distribution
#----------------------------------------------------------------------------
add_connection clk.out_clk   dma.clk
add_connection clk.out_clk   sysram.clk1
add_connection rst.out_reset dma.reset
add_connection rst.out_reset sysram.reset1

# In a real system, drive clk/rst from the Hard IP:
# add_connection pcie.coreclkout_hip clk.in_clk
# add_connection pcie.app_nreset_status rst.in_reset

#----------------------------------------------------------------------------
# Data-path connections (the documented topology)
#----------------------------------------------------------------------------
# Host register access:  PCIe BAR/RXM master -> dma CSR slave
# add_connection pcie.rxm_bar0 dma.csr

# Host memory access:    dma HOST master -> PCIe TXS slave
# add_connection dma.host pcie.txs

# Completion interrupt:  dma irq -> PCIe MSI / interrupt receiver
# add_connection dma.irq pcie.msi

# Local system bus:      dma Avalon-MM SYS master -> on-chip RAM
add_connection dma.sys_avm sysram.s1
set_connection_parameter_value dma.sys_avm/sysram.s1 baseAddress {0x00000000}

#----------------------------------------------------------------------------
# Export the SYS-bus-error conduit so the integrator can observe it.
#----------------------------------------------------------------------------
add_interface          sys_bus_error conduit end
set_interface_property sys_bus_error EXPORT_OF dma.sys_bus_error

save_system pcie_dma_example.qsys
