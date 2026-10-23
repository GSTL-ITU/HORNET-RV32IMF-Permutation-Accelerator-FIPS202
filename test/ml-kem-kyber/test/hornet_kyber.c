#include <stddef.h>
#include <stdint.h>
#include <string.h> // Retained: memcpy, memset, memcmp

// Adjusted include paths based on the new directory tree
#include "../kem.h"
#include "../randombytes.h"
#include "../fips202.h"
#include "kyber_kat.h"

// Hornet Debug Interface
#define DEBUG_IF_ADDR 0x10008010
#define DEBUG_REG     ((volatile char *)DEBUG_IF_ADDR)

// Reduced iterations for bare-metal FPGA simulation speed
#define NTESTS 1

// Failure codes written to the debug interface before 'F'
#define FAIL_FIPS202 'H'  // FIPS 202 known-answer test mismatch
#define FAIL_KAT     'K'  // Kyber output differs from the software-Keccak reference

static int hexcmp(const uint8_t *x, const char *hex, size_t len)
{
  size_t i;
  unsigned int hi, lo;

  for(i = 0; i < len; i++) {
    hi = (hex[2*i]   <= '9') ? hex[2*i]   - '0' : hex[2*i]   - 'a' + 10;
    lo = (hex[2*i+1] <= '9') ? hex[2*i+1] - '0' : hex[2*i+1] - 'a' + 10;
    if(x[i] != ((hi << 4) | lo))
      return 1;
  }
  return 0;
}

// FIPS 202 known-answer tests (expected values from Python hashlib). Covers single and
// multi-block absorb, the rate-1 / rate padding boundaries, multi-block squeeze and the
// incremental API used by Kyber's PRF/XOF.
static int test_fips202(void)
{
  static uint8_t msg[200];
  uint8_t out[504];
  uint8_t h[64];
  keccak_state st;
  int r = 0;

  memset(msg, 0xa3, sizeof(msg));

  sha3_256(h, (const uint8_t *)"abc", 3);
  r |= hexcmp(h, "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532", 32);
  sha3_512(h, (const uint8_t *)"abc", 3);
  r |= hexcmp(h, "b751850b1a57168a5693cd924b6b096e08f621827444f70d884f5d0240d2712e"
                 "10e116e9192af3c91a7ec57647e3934057340b4cf408d5a56592f8274eec53f0", 64);
  shake128(h, 32, msg, 0);
  r |= hexcmp(h, "7f9c2ba4e88f827d616045507605853ed73b8093f6efbc88eb1a6eacfa66ef26", 32);
  shake256(h, 32, msg, 0);
  r |= hexcmp(h, "46b9dd2b0ba88d13233b3feb743eeb243fcd52ea62b81b82b50c27646ed5762f", 32);

  sha3_256(h, msg, 200);
  r |= hexcmp(h, "79f38adec5c20307a98ef76e8324afbfd46cfd81b22e3973c65fa1bd9de31787", 32);
  sha3_512(h, msg, 200);
  r |= hexcmp(h, "e76dfad22084a8b1467fcf2ffa58361bec7628edf5f3fdc0e4805dc48caeeca8"
                 "1b7c13c30adf52a3659584739a2df46be589c51ca1a4a8416df6545a1ce8ba00", 64);
  sha3_256(h, msg, 135);
  r |= hexcmp(h, "d51927265ca4bf0cc8b4453387700918c03f8894e395ad437d4573f3be4d2c34", 32);
  sha3_256(h, msg, 136);
  r |= hexcmp(h, "0adf6bfb359ae40019b67d8c49c361574b70242a6b752de6f9e0d426ca177f7a", 32);

  // SHAKE128, 3 squeezed blocks, via absorb_once + squeezeblocks (Kyber's XOF path)
  shake128_absorb_once(&st, msg, 200);
  shake128_squeezeblocks(out, 3, &st);
  sha3_256(h, out, 504);
  r |= hexcmp(h, "7792f75a2dab004c605238b90a085f92897ad6b77c0ea79385a35fb5343432e1", 32);

  // SHAKE256, 300 bytes, via the incremental API with odd chunk sizes
  shake256_init(&st);
  shake256_absorb(&st, msg, 1);
  shake256_absorb(&st, msg + 1, 70);
  shake256_absorb(&st, msg + 71, 129);
  shake256_finalize(&st);
  shake256_squeeze(out, 7, &st);
  shake256_squeeze(out + 7, 150, &st);
  shake256_squeeze(out + 157, 143, &st);
  sha3_256(h, out, 300);
  r |= hexcmp(h, "25443d97add7f2b76d7903cfdd293e8bc6f0c25b362687276c84d1fc863caa27", 32);

  return r;
}

