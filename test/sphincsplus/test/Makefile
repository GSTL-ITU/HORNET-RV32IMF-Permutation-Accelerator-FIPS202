CC32=riscv32-unknown-elf
CC64=riscv64-unknown-elf
HOSTCC=gcc
TARGET=sim_sphincs

ROOT = ../../..
SPX  = $(ROOT)/sphincsplus/ref

# SPHINCS+ (sphincsplus submodule, reference implementation) with the Keccak accelerator.
# `make build CORE=hornet` (default): HORNET-RV32IMF main, hornet_soc_keccak(_dma)
#     -> sim_sphincs.imem.hex / sim_sphincs.dmem.hex
# `make build CORE=legacy`: HORNET-RV32IMF legacy, barebones_wb_top_keccak(_dma)
#     -> sim_sphincs.data (memory_init_tb.mem)
# PARAMS: any SHAKE set of sphincsplus/ref/params (the signature is a static buffer: on the main
# core 192f/256f need a larger DMEM_SIZE). THASH: simple or robust.
CORE   ?= hornet
PARAMS ?= sphincs-shake-128f
THASH  ?= simple

ifeq (,$(findstring shake,$(PARAMS)))
$(error PARAMS=$(PARAMS): only the SHAKE parameter sets use Keccak)
endif

# SPHINCS+ does not use the FPU; same code generation on both cores
COMMON_FLAGS = -mabi=ilp32 -ffp-contract=off -mstrict-align -malign-data=xlen -O2 -fno-math-errno \
               -ffunction-sections -fdata-sections -Wl,--gc-sections -DPARAMS=$(PARAMS) -I$(SPX)
# merkle.c passes an unsigned int[] as uint32_t *; on riscv32-elf uint32_t is unsigned long (same
# size), which GCC >= 14 rejects by default
COMMON_FLAGS += -Wno-error=incompatible-pointer-types

SPX_SRC = $(addprefix $(SPX)/,address.c merkle.c wots.c wotsx1.c utils.c utilsx1.c fors.c sign.c \
                              hash_shake.c thash_shake_$(THASH).c)

# `make build KECCAK_SW=1`: reference software Keccak (sphincsplus/ref/fips202.c), for reference numbers
# `make build DMA=1`: use the accelerator's DMA engine (needs the DMA top)
ifeq ($(KECCAK_SW),1)
FIPS202 = $(SPX)/fips202.c
else
FIPS202 = ../fips202.c
endif
ifeq ($(DMA),1)
COMMON_FLAGS += -DKECCAK_DMA
endif

SRC = hornet_sphincs.c $(SPX_SRC) $(FIPS202) ../randombytes.c

ifeq ($(CORE),legacy)
# ---------------- legacy core: unified RAM image from rom_gen ----------------
CCFLAGS = $(COMMON_FLAGS) -march=rv32im -DHORNET_LEGACY -T $(ROOT)/test/ml-kem-kyber/test/linksc.ld -nostartfiles
STARTUP = $(ROOT)/rom_gen/crt0.s
OBJCOPY_SECTIONS = -j .init -j .text -j .rodata -j .data -j .sdata

define build_image
	$(1)-gcc $(SRC) $(STARTUP) $(CCFLAGS) -o $(TARGET).elf
	$(1)-objcopy -O binary $(OBJCOPY_SECTIONS) $(TARGET).elf $(TARGET).bin
	$(ROOT)/rom_gen/rom_generator $(TARGET).bin
	$(1)-size $(TARGET).elf
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
	$(1)-gcc $(SRC) $(STARTUP) $(CCFLAGS) -o $(TARGET).elf
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

# Expected outputs, computed on the host with the software Keccak. Regenerated on every build,
# since they depend on PARAMS / THASH.
kat:
	$(HOSTCC) -O2 -DPARAMS=$(PARAMS) -I$(SPX) gen_kat.c $(SPX_SRC) $(SPX)/fips202.c ../randombytes.c -o gen_kat
	./gen_kat > sphincs_kat.h

build: kat
	$(call build_image,$(CC32))

build_multilib: kat
	$(call build_image,$(CC64))

clean:
	rm -f *.elf *.bin *.data *.hex gen_kat sphincs_kat.h

.PHONY: kat build build_multilib copy_mem clean
