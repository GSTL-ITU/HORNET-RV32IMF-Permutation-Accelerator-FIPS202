/*
 * SPHINCS+ (sphincsplus/ref, SHAKE parameter sets) on the HORNET SoC with the Keccak accelerator.
 *
 *   1. SHAKE256 known-answer tests through the one-shot and the incremental API.
 *   2. Keypair, signature and verification; pk, sk and the signature are compared against a host
 *      run of the same code with the software Keccak (gen_kat.c -> sphincs_kat.h).
 *   3. A signature with one flipped bit, and a signature over a changed message, must not verify.
 *
 * Progress codes (report.h): 'S' start, 40 keypair, 41 sign, 42 verify, 43 negative tests,
 * then 'P' or a failure code followed by 'F'.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "api.h"
#include "params.h"
#include "fips202.h"
#include "randombytes.h"
#include "sphincs_kat.h"
#include "../../common/report.h"   // debug interface (legacy core) or UART + exit code (main core)

#define MLEN 32
#define XOF_LEN 300

// Failure codes reported before 'F'
#define FAIL_FIPS202 'H'  // SHAKE known-answer test mismatch
#define FAIL_KAT     'K'  // pk / sk / signature differ from the software-Keccak reference
#define FAIL_VERIFY  'V'  // valid signature rejected
#define FAIL_FORGE   'X'  // modified signature or message accepted

static uint8_t sig[SPX_BYTES];

static void fail(char code)
{
  report(code);
  report('F');
  while(1) { __asm__ volatile ("nop"); }
}

static int test_fips202(void)
{
  // SHAKE256 of the empty string (FIPS 202 example, 32 bytes)
  static const uint8_t shake256_empty[32] = {
    0x46, 0xb9, 0xdd, 0x2b, 0x0b, 0xa8, 0x8d, 0x13, 0x23, 0x3b, 0x3f, 0xeb, 0x74, 0x3e, 0xeb, 0x24,
    0x3f, 0xcd, 0x52, 0xea, 0x62, 0xb8, 0x1b, 0x82, 0xb5, 0x0c, 0x27, 0x64, 0x6e, 0xd5, 0x76, 0x2f };
  static uint8_t msg[200];
  uint8_t out[XOF_LEN];
  uint64_t s_inc[26];
  int r = 0;

  memset(msg, 0xa3, sizeof(msg));

  shake256(out, 32, msg, 0);
  r |= memcmp(out, shake256_empty, 32);

  shake256(out, XOF_LEN, msg, sizeof(msg));
  r |= memcmp(out, KAT_SHAKE256_A3, XOF_LEN);

  // incremental API: odd and unaligned chunks, crossing block boundaries on both sides
  memset(out, 0, sizeof(out));
  shake256_inc_init(s_inc);
  shake256_inc_absorb(s_inc, msg, 0);
  shake256_inc_absorb(s_inc, msg, 1);
  shake256_inc_absorb(s_inc, msg + 1, 70);
  shake256_inc_absorb(s_inc, msg + 71, 129);
  shake256_inc_finalize(s_inc);
  shake256_inc_squeeze(out, 7, s_inc);
  shake256_inc_squeeze(out + 7, 150, s_inc);
  shake256_inc_squeeze(out + 157, 143, s_inc);
  r |= memcmp(out, KAT_SHAKE256_A3, XOF_LEN);

  // incremental API: whole (word-aligned) buffer in one call, as H_msg does with the message
  memset(out, 0, sizeof(out));
  shake256_inc_init(s_inc);
  shake256_inc_absorb(s_inc, msg, sizeof(msg));
  shake256_inc_finalize(s_inc);
  shake256_inc_squeeze(out, XOF_LEN, s_inc);
  r |= memcmp(out, KAT_SHAKE256_A3, XOF_LEN);

  return r;
}

int main(void)
{
  uint8_t pk[SPX_PK_BYTES];
  uint8_t sk[SPX_SK_BYTES];
  uint8_t m[MLEN];
  uint8_t h[32];
  size_t siglen;

  report('S');

  if(test_fips202())
    fail(FAIL_FIPS202);

  // same order of randombytes() calls as gen_kat.c
  randombytes(m, MLEN);

  report(40);
  crypto_sign_keypair(pk, sk);
  report(41);
  crypto_sign_signature(sig, &siglen, m, MLEN, sk);
  report(42);
  if(crypto_sign_verify(sig, siglen, m, MLEN, pk))
    fail(FAIL_VERIFY);
  report(43);

  shake256(h, 32, sig, siglen);
  if(siglen != SPX_BYTES || memcmp(m, KAT_M, MLEN) || memcmp(pk, KAT_PK, sizeof(pk)) ||
     memcmp(sk, KAT_SK, sizeof(sk)) || memcmp(h, KAT_SIG_SHAKE256, 32))
    fail(FAIL_KAT);

  // one flipped bit in the signature (in the last WOTS+ / auth path part, i.e. the top layer)
  sig[SPX_BYTES - 1] ^= 0x01;
  if(!crypto_sign_verify(sig, siglen, m, MLEN, pk))
    fail(FAIL_FORGE);
  sig[SPX_BYTES - 1] ^= 0x01;

  // valid signature, changed message
  m[0] ^= 0x80;
  if(!crypto_sign_verify(sig, siglen, m, MLEN, pk))
    fail(FAIL_FORGE);

  report('P');

  while(1) { __asm__ volatile ("nop"); }

  return 0;
}