static int test_keys(void)
{
  uint8_t pk[CRYPTO_PUBLICKEYBYTES];
  uint8_t sk[CRYPTO_SECRETKEYBYTES];
  uint8_t ct[CRYPTO_CIPHERTEXTBYTES];
  uint8_t key_a[CRYPTO_BYTES];
  uint8_t key_b[CRYPTO_BYTES];

  *DEBUG_REG = 40;

  // Alice generates a public key
  crypto_kem_keypair(pk, sk);
  *DEBUG_REG = 41;

  // Bob derives a secret key and creates a response
  crypto_kem_enc(ct, key_b, pk);
  *DEBUG_REG = 42;

  // Alice uses Bob's response to get her shared key
  crypto_kem_dec(key_a, ct, sk);
  *DEBUG_REG = 43;

  if(memcmp(key_a, key_b, CRYPTO_BYTES)) {
    return 1; // Fail flag
  }

  // Compare against the software-Keccak run of the same deterministic sequence (gen_kat.c)
  {
    uint8_t h[32];
    int k = 0;

    sha3_256(h, pk, sizeof(pk));
    k |= memcmp(h, KAT_PK_SHA3_256, 32);
    sha3_256(h, sk, sizeof(sk));
    k |= memcmp(h, KAT_SK_SHA3_256, 32);
    sha3_256(h, ct, sizeof(ct));
    k |= memcmp(h, KAT_CT_SHA3_256, 32);
    k |= memcmp(key_a, KAT_SS, CRYPTO_BYTES);
    if(k) {
      *DEBUG_REG = FAIL_KAT;
      return 1;
    }
  }

  return 0; // Pass flag
}

static int test_invalid_sk_a(void)
{
  uint8_t pk[CRYPTO_PUBLICKEYBYTES];
  uint8_t sk[CRYPTO_SECRETKEYBYTES];
  uint8_t ct[CRYPTO_CIPHERTEXTBYTES];
  uint8_t key_a[CRYPTO_BYTES];
  uint8_t key_b[CRYPTO_BYTES];

  crypto_kem_keypair(pk, sk);
  crypto_kem_enc(ct, key_b, pk);

  // Replace secret key with random values
  randombytes(sk, CRYPTO_SECRETKEYBYTES);

  crypto_kem_dec(key_a, ct, sk);

  // If the shared secrets MATCH despite a corrupted secret key, it's a failure
  if(!memcmp(key_a, key_b, CRYPTO_BYTES)) {
    return 1;
  }

  return 0;
}

static int test_invalid_ciphertext(void)
{
  uint8_t pk[CRYPTO_PUBLICKEYBYTES];
  uint8_t sk[CRYPTO_SECRETKEYBYTES];
  uint8_t ct[CRYPTO_CIPHERTEXTBYTES];
  uint8_t key_a[CRYPTO_BYTES];
  uint8_t key_b[CRYPTO_BYTES];
  uint8_t b;
  size_t pos;

  do {
    randombytes(&b, sizeof(uint8_t));
  } while(!b);
  randombytes((uint8_t *)&pos, sizeof(size_t));

  crypto_kem_keypair(pk, sk);
  crypto_kem_enc(ct, key_b, pk);

  // Change some byte in the ciphertext (i.e., encapsulated key)
  ct[pos % CRYPTO_CIPHERTEXTBYTES] ^= b;

  crypto_kem_dec(key_a, ct, sk);

  // If the shared secrets MATCH despite a corrupted ciphertext, it's a failure
  if(!memcmp(key_a, key_b, CRYPTO_BYTES)) {
    return 1;
  }

  return 0;
}

int main(void)
{
  // Signal start to TCL console
  *DEBUG_REG = 'S'; // 32'd83
  
  unsigned int i;
  int r = 0;

  if(test_fips202()) {
    *DEBUG_REG = FAIL_FIPS202;
    *DEBUG_REG = 'F';
    while(1) { __asm__ volatile ("nop"); }
  }

  for(i = 0; i < NTESTS; i++) {
    r |= test_keys();
    r |= test_invalid_sk_a();
    r |= test_invalid_ciphertext();
    
    if(r) {
      *DEBUG_REG = 'F'; // Signal Fail: 32'd70
      while(1) { __asm__ volatile ("nop"); }
    }
  }

  // If we made it through the loop, all tests passed
  *DEBUG_REG = 'P'; // Signal Pass: 32'd80
  
  // Trap the CPU to prevent executing junk memory
  while(1) { 
    __asm__ volatile ("nop"); 
  }

  return 0;
}