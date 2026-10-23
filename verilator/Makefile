SOURCES := $(wildcard ../source/sources_1/imports/src/*.v)
SOURCES := $(filter-out ../source/sources_1/imports/src/fpga_top.v, $(SOURCES))
TESTBENCH = ../source/sim_1/imports/sim_src/barebones_top_tb.v
MEMFILE = ../source/sim_1/imports/initialize_memory/memory_init_tb.mem
TESTBENCH_NAME = barebones_top_tb
WNO = -Wno-lint -Wno-style -Wno-fatal

lint:
	@echo "Running lint checks..."
	verilator --lint-only --timing -Wall $(SOURCES)

build:
	verilator --binary $(SOURCES) $(TESTBENCH) -timescale 1ns/1ns --top $(TESTBENCH_NAME) -j 0 $(WNO)

run: build
	cp $(MEMFILE) ./
	obj_dir/V$(TESTBENCH_NAME)

wave: run
	gtkwave --dark dump.vcd

clean:
	@echo "Cleaning temp files..."
	rm -f dump.vcd
	rm -rf obj_dir

.PHONY: lint build run wave clean