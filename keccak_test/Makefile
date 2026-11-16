CC        = gcc
CFLAGS    = -O2 -Isw
VERILATOR = verilator
VFLAGS    = --binary --main --timing --timescale 1ns/1ps -Wno-fatal -Wno-lint -Wno-style

SW_DIR    = sw
RTL_DIR   = rtl
SRC_DIR   = ../rtl

# The DUTs are taken straight from rtl/ so the unit tests can't drift from them
DUT_SRC          = $(SRC_DIR)/legacy_keccak_accelerator_wb.v
DMA_DUT_SRC      = $(SRC_DIR)/legacy_keccak_accelerator_dma_wb.v $(DUT_SRC)
AXIL_DUT_SRC     = $(SRC_DIR)/keccak_accelerator_core.v $(SRC_DIR)/keccak_accelerator_axil.v
DMA_AXIL_DUT_SRC = $(SRC_DIR)/keccak_accelerator_core.v $(SRC_DIR)/keccak_accelerator_dma_axil.v

# Legacy accelerator without DMA: RTL vs reference C
SW_SRCS  = $(SW_DIR)/test.c $(SW_DIR)/fips202.c
RTL_SRCS = $(DUT_SRC) $(RTL_DIR)/legacy_keccak_accelerator_wb_tb.v
OUT_SW   = test_data_out_sw.hex
OUT_RTL  = test_data_out_rtl.hex

# Legacy accelerator with DMA: RTL vs reference C
DMA_SW_SRCS  = $(SW_DIR)/dma_test.c $(SW_DIR)/fips202.c
DMA_RTL_SRCS = $(DMA_DUT_SRC) $(RTL_DIR)/legacy_keccak_accelerator_dma_wb_tb.v
DMA_OUT_SW   = dma_out_sw.hex
DMA_OUT_RTL  = dma_out_rtl.hex

# AXI4-Lite accelerators (HORNET-RV32IMF main): equivalence with the legacy ones
AXIL_SRCS     = $(AXIL_DUT_SRC) $(DUT_SRC) $(RTL_DIR)/keccak_accelerator_axil_tb.sv
DMA_AXIL_SRCS = $(DMA_AXIL_DUT_SRC) $(DMA_DUT_SRC) $(RTL_DIR)/keccak_accelerator_dma_axil_tb.sv

all: test test_dma test_axil test_dma_axil

legacy: test test_dma

axil: test_axil test_dma_axil

$(OUT_SW): $(SW_SRCS)
	@echo "Compiling and executing C code (sw/test.c)..."
	@cd $(SW_DIR) && $(CC) $(CFLAGS) test.c fips202.c -o test_sw && ./test_sw

$(OUT_RTL): $(RTL_SRCS)
	@echo "Simulating hardware with verilator (rtl)..."
	@cd $(RTL_DIR) && $(VERILATOR) $(VFLAGS) $(addprefix ../,$(RTL_SRCS)) --top-module legacy_keccak_accelerator_wb_tb --Mdir obj_dir -o sim_exec > obj_dir.log
	@cd $(RTL_DIR) && ./obj_dir/sim_exec

$(DMA_OUT_SW): $(DMA_SW_SRCS)
	@echo "Compiling and executing C code (sw/dma_test.c)..."
	@cd $(SW_DIR) && $(CC) $(CFLAGS) dma_test.c fips202.c -o dma_test_sw && ./dma_test_sw

$(DMA_OUT_RTL): $(DMA_RTL_SRCS)
	@echo "Simulating DMA hardware with verilator (rtl)..."
	@cd $(RTL_DIR) && $(VERILATOR) $(VFLAGS) $(addprefix ../,$(DMA_RTL_SRCS)) --top-module legacy_keccak_accelerator_dma_wb_tb --Mdir obj_dir_dma -o sim_exec > obj_dir_dma.log
	@cd $(RTL_DIR) && ./obj_dir_dma/sim_exec

test: $(OUT_SW) $(OUT_RTL)
	@echo "Comparing output files..."
	@if diff -u $(OUT_SW) $(OUT_RTL); then \
		echo "[SUCCESS] RTL and SW outputs are identical."; \
	else \
		echo "[FAIL] RTL and SW outputs are different."; \
		exit 1; \
	fi

test_dma: $(DMA_OUT_SW) $(DMA_OUT_RTL)
	@echo "Comparing DMA output files..."
	@if diff -u $(DMA_OUT_SW) $(DMA_OUT_RTL); then \
		echo "[SUCCESS] DMA RTL and SW outputs are identical."; \
	else \
		echo "[FAIL] DMA RTL and SW outputs are different."; \
		exit 1; \
	fi

# $(1): top module, $(2): sources, $(3): obj dir
define run_equiv
	@echo "Simulating $(1) against the legacy accelerator (verilator)..."
	@cd $(RTL_DIR) && $(VERILATOR) $(VFLAGS) $(addprefix ../,$(2)) --top-module $(1) --Mdir $(3) -o sim_exec > $(3).log
	@cd $(RTL_DIR) && ./$(3)/sim_exec | tee $(3).out | grep -v "^-"
	@if grep -qx PASS $(RTL_DIR)/$(3).out; then \
		echo "[SUCCESS] $(1): AXI4-Lite and Wishbone accelerators are equivalent."; \
	else \
		echo "[FAIL] $(1)"; \
		exit 1; \
	fi
endef

test_axil: $(AXIL_SRCS)
	$(call run_equiv,keccak_accelerator_axil_tb,$(AXIL_SRCS),obj_dir_axil)

test_dma_axil: $(DMA_AXIL_SRCS)
	$(call run_equiv,keccak_accelerator_dma_axil_tb,$(DMA_AXIL_SRCS),obj_dir_dma_axil)

clean:
	@echo "Cleaning temp files..."
	@rm -rf $(OUT_SW) $(OUT_RTL) $(DMA_OUT_SW) $(DMA_OUT_RTL) $(SW_DIR)/test_sw $(SW_DIR)/dma_test_sw \
		$(RTL_DIR)/obj_dir* $(RTL_DIR)/*.log $(RTL_DIR)/*.out

.PHONY: all legacy axil test test_dma test_axil test_dma_axil clean
