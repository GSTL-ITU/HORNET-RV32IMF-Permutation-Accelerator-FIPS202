/*
 * Keccak accelerator driver, shared by the test programs (ml-kem-kyber, sphincsplus).
 *
 * HORNET-RV32IMF main: keccak_accelerator_(dma_)axil in soc/hornet/hornet_soc_keccak(_dma).v (KECCAK_BASE)
 * HORNET-RV32IMF legacy (-DHORNET_LEGACY): legacy_keccak_accelerator_(dma_)wb, Wishbone slave 4
 *
 * The state lives in the accelerator; 64-bit lane i is word 2i (low) and 2i+1 (high),
 * i.e. byte offset n of the Keccak state is byte n of the word window.
 *
 * With -DKECCAK_DMA (requires a DMA top: hornet_soc_keccak_dma, or barebones_wb_top_keccak_dma on
 * the legacy core) word-aligned buffers are moved by the accelerator's DMA engine; unaligned ones
 * fall back to register access.
 */
#ifndef KECCAK_ACC_H
#define KECCAK_ACC_H

#include <stddef.h>
#include <stdint.h>

#ifdef HORNET_LEGACY
#define KECCAK_BASE_ADDR   0x10009000u
#else
#define KECCAK_BASE_ADDR   0x60000000u
#endif
#define KECCAK_CTRL_OFS    0x000u  /* W: bit0 start, bit1 clear state; R: bit0 busy */
#define KECCAK_STATUS_OFS  0x010u  /* R: bit0 done, bit1 busy; W: bit0 -> done */
#define KECCAK_STATE_OFS   0x020u  /* 50 words, R/W */
#define KECCAK_XOR_OFS     0x120u  /* 50 words, write XORs into the state */
/* DMA registers, DMA versions only. Build with -DKECCAK_DMA to use them. */
#define KECCAK_DMA_ADDR_OFS   0x200u  /* RAM address (word aligned) */
#define KECCAK_DMA_LEN_OFS    0x204u  /* length in bytes */
#define KECCAK_DMA_RATE_OFS   0x208u  /* rate in bytes for ABSORB/SQUEEZE */
#define KECCAK_DMA_CTRL_OFS   0x20Cu  /* W: 1 ABSORB, 2 SQUEEZE, 3 LOAD, 4 STORE; R: bit0 busy */
#define KECCAK_DMA_STATUS_OFS 0x210u  /* R: bit0 done, bit1 busy, bit2 error; W: bit0 -> done */
/* not every program uses every helper */
#define ACC_FN static __attribute__((unused))

#define KECCAK_CTRL   (*(volatile uint32_t *)(KECCAK_BASE_ADDR + KECCAK_CTRL_OFS))
#define KECCAK_STATUS (*(volatile uint32_t *)(KECCAK_BASE_ADDR + KECCAK_STATUS_OFS))
#define KECCAK_STATE  ((volatile uint32_t *)(KECCAK_BASE_ADDR + KECCAK_STATE_OFS))
#define KECCAK_XOR    ((volatile uint32_t *)(KECCAK_BASE_ADDR + KECCAK_XOR_OFS))

#define KECCAK_CTRL_START 0x1u
#define KECCAK_CTRL_CLEAR 0x2u
#define KECCAK_STATUS_DONE 0x1u

ACC_FN void acc_permute(void)
{
  KECCAK_CTRL = KECCAK_CTRL_START;
  while(!(KECCAK_STATUS & KECCAK_STATUS_DONE))
    ;
}

ACC_FN void acc_clear(void)
{
  KECCAK_CTRL = KECCAK_CTRL_CLEAR;
}

#ifdef KECCAK_DMA
#define KECCAK_DMA_ADDR   (*(volatile uint32_t *)(KECCAK_BASE_ADDR + KECCAK_DMA_ADDR_OFS))
#define KECCAK_DMA_LEN    (*(volatile uint32_t *)(KECCAK_BASE_ADDR + KECCAK_DMA_LEN_OFS))
#define KECCAK_DMA_RATE   (*(volatile uint32_t *)(KECCAK_BASE_ADDR + KECCAK_DMA_RATE_OFS))
#define KECCAK_DMA_CTRL   (*(volatile uint32_t *)(KECCAK_BASE_ADDR + KECCAK_DMA_CTRL_OFS))
#define KECCAK_DMA_STATUS (*(volatile uint32_t *)(KECCAK_BASE_ADDR + KECCAK_DMA_STATUS_OFS))

