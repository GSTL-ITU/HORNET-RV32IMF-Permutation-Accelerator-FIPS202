#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include "fips202.h"

// Mirrors the test sequence in rtl/keccak_accelerator_wb_tb.v using the reference permutation.
static void dump_state(FILE *f, const uint64_t state[25]) {
    for (int i = 0; i < 25; i++) {
        fprintf(f, "%016" PRIx64 "\n", state[i]);
    }
}

int main(void) {
    uint64_t in[25], state[25];
    FILE *file_in, *file_out;

    file_in = fopen("../test_data_in.hex", "r");
    if (file_in == NULL) {
        fprintf(stderr, "ERROR: Could not open 'test_data_in.hex'!\n");
        return EXIT_FAILURE;
    }

    for (int i = 0; i < 25; i++) {
        if (fscanf(file_in, "%" SCNx64, &in[i]) != 1) {
            fprintf(stderr, "ERROR: Failed to read from 'test_data_in.hex'.\n");
            fclose(file_in);
            return EXIT_FAILURE;
        }
    }
    fclose(file_in);
    printf("[SW] Read data from 'test_data_in.hex'.\n");

    file_out = fopen("../test_data_out_sw.hex", "w");
    if (file_out == NULL) {
        fprintf(stderr, "ERROR: Could not create 'test_data_out_sw.hex'!\n");
        return EXIT_FAILURE;
    }

    // 1-4. P(in), P^2(in), P^3(in), P^4(in)
    for (int i = 0; i < 25; i++) state[i] = in[i];
    for (int k = 0; k < 4; k++) {
        KeccakF1600_StatePermute(state);
        dump_state(file_out, state);
    }

    // 5. P(0)
    for (int i = 0; i < 25; i++) state[i] = 0;
    KeccakF1600_StatePermute(state);
    dump_state(file_out, state);

    // 6. P(0 ^ in)
    for (int i = 0; i < 25; i++) state[i] = in[i];
    KeccakF1600_StatePermute(state);
    dump_state(file_out, state);

    // 7. P(P(in) ^ in)
    for (int i = 0; i < 25; i++) state[i] ^= in[i];
    KeccakF1600_StatePermute(state);
    dump_state(file_out, state);

    fclose(file_out);
    printf("[SW] Output written into 'test_data_out_sw.hex'.\n");

    return EXIT_SUCCESS;
}
