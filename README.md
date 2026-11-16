# HORNET-RV32IMF with Permutation Accelerator for Keccak (FIPS202)

This repository contains a hardware/software environment for the Keccak-f[1600] permutation accelerator (FIPS 202 standard) for the HORNET-RV32IMF processor.
The accelerator works with both generations of the core, which are included as submodules:

| Submodule                | Upstream branch | Bus       | Accelerators |
| :----------------------- | :-------------- | :-------- | :----------- |
| `HORNET-RV32IMF/`        | `main`          | AXI4-Lite | `keccak_accelerator_axil`, `keccak_accelerator_dma_axil` |
| `HORNET-RV32IMF-legacy/` | `legacy`        | Wishbone  | `legacy_keccak_accelerator_wb`, `legacy_keccak_accelerator_dma_wb` |

No modifications are made inside the cores or the submodules; the accelerators are added as bus slaves (and, for DMA, a bus master) in SoC tops that live in this repository.
Software modifications are made so the core sends the data through the accelerator address range.

```sh
git clone --recurse-submodules <this repo>
# or, in an existing clone:
git submodule update --init
```

**STATUS:** ML-KEM (Kyber768) passes on both cores in simulation (FIPS 202 known-answer tests and a
cross-check against a software-Keccak host run). The FPGA build of the main core with the accelerator
meets timing at 50 MHz on the Nexys 4 DDR; it has not been run on a board yet.

## Accelerator

- One full Keccak-f[1600] round per clock cycle: **24 cycles per permutation**.
- The 1600-bit state lives inside the accelerator and is directly readable/writable over the bus.
  Software absorbs by XORing into the state and squeezes by reading it, so one-shot hashes
  (`sha3_256`, `sha3_512`, `shake128`, `shake256`) never copy the state to RAM.
- Same register map on both cores (offsets from the accelerator base):

| Core   | Base address  | SoC top |
| :----- | :------------ | :------ |
| main   | `0x6000_0000` | `soc/hornet/hornet_soc_keccak.v` (4 KiB in the external AXI range, parameter `KECCAK_BASE`) |
| legacy | `0x1000_9000` | `soc/legacy/barebones_wb_top_keccak.v` (Wishbone slave 4, `0x1000_9000 - 0x1000_9FFF`) |

| Offset          | Name   | Access | Description |
| :-------------- | :----- | :----- | :---------- |
| `0x000`         | CTRL   | W      | bit0 = start permutation, bit1 = clear state (ignored while busy) |
|                 |        | R      | bit0 = busy |
| `0x010`         | STATUS | R      | bit0 = done (cleared on start), bit1 = busy |
|                 |        | W      | bit0 is written into done |
| `0x020 - 0x0E7` | STATE  | R/W    | 50 words; lane *i* = `{word 2i+1, word 2i}` (little-endian) |
| `0x120 - 0x1E7` | XOR    | W      | 50 words; written data is XORed into the state (reads return STATE) |

State/XOR writes are ignored while busy; byte enables (`wstrb` / `wb_sel_i`) are honoured.
The C driver is in `test/ml-kem-kyber/fips202.c`; the base address and register offsets are in
`test/ml-kem-kyber/params.h` (`-DHORNET_LEGACY` selects the legacy base address).

### DMA version

| Top (main, `soc/hornet/`) | Top (legacy, `soc/legacy/`)   | Accelerator | Description |
| :------------------------ | :---------------------------- | :---------- | :---------- |
| `hornet_soc_keccak`       | `barebones_wb_top_keccak`     | `keccak_accelerator_axil` / `legacy_keccak_accelerator_wb` | CPU moves every word over the bus |
| `hornet_soc_keccak_dma`   | `barebones_wb_top_keccak_dma` | `keccak_accelerator_dma_axil` / `legacy_keccak_accelerator_dma_wb` | Accelerator has a bus master and moves data to/from RAM itself |

The DMA accelerators keep the same register map at `0x000 - 0x1E7` (so non-DMA firmware runs on them
unmodified) and add a DMA engine. The master port shares memory with the core's data bus; the core
always has priority, so core timing is unchanged and the DMA uses the cycles in which the core does not
access memory (1 word per cycle).

- main: the AXI4-Lite master reaches IMEM (port B) and DMEM through `soc/hornet/axil_mem_port.v` in
  `hornet_soc_dma` (a copy of `hornet_soc` with that one addition). Buffers may be in DMEM or in IMEM
  (e.g. `.rodata`); other addresses answer DECERR and the command ends with ERROR set.
