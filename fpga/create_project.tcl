# Vivado GUI project of hornet_board_keccak, with the program images in the block RAMs.
# Same as HORNET-RV32IMF/fpga/common/create_project.tcl, with the Keccak SoC.
#
#   [KECCAK_DMA=1] vivado -mode batch -source fpga/create_project.tcl -tclargs <board> <dir> <imem.hex> <dmem.hex> [IMEM_SIZE DMEM_SIZE CLK_DIV BOOT_ADDR RV_M RV_F]
#
# Without program arguments it creates build/vivado-<keccak|keccak_dma>-<board>-project/hornet_keccak.xpr
# with the submodule's default images (bootloader + LED blink). To change the program, replace
# imem.hex/dmem.hex in the project directory, then Generate Bitstream.
set script_name create_project.tcl
source [file dirname [file normalize [info script]]]/keccak_sources.tcl
board_args $repo/build/vivado-[keccak_name]-$board-project
set dir $out

create_project hornet_keccak $dir -part $board_part -force
add_files [glob $rtl/core/*.v] [glob $rtl/fpu/*.v] [glob $rtl/soc/*.v] {*}$keccak_srcs
add_files [glob $rtl/core/*.vh]
set_property is_global_include true [get_files hornet_defs.vh]
file copy -force $imem $dir/imem.hex
file copy -force $dmem $dir/dmem.hex
add_files -norecurse $dir/imem.hex $dir/dmem.hex
set_property file_type {Memory Initialization Files} [get_files *.hex]
add_files -fileset constrs_1 $board_dir/$board_xdc
set_property top hornet_board_keccak [current_fileset]
set_property generic [join [keccak_generics] " "] [current_fileset]
set_property include_dirs [list $rtl/core $rtl/fpu] [current_fileset]
update_compile_order -fileset sources_1
puts "RESULT: $board_name project $dir/hornet_keccak.xpr (hornet_soc_[keccak_name], [board_isa])"
