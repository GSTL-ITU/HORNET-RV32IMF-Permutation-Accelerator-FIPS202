/*
 * SHAKE for SPHINCS+ (sphincsplus/ref/fips202.h API) on the Keccak accelerator.
 * Replaces sphincsplus/ref/fips202.c; with -DKECCAK_SW the Makefile builds that file instead.
 *
 * SPHINCS+ uses the one-shot shake256() for every tweakable hash (thash, PRF) and the incremental
 * shake256_inc_*() only for H_msg / PRF_msg. The one-shot functions keep the state in the
 * accelerator; the incremental ones keep it in RAM (s_inc[0..24], s_inc[25] = byte position, as
 * in the reference) and move it into the accelerator once per call.
 *
 * Like sphincsplus/ref/fips202.c, only SHAKE256 is implemented (one-shot and incremental), although
 * fips202.h declares more.
 */
#include <stddef.h>
#include <stdint.h>
#include "fips202.h"
#include "../common/keccak_acc.h"

#define SHAKE_DS 0x1F

static void inc_init(uint64_t *s_inc)
{
  unsigned int i;

  for(i = 0; i < 25; i++)
    s_inc[i] = 0;
  s_inc[25] = 0;
}

/* s_inc[25]: bytes absorbed into the current block */
static void inc_absorb(uint64_t *s_inc, unsigned int r, const uint8_t *m, size_t mlen)
{
  unsigned int pos = (unsigned int)s_inc[25];
  size_t n;

  if(!mlen)
    return;
  acc_load(s_inc);
#ifdef KECCAK_DMA
  if(pos == 0 && DMA_ALIGNED(m)) {
    /* permutes after every full block and absorbs the tail at offset 0 */
    acc_dma(KECCAK_DMA_ABSORB, m, mlen, r);
    pos = (unsigned int)(mlen % r);
    mlen = 0;
  }
#endif
  while(pos + mlen >= r) {
    n = r - pos;
    acc_xor_bytes(pos, m, n);
    acc_permute();
    m += n;
    mlen -= n;
    pos = 0;
  }
  acc_xor_bytes(pos, m, mlen);
  pos += (unsigned int)mlen;
  acc_store(s_inc);
  s_inc[25] = pos;
}

/* After finalize s_inc[25] counts the bytes of the current block not yet squeezed (0: permute first) */
static void inc_finalize(uint64_t *s_inc, unsigned int r, uint8_t p)
{
  unsigned int pos = (unsigned int)s_inc[25];

  s_inc[pos >> 3] ^= (uint64_t)p << 8*(pos & 7);
  s_inc[(r-1) >> 3] ^= (uint64_t)128 << 8*((r-1) & 7);
  s_inc[25] = 0;
}

static void inc_squeeze(uint8_t *out, size_t outlen, uint64_t *s_inc, unsigned int r)
{
  unsigned int avail = (unsigned int)s_inc[25];
  unsigned int i;
  size_t n;

  /* bytes left over in RAM from the previous call */
  for(i = 0; i < avail && outlen; i++, outlen--)
    *out++ = (uint8_t)(s_inc[(r - avail + i) >> 3] >> 8*((r - avail + i) & 7));
  avail -= i;

  if(outlen) {
    acc_load(s_inc);
    while(outlen) {
      acc_permute();
      n = outlen < r ? outlen : r;
      acc_read_bytes(out, n);
      out += n;
      outlen -= n;
      avail = r - (unsigned int)n;
    }
    acc_store(s_inc);
  }
  s_inc[25] = avail;
}

void shake256_inc_init(uint64_t *s_inc)
{
  inc_init(s_inc);
}

void shake256_inc_absorb(uint64_t *s_inc, const uint8_t *input, size_t inlen)
{
  inc_absorb(s_inc, SHAKE256_RATE, input, inlen);
}

void shake256_inc_finalize(uint64_t *s_inc)
{
  inc_finalize(s_inc, SHAKE256_RATE, SHAKE_DS);
}

void shake256_inc_squeeze(uint8_t *output, size_t outlen, uint64_t *s_inc)
{
  inc_squeeze(output, outlen, s_inc, SHAKE256_RATE);
}

void shake256(uint8_t *output, size_t outlen, const uint8_t *input, size_t inlen)
{
  acc_hash(output, outlen, SHAKE256_RATE, input, inlen, SHAKE_DS);
}
