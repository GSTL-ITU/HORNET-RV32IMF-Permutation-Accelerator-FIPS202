CC        = gcc
CFLAGS    = -O2 -Isw
VERILATOR = verilator

SW_DIR    = sw
RTL_DIR   = rtl
SRC_DIR   = ../source/sources_1/imports/src

# The DUTs are taken straight from the SoC sources so the unit tests can't drift from them
DUT_SRC     = $(SRC_DIR)/keccak_accelerator_wb.v
DMA_DUT_SRC = $(SRC_DIR)/keccak_accelerator_dma_wb.v $(DUT_SRC)

# Accelerator without DMA
SW_SRCS  = $(SW_DIR)/test.c $(SW_DIR)/fips202.c
RTL_SRCS = $(DUT_SRC) $(RTL_DIR)/keccak_accelerator_wb_tb.v
OUT_SW   = test_data_out_sw.hex
OUT_RTL  = test_data_out_rtl.hex

# Accelerator with DMA
DMA_SW_SRCS  = $(SW_DIR)/dma_test.c $(SW_DIR)/fips202.c
DMA_RTL_SRCS = $(DMA_DUT_SRC) $(RTL_DIR)/keccak_accelerator_dma_wb_tb.v
DMA_OUT_SW   = dma_out_sw.hex
DMA_OUT_RTL  = dma_out_rtl.hex

all: test test_dma

$(OUT_SW): $(SW_SRCS)
	@echo "Compiling and executing C code (sw/test.c)..."
	@cd $(SW_DIR) && $(CC) $(CFLAGS) test.c fips202.c -o test_sw && ./test_sw

$(OUT_RTL): $(RTL_SRCS)
	@echo "Simulating hardware with verilator (rtl)..."
	@cd $(RTL_DIR) && $(VERILATOR) --binary --main --timing --timescale 1ns/1ps ../$(DUT_SRC) keccak_accelerator_wb_tb.v --Mdir obj_dir -o sim_exec
	@cd $(RTL_DIR) && ./obj_dir/sim_exec

$(DMA_OUT_SW): $(DMA_SW_SRCS)
	@echo "Compiling and executing C code (sw/dma_test.c)..."
	@cd $(SW_DIR) && $(CC) $(CFLAGS) dma_test.c fips202.c -o dma_test_sw && ./dma_test_sw

$(DMA_OUT_RTL): $(DMA_RTL_SRCS)
	@echo "Simulating DMA hardware with verilator (rtl)..."
	@cd $(RTL_DIR) && $(VERILATOR) --binary --main --timing --timescale 1ns/1ps $(addprefix ../,$(DMA_DUT_SRC)) keccak_accelerator_dma_wb_tb.v --top-module keccak_accelerator_dma_wb_tb --Mdir obj_dir_dma -o sim_exec
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

clean:
	@echo "Cleaning temp files..."
	@rm -rf $(OUT_SW) $(OUT_RTL) $(DMA_OUT_SW) $(DMA_OUT_RTL) $(SW_DIR)/test_sw $(SW_DIR)/dma_test_sw $(RTL_DIR)/obj_dir $(RTL_DIR)/obj_dir_dma

.PHONY: all test test_dma clean
