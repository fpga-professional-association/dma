#============================================================================
# virtual_pins.tcl -- mark every top-level port except clk/rst_n as a virtual
# pin, so pcie_dma_top can be fitted standalone (it is an IP core, not a
# pinned-out top). Sourced by the .qsf.
#============================================================================
package require ::quartus::project

# Keep clk/rst_n as real inputs; everything else is internal-facing.
foreach_in_collection node [get_all_ports] {
    set name [get_port_info -name $node]
    if {$name ne "clk" && $name ne "rst_n"} {
        set_instance_assignment -name VIRTUAL_PIN ON -to $name
    }
}
