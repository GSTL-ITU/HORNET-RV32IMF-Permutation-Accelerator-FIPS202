#ifndef PARAMS_H
#define PARAMS_H

#ifndef KYBER_K
#define KYBER_K 3	/* Change this for different security strengths */
#endif

/* Keccak accelerator (keccak_accelerator_wb). Build with -DKECCAK_SW for the software permutation. */
#define KECCAK_BASE_ADDR   0x10009000u
#define KECCAK_CTRL_OFS    0x000u  /* W: bit0 start, bit1 clear state; R: bit0 busy */
#define KECCAK_STATUS_OFS  0x010u  /* R: bit0 done, bit1 busy; W: bit0 -> done */
#define KECCAK_STATE_OFS   0x020u  /* 50 words, R/W */
#define KECCAK_XOR_OFS     0x120u  /* 50 words, write XORs into the state */
/* DMA registers, keccak_accelerator_dma_wb only. Build with -DKECCAK_DMA to use them. */
#define KECCAK_DMA_ADDR_OFS   0x200u  /* RAM address (word aligned) */
#define KECCAK_DMA_LEN_OFS    0x204u  /* length in bytes */
#define KECCAK_DMA_RATE_OFS   0x208u  /* rate in bytes for ABSORB/SQUEEZE */
#define KECCAK_DMA_CTRL_OFS   0x20Cu  /* W: 1 ABSORB, 2 SQUEEZE, 3 LOAD, 4 STORE; R: bit0 busy */
#define KECCAK_DMA_STATUS_OFS 0x210u  /* R: bit0 done, bit1 busy, bit2 error; W: bit0 -> done */

/* Don't change parameters below this line */
#if   (KYBER_K == 2)
#define KYBER_NAMESPACE(s) pqcrystals_kyber512_ref_##s
#elif (KYBER_K == 3)
#define KYBER_NAMESPACE(s) pqcrystals_kyber768_ref_##s
#elif (KYBER_K == 4)
#define KYBER_NAMESPACE(s) pqcrystals_kyber1024_ref_##s
#else
#error "KYBER_K must be in {2,3,4}"
#endif

#define KYBER_N 256
#define KYBER_Q 3329

#define KYBER_SYMBYTES 32   /* size in bytes of hashes, and seeds */
#define KYBER_SSBYTES  32   /* size in bytes of shared key */

#define KYBER_POLYBYTES		384
#define KYBER_POLYVECBYTES	(KYBER_K * KYBER_POLYBYTES)

#if KYBER_K == 2
#define KYBER_ETA1 3
#define KYBER_POLYCOMPRESSEDBYTES    128
#define KYBER_POLYVECCOMPRESSEDBYTES (KYBER_K * 320)
#elif KYBER_K == 3
#define KYBER_ETA1 2
#define KYBER_POLYCOMPRESSEDBYTES    128
#define KYBER_POLYVECCOMPRESSEDBYTES (KYBER_K * 320)
#elif KYBER_K == 4
#define KYBER_ETA1 2
#define KYBER_POLYCOMPRESSEDBYTES    160
#define KYBER_POLYVECCOMPRESSEDBYTES (KYBER_K * 352)
#endif

#define KYBER_ETA2 2

#define KYBER_INDCPA_MSGBYTES       (KYBER_SYMBYTES)
#define KYBER_INDCPA_PUBLICKEYBYTES (KYBER_POLYVECBYTES + KYBER_SYMBYTES)
#define KYBER_INDCPA_SECRETKEYBYTES (KYBER_POLYVECBYTES)
#define KYBER_INDCPA_BYTES          (KYBER_POLYVECCOMPRESSEDBYTES + KYBER_POLYCOMPRESSEDBYTES)

#define KYBER_PUBLICKEYBYTES  (KYBER_INDCPA_PUBLICKEYBYTES)
/* 32 bytes of additional space to save H(pk) */
#define KYBER_SECRETKEYBYTES  (KYBER_INDCPA_SECRETKEYBYTES + KYBER_INDCPA_PUBLICKEYBYTES + 2*KYBER_SYMBYTES)
#define KYBER_CIPHERTEXTBYTES (KYBER_INDCPA_BYTES)

#endif
