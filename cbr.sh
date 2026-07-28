#!/bin/bash

IS_MULTILIB=0

###########################################

cd test/ml-kem-kyber/test

if [ $IS_MULTILIB -eq 1 ]; then
    echo "MULTILIB"
    make build_multilib
else
    make build
fi
make copy_mem

cd ../../../verilator

make run