#define KECCAK_DMA_ABSORB  1u
#define KECCAK_DMA_SQUEEZE 2u
#define KECCAK_DMA_LOAD    3u
#define KECCAK_DMA_STORE   4u

#define DMA_ALIGNED(p) ((((uintptr_t)(p)) & 3) == 0)

/* Run one DMA command and wait for it. The "memory" clobbers make the compiler flush pending
   stores to the buffer before the DMA reads it, and reload it after the DMA wrote it. */
ACC_FN void acc_dma(uint32_t cmd, const void *addr, size_t len, unsigned int r)
{
  __asm__ volatile ("" ::: "memory");
  KECCAK_DMA_ADDR = (uint32_t)(uintptr_t)addr;
  KECCAK_DMA_LEN  = len;
  KECCAK_DMA_RATE = r;
  KECCAK_DMA_CTRL = cmd;
  while(!(KECCAK_DMA_STATUS & KECCAK_STATUS_DONE))
    ;
  __asm__ volatile ("" ::: "memory");
}

ACC_FN void acc_load(const uint64_t s[25])
{
  acc_dma(KECCAK_DMA_LOAD, s, 200, 0);
}

ACC_FN void acc_store(uint64_t s[25])
{
  acc_dma(KECCAK_DMA_STORE, s, 200, 0);
}
#else
ACC_FN void acc_load(const uint64_t s[25])
{
  unsigned int i;
  for(i=0;i<25;i++) {
    KECCAK_STATE[2*i]   = (uint32_t)s[i];
    KECCAK_STATE[2*i+1] = (uint32_t)(s[i] >> 32);
  }
}

ACC_FN void acc_store(uint64_t s[25])
{
  unsigned int i;
  for(i=0;i<25;i++)
    s[i] = (uint64_t)KECCAK_STATE[2*i] | ((uint64_t)KECCAK_STATE[2*i+1] << 32);
}
#endif

/* XOR inlen bytes into the state starting at byte offset pos */
ACC_FN void acc_xor_bytes(unsigned int pos, const uint8_t *in, size_t inlen)
{
  unsigned int n;
  uint32_t w;

  while(inlen) {
    w = 0;
    for(n=0; (pos & 3) + n < 4 && n < inlen; n++)
      w |= (uint32_t)in[n] << 8*((pos & 3) + n);
    KECCAK_XOR[pos >> 2] = w;
    pos += n;
    in += n;
    inlen -= n;
  }
}

/* Read outlen bytes of the state starting at byte offset 0 */
ACC_FN void acc_read_bytes(uint8_t *out, size_t outlen)
{
  unsigned int i, n;
  uint32_t w;

  for(i=0; outlen; i++) {
    w = KECCAK_STATE[i];
    for(n=0; n < 4 && outlen; n++, outlen--)
      *out++ = w >> 8*n;
  }
}

/* Zero the state, absorb in and pad; the result is left in the accelerator (not permuted) */
ACC_FN void acc_absorb_once(unsigned int r, const uint8_t *in, size_t inlen, uint8_t p)
{
  const uint8_t pad = 0x80;

  acc_clear();
#ifdef KECCAK_DMA
  if(DMA_ALIGNED(in)) {
    /* permutes after every full block and absorbs the tail */
    acc_dma(KECCAK_DMA_ABSORB, in, inlen, r);
    inlen %= r;
  }
  else
#endif
  {
    while(inlen >= r) {
      acc_xor_bytes(0, in, r);
      acc_permute();
      in += r;
      inlen -= r;
    }
    acc_xor_bytes(0, in, inlen);
  }
  acc_xor_bytes(inlen, &p, 1);
  acc_xor_bytes(r-1, &pad, 1);
}

/* Absorb once, then squeeze outlen bytes; the state never leaves the accelerator */
ACC_FN void acc_hash(uint8_t *out, size_t outlen, unsigned int r,
                     const uint8_t *in, size_t inlen, uint8_t p)
{
  size_t n;

  acc_absorb_once(r, in, inlen, p);
#ifdef KECCAK_DMA
  if(DMA_ALIGNED(out)) {
    acc_dma(KECCAK_DMA_SQUEEZE, out, outlen, r);
    return;
  }
#endif
  while(outlen) {
    acc_permute();
    n = outlen < r ? outlen : r;
    acc_read_bytes(out, n);
    out += n;
    outlen -= n;
  }
}

#endif
