#!/bin/bash
# Compile, build and run ML-KEM on the Hornet SoC in Verilator.
#   bash cbr.sh                         HORNET-RV32IMF main, accelerator  (hornet_soc_keccak)
#   DMA=1 bash cbr.sh                   HORNET-RV32IMF main, accelerator with DMA (hornet_soc_keccak_dma)
#   KECCAK_SW=1 bash cbr.sh             software Keccak reference
#   CORE=legacy bash cbr.sh             HORNET-RV32IMF legacy (barebones_wb_top_keccak, DMA=1: _dma)

set -e

IS_MULTILIB=${IS_MULTILIB:-0}
KECCAK_SW=${KECCAK_SW:-0}
DMA=${DMA:-0}
CORE=${CORE:-hornet}

###########################################

cd "$(dirname "$0")/test/ml-kem-kyber/test"

if [ "$IS_MULTILIB" -eq 1 ]; then
    echo "MULTILIB"
    make build_multilib CORE="$CORE" KECCAK_SW="$KECCAK_SW" DMA="$DMA"
else
    make build CORE="$CORE" KECCAK_SW="$KECCAK_SW" DMA="$DMA"
fi
make copy_mem CORE="$CORE"

cd ../../../verilator

make run CORE="$CORE" DMA="$DMA"
