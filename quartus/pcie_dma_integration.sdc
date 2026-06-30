#============================================================================
# pcie_dma_integration.sdc -- integration timing template for pcie_dma_top
#
# Use this INSTEAD of quartus/pcie_dma.sdc when pcie_dma_top is instantiated as
# a Platform Designer component behind a PCIe Hard IP (the documented primary
# flow), rather than fitted standalone with virtual pins.
#
# Why a separate file:
#   * pcie_dma.sdc creates its own 8 ns `clk` and puts blanket 1 ns I/O delays
#     on the (virtual) bus pins -- correct only for the standalone fit.
#   * When integrated, `clk` is the PCIe Hard IP application clock and the bus
#     ports are internal fabric nets fully timed by Quartus between the
#     connected masters/slaves. No create_clock / I/O delay on those nets.
#
# Edit the marked node paths to match your system, then add this .sdc to the
# project (set_global_assignment -name SDC_FILE pcie_dma_integration.sdc).
#============================================================================

# Always safe: account for PLL/clock-network uncertainty on every clock.
derive_clock_uncertainty

#----------------------------------------------------------------------------
# (1) Single-clock deployment  (default; SYS bus on the application clock)
#
# The PCIe Hard IP already constrains its application clock (coreclkout_hip)
# via its own generated .sdc -- do NOT create_clock it again. The whole engine
# runs on that one clock, so no extra clock constraints are needed here.
#
# Reset is active-low and synchronously deasserted, so recovery/removal is a
# false path. Point this at the synchronized reset register feeding the
# component (the Hard IP / reset bridge usually supplies it):
#
#   # set_false_path -from [get_keepers {*reset_sync*}] -to [all_registers]
#----------------------------------------------------------------------------

#----------------------------------------------------------------------------
# (2) Separate-SYS-clock deployment  (dual-clock)
#
# Per docs/architecture.md "Clocking / CDC note": when the local system bus
# runs on its own clock through a dual-clock Avalon-MM/AXI clock-crossing
# bridge, the application clock and the SYS clock are asynchronous. Cut the two
# domains so TimeQuest does not try to time cross-domain paths (the bridge
# provides the synchronizers). Set the two clock nodes for your system, then
# uncomment:
#
#   # set app_clk [get_clocks <pcie_inst>|*coreclkout_hip*]
#   # set sys_clk [get_clocks <sys_clk_source>]
#   # set_clock_groups -asynchronous -group $app_clk -group $sys_clk
#----------------------------------------------------------------------------
