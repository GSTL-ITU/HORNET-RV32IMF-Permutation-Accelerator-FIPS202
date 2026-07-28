CC        = gcc
CFLAGS    = -O2 -Isw
VERILATOR = verilator

SW_DIR    = sw
RTL_DIR   = rtl

SW_SRCS = $(SW_DIR)/test.c $(SW_DIR)/fips202.c
RTL_SRCS = $(RTL_DIR)/keccak_accelerator_wb.v $(RTL_DIR)/keccak_accelerator_wb_tb.v

OUT_SW  = test_data_out_sw.hex
OUT_RTL = test_data_out_rtl.hex

all: test

$(OUT_SW): $(SW_SRCS)
	@echo "Compiling and executing C code (sw/test.c)..."
	@cd $(SW_DIR) && $(CC) $(CFLAGS) test.c fips202.c -o test_sw && ./test_sw

$(OUT_RTL): $(RTL_SRCS)
	@echo "Simulating hardware with verilator (rtl)..."
	@cd $(RTL_DIR) && $(VERILATOR) --binary --main --timing keccak_accelerator_wb.v keccak_accelerator_wb_tb.v -o sim_exec
	@cd $(RTL_DIR) && ./obj_dir/sim_exec

test: $(OUT_SW) $(OUT_RTL)
	@echo "Comparing output files..."
	@if diff -u $(OUT_SW) $(OUT_RTL); then \
		echo "[SUCCESS] RTL and SW outputs are identical."; \
	else \
		echo "[FAIL] RTL and SW outputs are different."; \
		exit 1; \
	fi

# Temizlik Komutu
clean:
	@echo "Cleaning temp files..."
	@rm -rf $(OUT_SW) $(OUT_RTL) $(SW_DIR)/test_sw $(RTL_DIR)/obj_dir

.PHONY: all test clean