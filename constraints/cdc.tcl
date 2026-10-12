# SPDX-License-Identifier: MIT
# Apply after synthesis. Only asynchronous control input first stages are
# excluded; upstream FIFO Gray-pointer max-delay/bus-skew constraints remain.
set_false_path -from [get_ports reset_button]
set test_first [get_cells -quiet -hier -filter {NAME =~ *test_meta_reg}]
if {[llength $test_first]} {set_false_path -from [get_ports test_switch] -to $test_first}
set mdio_first [get_cells -quiet -hier -filter {NAME =~ *mdio_meta_reg}]
if {[llength $mdio_first]} {set_false_path -from [get_ports eth_mdio] -to $mdio_first}
# Both management outputs change only at the FSM's half-period boundaries.
# See the 500 ns / 40 ns relative output budget in arty_a7.xdc.
set management_clk [get_clocks -of_objects [get_pins clock_manager/CLKOUT0]]
if {[llength $management_clk] != 1} {error "Expected one system MMCM clock"}
set_max_delay -datapath_only 40.0 -from $management_clk -to [get_ports {eth_mdc eth_mdio}]
