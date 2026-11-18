# FPGA build of HORNET-RV32IMF (main) with the Keccak accelerator, running a test program.
#
#   make build   [BOARD=nexys4ddr|nexysvideo] [TEST=kyber|sphincs] [DMA=1] [KECCAK_SW=1] [CLK_DIV=20]
#                firmware (CORE=hornet) + synthesis/implementation/bitstream
#                TEST=kyber (default): ML-KEM-768, test/ml-kem-kyber
#                TEST=sphincs: SPHINCS+, test/sphincsplus ([PARAMS=sphincs-shake-128f] [THASH=simple])
#   make project [BOARD=...] [DMA=1]   Vivado GUI project with the same images
#   make program [BOARD=...] [DMA=1]   program the board over JTAG
#
# The firmware prints its cycle report over the UART (115200 baud) once; press
# CPU_RESET to run it again. Outputs go to build/<board>-<keccak|keccak_dma>/ (ML-KEM) or
# build/<board>-<keccak|keccak_dma>-sphincs/. The firmware is part of the bitstream (BRAM init), so
# every TEST needs its own build. The test programs need IMEM 16-20 KiB, DMEM 22-50 KiB with the
# 32 KiB stack (memory_report.txt); the default 64 KiB each fit both.

ROOT      = ..
BOARD    ?= nexys4ddr
DMA      ?= 0
KECCAK_SW ?= 0
TEST     ?= kyber
CLK_DIV  ?= 20
IMEM_SIZE = 65536
DMEM_SIZE = 65536
VIVADO   ?= $(shell command -v vivado 2>/dev/null || echo vivado)

NAME  = $(if $(filter 1,$(DMA)),keccak_dma,keccak)

ifeq ($(TEST),kyber)
FW      = $(ROOT)/test/ml-kem-kyber/test
FW_NAME = sim_kyber
FW_ARGS =
OUT     = build/$(BOARD)-$(NAME)
else ifeq ($(TEST),sphincs)
PARAMS  ?= sphincs-shake-128f
THASH   ?= simple
FW      = $(ROOT)/test/sphincsplus/test
FW_NAME = sim_sphincs
FW_ARGS = PARAMS=$(PARAMS) THASH=$(THASH)
OUT     = build/$(BOARD)-$(NAME)-sphincs
else
$(error TEST=$(TEST): use kyber or sphincs)
endif
ARGS  = $(BOARD) . $(CURDIR)/$(OUT)/imem.hex $(CURDIR)/$(OUT)/dmem.hex $(IMEM_SIZE) $(DMEM_SIZE) $(CLK_DIV) 0 1 1

images:
	$(MAKE) -C $(FW) build CORE=hornet DMA=$(DMA) KECCAK_SW=$(KECCAK_SW) IMEM_SIZE=$(IMEM_SIZE) DMEM_SIZE=$(DMEM_SIZE) $(FW_ARGS)
	@mkdir -p $(OUT)
	cp $(FW)/$(FW_NAME).imem.hex $(OUT)/imem.hex
	cp $(FW)/$(FW_NAME).dmem.hex $(OUT)/dmem.hex

build: images
	cd $(OUT) && KECCAK_DMA=$(DMA) $(VIVADO) -mode batch -nojournal -log vivado.log \
	    -source $(CURDIR)/build.tcl -tclargs $(ARGS) > /dev/null; \
	    status=$$?; grep "^RESULT" vivado.log; exit $$status

project: images
	cd $(OUT) && KECCAK_DMA=$(DMA) $(VIVADO) -mode batch -nojournal -log vivado_project.log \
	    -source $(CURDIR)/create_project.tcl -tclargs $(BOARD) project $(wordlist 3,10,$(ARGS)) > /dev/null; \
	    status=$$?; grep "^RESULT" vivado_project.log; exit $$status

program:
	$(VIVADO) -mode batch -nojournal -nolog -source $(ROOT)/HORNET-RV32IMF/fpga/common/program.tcl \
	    -tclargs $(BOARD) $(OUT)/hornet_$(NAME)_$(BOARD).bit

clean:
	rm -rf build

.PHONY: images build project program clean
