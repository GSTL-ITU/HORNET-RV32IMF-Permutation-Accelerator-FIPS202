# Batch build of hornet_board_keccak: synthesis, implementation, reports, bitstream.
# Same flow as HORNET-RV32IMF/fpga/common/build.tcl, with the Keccak SoC.
#
#   [KECCAK_DMA=1] vivado -mode batch -source fpga/build.tcl -tclargs <board> <out dir> <imem.hex> <dmem.hex> [IMEM_SIZE DMEM_SIZE CLK_DIV BOOT_ADDR RV_M RV_F]
#   (usually through fpga/Makefile)
#
# Without program arguments it builds build/vivado-<keccak|keccak_dma>-<board>/ with the submodule's
# default images (bootloader + LED blink).
set script_name build.tcl
source [file dirname [file normalize [info script]]]/keccak_sources.tcl
board_args $repo/build/vivado-[keccak_name]-$board

file mkdir $out
cd $out
set_part $board_part
set_param general.maxThreads 8

read_verilog [glob $rtl/core/*.v] [glob $rtl/fpu/*.v] [glob $rtl/soc/*.v] {*}$keccak_srcs
read_xdc $board_dir/$board_xdc
file copy -force $imem imem.hex
file copy -force $dmem dmem.hex

set generics {}
foreach g [keccak_generics] { lappend generics -generic $g }
synth_design -top hornet_board_keccak -include_dirs [list $rtl/core $rtl/fpu] {*}$generics
report_utilization -file utilization_synth.rpt
opt_design
place_design
phys_opt_design
route_design
report_utilization -file utilization.rpt
report_utilization -hierarchical -hierarchical_depth 6 -file utilization_hier.rpt
report_timing_summary -max_paths 20 -file timing.rpt
report_ram_utilization -file ram.rpt
write_bitstream -force hornet_[keccak_name]_$board.bit

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set period [expr {10.0 * $clk_div / 10.0}]
set f [open result.txt w]
puts $f "board=$board"
puts $f "part=$board_part"
puts $f "soc=hornet_soc_[keccak_name]"
puts $f "isa=[board_isa]"
puts $f "clk_div=$clk_div"
puts $f "period_ns=$period"
puts $f "wns_ns=$wns"
puts $f "whs_ns=$whs"
puts $f "vivado=[version -short]"
set crit [get_timing_paths -max_paths 1 -nworst 1 -setup]
puts $f "crit_from=[get_property STARTPOINT_PIN $crit]"
puts $f "crit_to=[get_property ENDPOINT_PIN $crit]"
puts $f "crit_levels=[get_property LOGIC_LEVELS $crit]"
puts $f "crit_datapath_ns=[get_property DATAPATH_DELAY $crit]"
close $f
puts "RESULT: $board_name ($board_part) hornet_soc_[keccak_name] [board_isa] WNS $wns ns at [expr {1000.0 / $period}] MHz (period $period ns)"
if {$wns < 0} {
    puts "RESULT: timing NOT met"
    exit 1
}
