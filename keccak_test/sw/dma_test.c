#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include "fips202.h"

// Mirrors the test sequence in rtl/keccak_accelerator_dma_wb_tb.v: a byte-level model of the
// DMA commands on top of the reference permutation.

static uint8_t ram[4096];
static uint8_t st[200];

static void permute(void) {
    uint64_t s[25];

    for (int i = 0; i < 25; i++) {
        s[i] = 0;
        for (int b = 0; b < 8; b++)
            s[i] |= (uint64_t)st[8 * i + b] << (8 * b);
    }
    KeccakF1600_StatePermute(s);
    for (int i = 0; i < 25; i++)
        for (int b = 0; b < 8; b++)
            st[8 * i + b] = s[i] >> (8 * b);
}

static size_t min_sz(size_t a, size_t b) { return a < b ? a : b; }

// XOR len bytes from RAM, permuting after every full rate block
static void dma_absorb(size_t addr, size_t len, size_t rate) {
    while (len) {
        size_t n = min_sz(len, rate);
        for (size_t i = 0; i < n; i++)
            st[i] ^= ram[addr + i];
        addr += n;
        len -= n;
        if (n == rate)
            permute();
    }
}

// Repeat { permute; write min(rate, left) bytes to RAM }
static void dma_squeeze(size_t addr, size_t len, size_t rate) {
    while (len) {
        size_t n = min_sz(len, rate);
        permute();
        memcpy(&ram[addr], st, n);
        addr += n;
        len -= n;
    }
}

static void dump(FILE *f, size_t addr, size_t len) {
    for (size_t i = 0; i < len; i++)
        fprintf(f, "%02x\n", ram[addr + i]);
}

int main(void) {
    FILE *file_out = fopen("../dma_out_sw.hex", "w");
    if (file_out == NULL) {
        fprintf(stderr, "ERROR: Could not create 'dma_out_sw.hex'!\n");
        return EXIT_FAILURE;
    }

    memset(ram, 0xA5, sizeof(ram));
    for (int i = 0; i < 1024; i++)
        ram[i] = (uint8_t)(7 * i + 3);

    // 1. ABSORB 300 B @ 136 (CPU writes while busy are ignored), pad, SQUEEZE 301 B
    memset(st, 0, sizeof(st));
    dma_absorb(0x000, 300, 136);
    st[28] ^= 0x1F;
    st[135] ^= 0x80;
    dma_squeeze(0x800, 301, 136);
    dump(file_out, 0x800, 304);

    // 2. ABSORB 336 B @ 168, pad, SQUEEZE 168 B
    memset(st, 0, sizeof(st));
    dma_absorb(0x000, 336, 168);
    st[0] ^= 0x1F;
    st[167] ^= 0x80;
    dma_squeeze(0xA00, 168, 168);
    dump(file_out, 0xA00, 168);

    // 3. LOAD 200 B, permute, STORE 200 B and 13 B
    memcpy(st, &ram[0x100], 200);
    permute();
    memcpy(&ram[0xC00], st, 200);
    memcpy(&ram[0xD00], st, 13);
    dump(file_out, 0xC00, 200);
    dump(file_out, 0xD00, 16);

    // 4. Rejected commands leave the state and RAM untouched

    // 5. ABSORB 3 B @ 136, pad, SQUEEZE 32 B
    memset(st, 0, sizeof(st));
    dma_absorb(0x000, 3, 136);
    st[3] ^= 0x06;
    st[135] ^= 0x80;
    dma_squeeze(0xE00, 32, 136);
    dump(file_out, 0xE00, 36);

    fclose(file_out);
    printf("[SW] Output written into 'dma_out_sw.hex'.\n");

    return EXIT_SUCCESS;
}
