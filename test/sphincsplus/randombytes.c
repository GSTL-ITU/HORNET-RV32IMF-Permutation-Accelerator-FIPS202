/*
 * Deterministic randombytes() for SPHINCS+ (replaces sphincsplus/ref/randombytes.c, which reads
 * /dev/urandom). Same SHAKE256 generator and seed as test/ml-kem-kyber/randombytes.c, so the
 * host (gen_kat.c) and the SoC produce the same keys and signatures.
 * Not a secure RNG: a real system seeds this from a TRNG.
 */
#include <stddef.h>
#include <stdint.h>
#include "randombytes.h"
#include "fips202.h"

static uint8_t prng_state[32] = {
  0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
  0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F,
  0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
  0x18, 0x19, 0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F
};

void randombytes(unsigned char *x, unsigned long long xlen)
{
  uint8_t buffer[64 + 32];
  size_t n, i;

  while(xlen) {
    n = xlen < 64 ? (size_t)xlen : 64;
    shake256(buffer, n + 32, prng_state, 32);
    for(i = 0; i < n; i++)
      x[i] = buffer[i];
    for(i = 0; i < 32; i++)
      prng_state[i] = buffer[n + i];
    x += n;
    xlen -= n;
  }
}
