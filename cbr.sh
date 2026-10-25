#!/bin/bash
# Compile, build and run ML-KEM on the Hornet SoC in Verilator.
#   bash cbr.sh              accelerator build (barebones_wb_top)
#   DMA=1 bash cbr.sh        accelerator with DMA (barebones_wb_top_dma)
#   KECCAK_SW=1 bash cbr.sh  software Keccak reference build

set -e

IS_MULTILIB=${IS_MULTILIB:-0}
KECCAK_SW=${KECCAK_SW:-0}
DMA=${DMA:-0}

###########################################

cd "$(dirname "$0")/test/ml-kem-kyber/test"

if [ "$IS_MULTILIB" -eq 1 ]; then
    echo "MULTILIB"
    make build_multilib KECCAK_SW="$KECCAK_SW" DMA="$DMA"
else
    make build KECCAK_SW="$KECCAK_SW" DMA="$DMA"
fi
make copy_mem

cd ../../../verilator

make run DMA="$DMA"
