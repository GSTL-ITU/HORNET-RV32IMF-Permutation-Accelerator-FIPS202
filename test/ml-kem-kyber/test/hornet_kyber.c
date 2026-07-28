#include <stddef.h>
#include <stdint.h>
#include <string.h> // Retained: memcpy, memset, memcmp

// Adjusted include paths based on the new directory tree
#include "../kem.h"
#include "../randombytes.h"

// Hornet Debug Interface
#define DEBUG_IF_ADDR 0x10008010
#define DEBUG_REG     ((volatile char *)DEBUG_IF_ADDR)

// Reduced iterations for bare-metal FPGA simulation speed
#define NTESTS 1

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