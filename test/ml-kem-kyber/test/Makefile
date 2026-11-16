CC32=riscv32-unknown-elf
CC64=riscv64-unknown-elf
HOSTCC=gcc
TARGET=sim_kyber

ROOT = ../../..

# `make build CORE=hornet` (default): HORNET-RV32IMF main, hornet_soc_keccak(_dma)
#     -> sim_kyber.imem.hex / sim_kyber.dmem.hex
# `make build CORE=legacy`: HORNET-RV32IMF legacy, barebones_wb_top_keccak(_dma)
#     -> sim_kyber.data (memory_init_tb.mem)
CORE ?= hornet

# Kyber does not use the FPU; same code generation on both cores
COMMON_FLAGS = -mabi=ilp32 -ffp-contract=off -mstrict-align -malign-data=xlen -O2 -fno-math-errno \
               -ffunction-sections -fdata-sections -Wl,--gc-sections -I../

# `make build KECCAK_SW=1` uses the software permutation instead of the accelerator (reference numbers)
ifeq ($(KECCAK_SW),1)
COMMON_FLAGS += -DKECCAK_SW
endif

# `make build DMA=1` uses the accelerator's DMA engine (needs the DMA top)
ifeq ($(DMA),1)
COMMON_FLAGS += -DKECCAK_DMA
endif

# All Kyber core submodules located one directory up
KYBER_SRC = ../cbd.c ../fips202.c ../indcpa.c ../kem.c ../ntt.c ../poly.c ../polyvec.c ../randombytes.c ../reduce.c ../symmetric-shake.c ../verify.c

ifeq ($(CORE),legacy)
# ---------------- legacy core: unified RAM image from rom_gen ----------------
CCFLAGS = $(COMMON_FLAGS) -march=rv32im -DHORNET_LEGACY -T ./linksc.ld -nostartfiles
STARTUP = $(ROOT)/rom_gen/crt0.s

# .data holds initialised globals (e.g. the randombytes seed); it must be part of the memory image
OBJCOPY_SECTIONS = -j .init -j .text -j .rodata -j .data -j .sdata

define build_image
	$(1)-gcc hornet_kyber.c $(KYBER_SRC) $(STARTUP) $(CCFLAGS) -o $(TARGET).elf
	$(1)-objcopy -O binary $(OBJCOPY_SECTIONS) $(TARGET).elf $(TARGET).bin
	$(ROOT)/rom_gen/rom_generator $(TARGET).bin
	cp $(TARGET).data memory_init_tb.mem
endef

copy_mem:
	cp $(TARGET).data $(ROOT)/verilator/memory_init_tb.mem

else ifeq ($(CORE),hornet)
# ---------------- main core: IMEM / DMEM images, upstream startup code and drivers ----------------
HORNET_SW  = $(ROOT)/HORNET-RV32IMF/sw
IMEM_SIZE  ?= 0x10000
DMEM_SIZE  ?= 0x10000
STACK_SIZE ?= 0x8000
CCFLAGS = $(COMMON_FLAGS) -march=rv32im_zicsr_zifencei -g -I$(HORNET_SW)/drivers \
          -nostartfiles -specs=nano.specs -T $(HORNET_SW)/common/link.ld \
          -Wl,--defsym=__imem_size=$(IMEM_SIZE) -Wl,--defsym=__dmem_size=$(DMEM_SIZE) \
          -Wl,--defsym=__stack_size=$(STACK_SIZE) -Wl,--defsym=__imem_origin=0 -Wl,--defsym=__dmem_skip=0 \
          -Wl,--no-warn-rwx-segments
STARTUP = $(HORNET_SW)/common/crt0.S $(HORNET_SW)/common/syscalls.c $(HORNET_SW)/drivers/uart.c \
          $(HORNET_SW)/drivers/gpio.c $(HORNET_SW)/drivers/timer.c $(HORNET_SW)/drivers/irq.c

define build_image
	$(1)-gcc hornet_kyber.c $(KYBER_SRC) $(STARTUP) $(CCFLAGS) -o $(TARGET).elf
	python3 $(ROOT)/scripts/elf2hex.py $(TARGET).elf $(TARGET).imem.hex 0x00000000 $(IMEM_SIZE)
	python3 $(ROOT)/scripts/elf2hex.py $(TARGET).elf $(TARGET).dmem.hex 0x10000000 $(DMEM_SIZE)
	$(1)-size $(TARGET).elf
endef

copy_mem:
	cp $(TARGET).imem.hex $(ROOT)/verilator/imem.hex
	cp $(TARGET).dmem.hex $(ROOT)/verilator/dmem.hex

else
$(error CORE=$(CORE): use hornet or legacy)
endif

# Expected Kyber outputs, computed on the host with the software Keccak
kyber_kat.h: gen_kat.c $(KYBER_SRC)
	$(HOSTCC) -O2 -DKECCAK_SW -I../ gen_kat.c $(KYBER_SRC) -o gen_kat
	./gen_kat > $@

build: kyber_kat.h
	$(call build_image,$(CC32))

build_multilib: kyber_kat.h
	$(call build_image,$(CC64))

clean:
	rm -f *.elf *.bin *.data *.hex memory_init_tb.mem gen_kat kyber_kat.h

.PHONY: build build_multilib copy_mem clean
