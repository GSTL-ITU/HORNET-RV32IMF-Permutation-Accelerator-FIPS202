# HORNET-RV32IMF with Permutation Accelerator for Keccak (FIPS202)

This repository contains a hardware/software environment for the Keccak-f[1600] permutation accelerator (FIPS 202 standard) integrated with the HORNET-RV32IMF processor architecture.

It includes full RTL hardware designs, C reference code, unit testbenches, and automated build verification scripts using Verilator.

The added accelerator `keccak_accelerator_wb` is connected only via the Wishbone bus interface (slave 4, `0x1000_9000 - 0x1000_9FFF`). No modifications are made inside the core itself.
Software modifications are made so the core sends the data through the accelerator address range.

**STATUS:** Only ML-KEM (Kyber768) has been tested so far.

## Accelerator

- One full Keccak-f[1600] round per clock cycle: **24 cycles per permutation**.
- The 1600-bit state lives inside the accelerator and is directly readable/writable over the bus.
  Software absorbs by XORing into the state and squeezes by reading it, so one-shot hashes
  (`sha3_256`, `sha3_512`, `shake128`, `shake256`) never copy the state to RAM.

| Offset          | Name   | Access | Description |
| :-------------- | :----- | :----- | :---------- |
| `0x000`         | CTRL   | W      | bit0 = start permutation, bit1 = clear state (ignored while busy) |
|                 |        | R      | bit0 = busy |
| `0x010`         | STATUS | R      | bit0 = done (cleared on start), bit1 = busy |
|                 |        | W      | bit0 is written into done |
| `0x020 - 0x0E7` | STATE  | R/W    | 50 words; lane *i* = `{word 2i+1, word 2i}` (little-endian) |
| `0x120 - 0x1E7` | XOR    | W      | 50 words; written data is XORed into the state (reads return STATE) |

State/XOR writes are ignored while busy; byte enables (`wb_sel_i`) are honoured.
The C driver is in `test/ml-kem-kyber/fips202.c`; register offsets are in `test/ml-kem-kyber/params.h`.

### DMA version

Two SoC tops exist side by side in `source/sources_1/imports/src/`:

| Top                    | Accelerator                 | Description |
| :--------------------- | :-------------------------- | :---------- |
| `barebones_wb_top`     | `keccak_accelerator_wb`     | CPU moves every word over the bus |
| `barebones_wb_top_dma` | `keccak_accelerator_dma_wb` | Accelerator has a Wishbone master and moves data to/from RAM itself |

`keccak_accelerator_dma_wb` wraps the unchanged `keccak_accelerator_wb` (same register map at
`0x000 - 0x1E7`, so non-DMA firmware runs on it unmodified) and adds a DMA engine. Its master port
shares memory port 1 with the core's data bus; the core always has priority, so core timing is
unchanged and the DMA uses the cycles in which the core does not access RAM (1 word per cycle).

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
`RATE`) sets done + error. The driver (`-DKECCAK_DMA`) uses DMA for word-aligned buffers and falls back
to register access otherwise.

## Project Structure

```
├─ keccak_test/         # Unit tests for both accelerators (RTL vs reference C)
├─ rom_gen/             # ROM generator
├─ source/              # RTL source for Hornet Core and peripherals
├─ test/                # PQC source codes and makefiles
├─ verilator/           # Verilator build files
├─ cbr.sh               # Auto -build & test- script
├─ cycle_report.txt     # Cycle count reports
└─ changes.log          # Change log
```

## Prerequisites

- gcc (host, also used to generate the Kyber known-answer header)
- riscv32-unknown-elf toolchain
- verilator
- make

## Usage and Verification

To compile, build and run the PQC source codes in the Hornet bare-metal configuration, simply run:
```sh
bash cbr.sh                # accelerator, barebones_wb_top
DMA=1 bash cbr.sh          # accelerator with DMA, barebones_wb_top_dma
KECCAK_SW=1 bash cbr.sh    # software Keccak reference
```
`DMA=1` selects both the firmware driver (`make build DMA=1` in `test/ml-kem-kyber/test`) and the
simulated top (`make run DMA=1` in `verilator/`, built into `obj_dir_dma`). A DMA firmware image needs the
DMA top; the non-DMA firmware runs on either top. The testbench gives up after 100M cycles (`TEST TIMEOUT`).
The testbench prints the cycle number of every debug-interface write and stops on `P` (pass) or `F` (fail).
Before the KEM tests the firmware runs FIPS 202 known-answer tests (fails with code `H` = 72), and the
Kyber keypair/ciphertext/shared secret are compared against a host run with the software Keccak
(`gen_kat.c` -> `kyber_kat.h`, fails with code `K` = 75).

To run the accelerator unit tests, use the makefile in `keccak_test`:
```sh
cd keccak_test
make            # both tests
make test       # keccak_accelerator_wb only
make test_dma   # keccak_accelerator_dma_wb only
```
Both simulate the RTL from `source/sources_1/imports/src/` directly and compare it against the reference
C permutation.
- `test`: single permutation, back-to-back permutations, the clear command, absorbing via the XOR window
  with byte-enable writes, and writes during a busy permutation.
- `test_dma`: a RAM model with pseudo-random stalls; multi-block ABSORB with tail, ABSORB of an exact
  multiple of the rate, multi-block SQUEEZE with a partial last word (bytes past the end must stay
  untouched), LOAD/STORE, rejected commands, and CPU accesses while the DMA is busy.

