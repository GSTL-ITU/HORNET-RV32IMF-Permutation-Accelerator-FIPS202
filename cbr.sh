#!/bin/bash
# Compile, build and run ML-KEM on the Hornet SoC in Verilator.
#   bash cbr.sh              accelerator build
#   KECCAK_SW=1 bash cbr.sh  software Keccak reference build

set -e

IS_MULTILIB=${IS_MULTILIB:-0}
KECCAK_SW=${KECCAK_SW:-0}

###########################################

cd "$(dirname "$0")/test/ml-kem-kyber/test"

if [ "$IS_MULTILIB" -eq 1 ]; then
    echo "MULTILIB"
    make build_multilib KECCAK_SW="$KECCAK_SW"
else
    make build KECCAK_SW="$KECCAK_SW"
fi
make copy_mem

cd ../../../verilator

make run
