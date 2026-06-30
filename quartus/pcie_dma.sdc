#============================================================================
# pcie_dma.sdc -- Timing constraints for the PCIe DMA engine
#
# The whole engine runs on a single clock `clk` (typically the PCIe Hard IP
# application clock coreclkout_hip, 125-250 MHz). Adjust the period to the
# target. Bus ports are constrained relative to clk; tighten with real values
# once integrated.
#============================================================================

# 125 MHz application clock (8 ns). Change to match coreclkout_hip.
create_clock -name clk -period 8.000 [get_ports clk]

derive_clock_uncertainty

# asynchronous, synchronously-deasserted reset
set_false_path -from [get_ports rst_n]

# Conservative I/O budget: 1 ns for combinational paths to/from pins, applied to
# the data/control ports only (not the clock or reset). These ports are
# internal-facing (virtual pins for standalone fit); when the core is integrated,
# the surrounding fabric provides the real timing.
set_input_delay  -clock clk 1.0 [remove_from_collection [all_inputs] [get_ports {clk rst_n}]]
set_output_delay -clock clk 1.0 [all_outputs]