### Contact
Ali Barış Bozoğlu: [bozoglu20@itu.edu.tr](mailto:bozoglu20@itu.edu.tr) - [GitHub](https://github.com/alibarisbozoglu)


**Original README for more info:**

---

# HORNET-RV32IMF: A RV32IMF RISC-V SoC

![Status](https://img.shields.io/badge/Status-Completed-success)
![Hardware](https://img.shields.io/badge/Target-Nexys%20Video%20%7C%20Nexys--4--DDR-blue)
![ISA](https://img.shields.io/badge/ISA-RV32IMF-orange)
![Toolchain](https://img.shields.io/badge/Vivado-2025.2-red)

**HORNET-RV32IMF** is an academic-grade, 5-stage pipelined RISC-V soft-core processor designed for high-efficiency floating-point arithmetic and Edge AI applications. It implements the **RV32IMF** Instruction Set Architecture (ISA) and is optimized for deployment across Xilinx Artix-7 platforms, including the Nexys Video and Nexys-4-DDR.

---



---

## 👥 Contributors & Research

This project is the result of collaborative engineering at the **Istanbul Technical University (ITU)** and the **GSTL Lab**.

### 🎓 Academic Advisor
* **Prof. Dr. Sıddıka Berna Örs Yalçın** - [ITU Academic Profile](https://web.itu.edu.tr/~orssi/)

### 🏛️ Core Creators
* **Yavuz Selim Tozlu** - [GitHub](https://github.com/yavuz650)
* **Yasin Yılmaz** - [GitHub](https://github.com/yasinxyz)

### 📐 FPU Design & Implementation
* **Salih Daysal**
* **Mehmet Emin Tuzcu**

### 🧪 Verification
* **Deniz Zakir Eroglu** - [GitHub](https://github.com/dezariye)
* **Mete Kaan Özden** - [GitHub](https://github.com/mkozden)

### ✏️ Organization
* **Deniz Zakir Eroglu** - [GitHub](https://github.com/dezariye)
* **Yusuf Tekin** - [GitHub](https://github.com/jsphtkn)

### 📎 Projects
* **Yusuf Tekin** & **Ahmet Tolga Özkan**- 
🔗 **[HORNET-RV32IMF-For-AI-Applications](https://github.com/GSTL-ITU/HORNET-RV32IMF-For-AI-Applications)**

### 📚 Academic Publications
The initial design of Hornet core is detailed in the following conference paper:
> Y. S. Tozlu, Y. Yilmaz, B. Ors, “Design and Implementation Of a 32-Bit RISC-V Core”, 12th International Conference on Electrical and Electronics Engineering (ELECO), 2021. 

The verification methodologies used in this core are detailed in the following conference paper:
> D. Z. Eroglu, M. K. Ozden, B. Ors, “Creating Verification Environment Using RISCV-DV With Open and Closed Source Tools”, 9th International Symposium on Multidisciplinary Studies and Innovative Technologies (ISMSIT), 2025.

---

## ⚙️ Hardware Specifications

| Parameter | Specification |
| :--- | :--- |
| **ISA** | RV32IMF (Integer, Multiply/Divide, Single-Precision Floating Point) |
| **Pipeline** | 5-Stage In-Order |
| **FPU** | IEEE-754 Single-Precision Hardware Unit |
| **Max Frequency** | 26.25 MHz (Target: Nexys-4-DDR & Nexys Video) |
| **Interconnect** | Wishbone |
| **Peripherals** | UART (Interrupt-driven), GPIO, MTIME, Debug Interface |

---

## 🛠️ Toolchain & Setup

### **Software Requirements**
* **Toolchain:** `riscv32-unknown-elf-gcc` (RV32IMF / ILP32F)
* **Simulation:** Vivado Simulator / Verilator
* **Python:** 3.x (with `pyserial` for hardware-in-the-loop tests)

### **Hardware Requirements**
* **FPGA:** Nexys-4-DDR (Artix-7 100t) or Nexys Video (Artix-7 200t)
* **Vivado Version:** Verified on **Vivado 2025.2**

---

## 📂 Project Structure

* **`source/`**: RTL Verilog files for the core, FPU, and Wishbone peripherals.
* **`drivers/`**: Bare-metal C drivers for UART, GPIO, and Interrupt handling.
* **`test/`**: Comprehensive test suites including FPU arithmetic, Bubble Sort, and MLP Neural Network inference.
* **`rom_gen/`**: Custom tools to convert compiled binaries into FPGA-ready `.mem` files.

---

## 🚀 Quick Start

1.  **Generate Firmware:** Navigate to `test/gpio` or `test/uart-fpu-fpga` and run `make build`.
2.  **Synthesis:** Load the `source/` files into Vivado 2025.2. Ensure the generated `memory_init.mem` is linked to the BRAM initialization.
3.  **Deploy:** Program the Nexys-4-DDR and monitor the output via the USB-UART bridge (Baud: 115200).

---

## 👤 Contact & Support

For technical inquiries or bug reports, please open an issue in this repository or contact the organizers:
* **Yusuf Tekin:** [tekiny20@itu.edu.tr](mailto:tekiny20@itu.edu.tr) - [GitHub Profile](https://github.com/jsphtkn)
* **Deniz Zakir Eroglu:** [eroglud20@itu.edu.tr](mailto:eroglud20@itu.edu.tr) - [GitHub Profile](https://github.com/dezariye)

---
*Developed at Istanbul Technical University. 🐝*