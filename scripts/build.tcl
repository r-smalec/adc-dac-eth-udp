# SPDX-License-Identifier: MIT
# vivado -mode batch -source scripts/build.tcl -tclargs <part> [synth|bitstream]
set project_root [file normalize [file join [file dirname [info script]] ..]]
set build_dir [file join $project_root build vivado]
file mkdir $build_dir
set part xc7a35ticsg324-1L
set stage synth
set_param general.maxThreads 1
if {[llength $argv] >= 1} {set part [lindex $argv 0]}
if {[llength $argv] >= 2} {set stage [lindex $argv 1]}
if {$stage ni {synth bitstream}} {error "Stage must be synth or bitstream"}
source [file join $project_root build sources.tcl]
source [file join $project_root config.tcl]
foreach src $ad9226_sources {read_verilog -sv $src}
read_xdc [file join $project_root constraints arty_a7.xdc]
synth_design -top arty_ad9226_udp -part $part -generic $ad9226_generics
# Retain upstream CDC timing constraints; do not blanket-exclude clock groups.
source [file join $taxi_root src axis syn vivado taxi_axis_async_fifo.tcl]
source [file join $taxi_root src sync syn vivado taxi_sync_signal.tcl]
source [file join $taxi_root src sync syn vivado taxi_sync_reset.tcl]
source [file join $project_root constraints cdc.tcl]
write_checkpoint -force [file join $build_dir synthesized.dcp]
report_utilization -file [file join $build_dir utilization-synth.rpt]
report_timing_summary -report_unconstrained -file [file join $build_dir timing-synth.rpt]
report_cdc -details -file [file join $build_dir cdc-synth.rpt]
report_bus_skew -file [file join $build_dir bus-skew-synth.rpt]
if {$stage eq "bitstream"} {
    opt_design
    place_design
    phys_opt_design
    route_design
    # Save the implementation before report generation so tool failures
    # cannot discard a completed route.
    write_checkpoint -force [file join $build_dir routed.dcp]
    report_utilization -file [file join $build_dir utilization-route.rpt]
    report_timing_summary -report_unconstrained -file [file join $build_dir timing-route.rpt]
    report_drc -file [file join $build_dir drc.rpt]
    report_cdc -details -file [file join $build_dir cdc-route.rpt]
    report_bus_skew -file [file join $build_dir bus-skew-route.rpt]
    set failing_paths [get_timing_paths -quiet -delay_type min_max -slack_lesser_than 0 -max_paths 1]
    if {[llength $failing_paths]} {error "Timing failed; see timing-route.rpt"}
    write_bitstream -force [file join $build_dir arty_ad9226_udp.bit]
}
puts "AD9226_BUILD_COMPLETE stage=$stage part=$part"
