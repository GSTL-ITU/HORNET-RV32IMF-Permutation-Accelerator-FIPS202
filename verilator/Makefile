# Verilator simulation of the SoC with the Keccak accelerator.
#
#   make run                    HORNET-RV32IMF main, hornet_soc_keccak       (imem.hex / dmem.hex here)
#   make run DMA=1              HORNET-RV32IMF main, hornet_soc_keccak_dma
#   make run CORE=legacy        HORNET-RV32IMF legacy, barebones_wb_top_keccak     (memory_init_tb.mem here)
#   make run CORE=legacy DMA=1  HORNET-RV32IMF legacy, barebones_wb_top_keccak_dma
#
# The memory images are copied here by `make copy_mem` in test/ml-kem-kyber/test (see cbr.sh).

ROOT   = ..
CORE  ?= hornet
DMA   ?= 0
WNO    = -Wno-lint -Wno-style -Wno-fatal

ACC_SRCS_LEGACY = $(ROOT)/rtl/legacy_keccak_accelerator_wb.v $(ROOT)/rtl/legacy_keccak_accelerator_dma_wb.v
ACC_SRCS_HORNET = $(ROOT)/rtl/keccak_accelerator_core.v $(ROOT)/rtl/keccak_accelerator_axil.v \
                  $(ROOT)/rtl/keccak_accelerator_dma_axil.v

ifeq ($(DMA),1)
DEFINES = +define+KECCAK_DMA
SUFFIX  = _dma
else
DEFINES =
SUFFIX  =
endif

ifeq ($(CORE),legacy)
# legacy SoC from the submodule; barebones_wb_top and debug_interface_wb are replaced by soc/legacy
LEGACY_SRC = $(ROOT)/HORNET-RV32IMF-legacy/source/sources_1/imports/src
SOURCES  := $(filter-out $(addprefix $(LEGACY_SRC)/,fpga_top.v barebones_wb_top.v debug_interface_wb.v), \
                         $(wildcard $(LEGACY_SRC)/*.v)) \
            $(ACC_SRCS_LEGACY) $(filter-out %_tb.v,$(wildcard $(ROOT)/soc/legacy/*.v))
TESTBENCH = $(ROOT)/soc/legacy/barebones_top_tb.v
TESTBENCH_NAME = barebones_top_tb
OBJ_DIR  = obj_dir_legacy$(SUFFIX)
VFLAGS   = -timescale 1ns/1ns
RUN_ARGS =
else ifeq ($(CORE),hornet)
HORNET   = $(ROOT)/HORNET-RV32IMF/rtl
SOURCES  := $(wildcard $(HORNET)/core/*.v $(HORNET)/fpu/*.v $(HORNET)/soc/*.v) \
            $(ACC_SRCS_HORNET) $(wildcard $(ROOT)/soc/hornet/*.v)
TESTBENCH = $(ROOT)/soc/hornet/hornet_soc_keccak_tb.sv
TESTBENCH_NAME = soc_tb
OBJ_DIR  = obj_dir_hornet$(SUFFIX)
IMEM_SIZE ?= 65536
DMEM_SIZE ?= 65536
TIMEOUT   ?= 200000000
VFLAGS   = --timing --timescale 1ns/1ps +1364-2005ext+v -I$(HORNET)/core -I$(HORNET)/fpu \
           -GIMEM_SIZE=$(IMEM_SIZE) -GDMEM_SIZE=$(DMEM_SIZE)
RUN_ARGS = +imem=imem.hex +dmem=dmem.hex +timeout=$(TIMEOUT)
else
$(error CORE=$(CORE): use hornet or legacy)
endif

lint:
	@echo "Running lint checks..."
	verilator --lint-only --timing -Wall $(VFLAGS) $(DEFINES) $(SOURCES) --top-module $(TESTBENCH_NAME) $(TESTBENCH)

build:
	verilator --binary $(SOURCES) $(TESTBENCH) $(DEFINES) $(VFLAGS) --top $(TESTBENCH_NAME) --Mdir $(OBJ_DIR) -j 0 $(WNO)

run: build
	$(OBJ_DIR)/V$(TESTBENCH_NAME) $(RUN_ARGS)

wave: run
	gtkwave --dark dump.vcd

clean:
	@echo "Cleaning temp files..."
	rm -f dump.vcd
	rm -rf obj_dir obj_dir_dma obj_dir_legacy obj_dir_legacy_dma obj_dir_hornet obj_dir_hornet_dma

.PHONY: lint build run wave clean
