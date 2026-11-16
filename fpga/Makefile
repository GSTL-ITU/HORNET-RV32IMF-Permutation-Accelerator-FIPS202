# FPGA build of HORNET-RV32IMF (main) with the Keccak accelerator, running the ML-KEM firmware.
#
#   make build   [BOARD=nexys4ddr|nexysvideo] [DMA=1] [KECCAK_SW=1] [CLK_DIV=20]
#                firmware (test/ml-kem-kyber, CORE=hornet) + synthesis/implementation/bitstream
#   make project [BOARD=...] [DMA=1]   Vivado GUI project with the same images
#   make program [BOARD=...] [DMA=1]   program the board over JTAG
#
# The firmware prints its cycle report over the UART (115200 baud) once; press
# CPU_RESET to run it again. Outputs go to build/<board>-<keccak|keccak_dma>/.

ROOT      = ..
BOARD    ?= nexys4ddr
DMA      ?= 0
KECCAK_SW ?= 0
CLK_DIV  ?= 20
IMEM_SIZE = 65536
DMEM_SIZE = 65536
VIVADO   ?= $(shell command -v vivado 2>/dev/null || echo vivado)

NAME  = $(if $(filter 1,$(DMA)),keccak_dma,keccak)
OUT   = build/$(BOARD)-$(NAME)
FW    = $(ROOT)/test/ml-kem-kyber/test
ARGS  = $(BOARD) . $(CURDIR)/$(OUT)/imem.hex $(CURDIR)/$(OUT)/dmem.hex $(IMEM_SIZE) $(DMEM_SIZE) $(CLK_DIV) 0 1 1

images:
	$(MAKE) -C $(FW) build CORE=hornet DMA=$(DMA) KECCAK_SW=$(KECCAK_SW) IMEM_SIZE=$(IMEM_SIZE) DMEM_SIZE=$(DMEM_SIZE)
	@mkdir -p $(OUT)
	cp $(FW)/sim_kyber.imem.hex $(OUT)/imem.hex
	cp $(FW)/sim_kyber.dmem.hex $(OUT)/dmem.hex

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