- legacy: the Wishbone master shares memory port 1 with the core.

| Offset  | Name       | Access | Description |
| :------ | :--------- | :----- | :---------- |
| `0x200` | DMA_ADDR   | R/W    | RAM byte address (word aligned) |
| `0x204` | DMA_LEN    | R/W    | length in bytes |
| `0x208` | DMA_RATE   | R/W    | rate in bytes (multiple of 4, 4..200) for ABSORB/SQUEEZE |
| `0x20C` | DMA_CTRL   | W      | command: 1 ABSORB, 2 SQUEEZE, 3 LOAD, 4 STORE (ignored while busy) |
|         |            | R      | bit0 = busy |
| `0x210` | DMA_STATUS | R      | bit0 = done (cleared on start), bit1 = busy, bit2 = error |
|         |            | W      | bit0 is written into done |

- **ABSORB**: XOR `LEN` bytes from RAM into the state from byte 0, permuting after every full `RATE` block.
  A trailing partial block is absorbed but not permuted; padding is done by software through the XOR window.
- **SQUEEZE**: repeat { permute; write min(`RATE`, remaining) bytes to RAM }.
- **LOAD / STORE**: copy the first `LEN` (<= 200) state bytes from / to RAM.

Partial words use byte enables, so RAM past `LEN` is never written. While the DMA is busy, CPU
accesses to `0x000 - 0x1FF` are acknowledged but ignored. A rejected command (unknown command or bad
`RATE`) sets done + error; on the main core an error response on the master port does too, and DONE is
only set once every write has been acknowledged. The driver (`-DKECCAK_DMA`) uses DMA for word-aligned
buffers and falls back to register access otherwise.

On the main core the accelerator's DONE (DMA DONE for the DMA version) is also ORed into `irq_i[0]`
(fast interrupt 2). `hornet_soc_keccak` and `hornet_soc_keccak_dma` have the same parameters and ports
as `hornet_soc`, so they are drop-in replacements.

## Project Structure

```
├─ HORNET-RV32IMF/          # submodule: HORNET-RV32IMF, main branch (AXI4-Lite SoC)
├─ HORNET-RV32IMF-legacy/   # submodule: HORNET-RV32IMF, legacy branch (Wishbone SoC)
├─ rtl/                     # Keccak accelerators
│  ├─ keccak_accelerator_core.v           # permutation + register file (shared by the AXI versions)
│  ├─ keccak_accelerator_axil.v           # main core, AXI4-Lite slave
│  ├─ keccak_accelerator_dma_axil.v       # main core, AXI4-Lite slave + DMA master
│  ├─ legacy_keccak_accelerator_wb.v      # legacy core, Wishbone slave
│  ├─ legacy_keccak_accelerator_dma_wb.v  # legacy core, Wishbone slave + DMA master
│  └─ lint.vlt                            # Verilator lint waivers
├─ soc/
│  ├─ hornet/               # main core: hornet_soc_keccak(_dma), hornet_soc_dma, axil_mem_port, testbench
│  └─ legacy/               # legacy core: barebones_wb_top_keccak(_dma), testbench, debug interface
├─ fpga/                    # main core: board top and Vivado scripts (Nexys 4 DDR, Nexys Video)
├─ keccak_test/             # Unit tests for the accelerators
├─ rom_gen/                 # ROM generator (legacy core)
├─ scripts/                 # elf2hex.py (IMEM/DMEM images for the main core)
├─ test/                    # PQC source codes and makefiles
├─ verilator/               # Verilator build files
├─ cbr.sh                   # Auto -build & test- script
├─ cycle_report.txt         # Cycle count reports
└─ changes.log              # Change log
```

The SoC tops reuse the submodules' RTL as is (see `verilator/Makefile` for the exact source lists):
- main: `HORNET-RV32IMF/rtl/{core,fpu,soc}/*.v` + `rtl/keccak_accelerator_*.v` + `soc/hornet/*.v`
- legacy: `HORNET-RV32IMF-legacy/source/sources_1/imports/src/*.v` except `fpga_top.v`, `barebones_wb_top.v`
  and `debug_interface_wb.v`, + `rtl/legacy_*.v` + `soc/legacy/*.v`

## Prerequisites

- gcc (host, also used to generate the Kyber known-answer header)
- riscv32-unknown-elf toolchain (with the `rv32im/ilp32` multilib and newlib-nano)
- verilator (5.x, `--timing`)
- make, python3
- Vivado (FPGA build only)

## Usage and Verification

