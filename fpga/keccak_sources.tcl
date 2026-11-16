# Shared by build.tcl and create_project.tcl: board definition and arguments from the
# HORNET-RV32IMF submodule (fpga/common/board.tcl), plus the Keccak sources of this repository.
#
# Sets: board, board_part, board_xdc, board_dir, rtl (submodule rtl/), out, imem, dmem, ... (see
# board.tcl), keccak_dma, keccak_srcs, keccak_generics.
# KECCAK_DMA=1 in the environment selects hornet_soc_keccak_dma.
set repo [file normalize [file dirname [info script]]/..]
source $repo/HORNET-RV32IMF/fpga/common/board.tcl

set keccak_dma [expr {[info exists ::env(KECCAK_DMA)] && $::env(KECCAK_DMA) ne "" ? $::env(KECCAK_DMA) : 0}]
set keccak_srcs [concat \
    [list $repo/rtl/keccak_accelerator_core.v $repo/rtl/keccak_accelerator_axil.v $repo/rtl/keccak_accelerator_dma_axil.v] \
    [glob $repo/soc/hornet/*.v] [list $repo/fpga/hornet_board_keccak.v]]

proc keccak_generics {} {
    global keccak_dma
    return [concat [board_generic_list] [list KECCAK_DMA=$keccak_dma]]
}

proc keccak_name {} {
    global keccak_dma
    return [expr {$keccak_dma ? "keccak_dma" : "keccak"}]
}