To compile, build and run ML-KEM on the SoC in Verilator, run:
```sh
bash cbr.sh                          # main core, accelerator         (hornet_soc_keccak)
DMA=1 bash cbr.sh                    # main core, accelerator + DMA   (hornet_soc_keccak_dma)
KECCAK_SW=1 bash cbr.sh              # main core, software Keccak reference
CORE=legacy bash cbr.sh              # legacy core, accelerator       (barebones_wb_top_keccak)
CORE=legacy DMA=1 bash cbr.sh        # legacy core, accelerator + DMA (barebones_wb_top_keccak_dma)
CORE=legacy KECCAK_SW=1 bash cbr.sh  # legacy core, software Keccak reference
```
`CORE` and `DMA` select both the firmware (`make build` in `test/ml-kem-kyber/test`) and the simulated
top (`make run` in `verilator/`, built into `obj_dir_<core>[_dma]`). A DMA firmware image needs the DMA
top; the non-DMA firmware runs on either top.

The firmware prints `cycle N : code` for every checkpoint (`S` = 83 start, 40..43 around keypair /
encapsulation / decapsulation, `P` = 80 pass, `F` = 70 fail) and ends with `TEST PASSED` / `TEST FAILED`.
Before the KEM tests it runs FIPS 202 known-answer tests (fails with code `H` = 72), and the Kyber
keypair/ciphertext/shared secret are compared against a host run with the software Keccak
(`gen_kat.c` -> `kyber_kat.h`, fails with code `K` = 75).
- main core: the cycle counter is read by the firmware and printed over the UART at the end; the
  simulation stops through the system control EXIT register (`PASS` / `FAIL` from the testbench,
  timeout 200M cycles, `make run TIMEOUT=...`).
- legacy core: codes go to the debug interface; the testbench prints the cycle of each write, stops on
  `P` / `F` and gives up after 100M cycles (`TEST TIMEOUT`).

Results are in `cycle_report.txt`.

To run the accelerator unit tests, use the makefile in `keccak_test`:
```sh
cd keccak_test
make                 # all four tests
make legacy          # test + test_dma
make axil            # test_axil + test_dma_axil
```
- `test`: `legacy_keccak_accelerator_wb` against the reference C permutation: single permutation,
  back-to-back permutations, the clear command, absorbing via the XOR window with byte-enable writes,
  and writes during a busy permutation.
- `test_dma`: `legacy_keccak_accelerator_dma_wb` against the reference C model with a RAM model with
  pseudo-random stalls; multi-block ABSORB with tail, ABSORB of an exact multiple of the rate,
  multi-block SQUEEZE with a partial last word (bytes past the end must stay untouched), LOAD/STORE,
  rejected commands, and CPU accesses while the DMA is busy.
- `test_axil`: `keccak_accelerator_axil` against `legacy_keccak_accelerator_wb`, 20000 random operations
  with random AXI backpressure; every read must match.
- `test_dma_axil`: `keccak_accelerator_dma_axil` against `legacy_keccak_accelerator_dma_wb`, 1500 random
  DMA commands against a stalling Wishbone RAM and an AXI4-Lite RAM with random readies and latencies;
  state, registers and all of memory must match after every command, AXI valid/payload stability is
  checked every cycle, plus error-response tests.

### FPGA (main core)

`fpga/hornet_board_keccak.v` is the upstream board top (`HORNET-RV32IMF/fpga/common/hornet_board.v`)
with `hornet_soc_keccak`, or `hornet_soc_keccak_dma` with `KECCAK_DMA = 1`. `fpga/build.tcl` and
`fpga/create_project.tcl` use the submodule's board definitions and constraints.
```sh
cd fpga
make build                   # ML-KEM firmware + bitstream, Nexys 4 DDR, 50 MHz
make build DMA=1             # with the DMA accelerator
make build BOARD=nexysvideo  # other board
make project [DMA=1]         # Vivado GUI project
make program [DMA=1]         # program the board over JTAG
```
Outputs go to `fpga/build/<board>-<keccak|keccak_dma>/` (bitstream, `timing.rpt`, `utilization*.rpt`,
`result.txt`). The firmware prints its cycle report over the UART (115200 baud) after reset.

### Contact
Ali Barış Bozoğlu: [bozoglu20@itu.edu.tr](mailto:bozoglu20@itu.edu.tr) - [GitHub](https://github.com/alibarisbozoglu)

The HORNET-RV32IMF core, its documentation and its contributors are described in the submodules'
`README.md` files.
