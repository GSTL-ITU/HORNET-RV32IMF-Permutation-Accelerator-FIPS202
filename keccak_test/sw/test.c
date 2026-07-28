#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <inttypes.h>
#include "fips202.h"

int main(void) {
    uint64_t state[25];
    FILE *file_in, *file_out;

    file_in = fopen("../test_data_in.hex", "r");
    if (file_in == NULL) {
        fprintf(stderr, "ERROR: Could not open 'test_data_in.hex'!\n");
        return EXIT_FAILURE;
    }

    for (int i = 0; i < 25; i++) {
        if (fscanf(file_in, "%" SCNx64, &state[i]) != 1) {
            fprintf(stderr, "ERROR: Failed to read from 'test_data_in.hex'.\n");
        }
    }
    fclose(file_in);
    printf("[SW] Read data from 'test_data_in.hex'.\n");

    KeccakF1600_StatePermute(state);
    printf("[SW] Executed KeccakF1600_StatePermute.\n");

    file_out = fopen("../test_data_out_sw.hex", "w");
    if (file_out == NULL) {
        fprintf(stderr, "ERRROR: Could not create 'test_data_out.hex'!\n");
        return EXIT_FAILURE;
    }

    for (int i = 0; i < 25; i++) {
        fprintf(file_out, "%016" PRIx64 "\n", state[i]);
    }
    fclose(file_out);
    printf("[SW] Output written into 'test_data_out_sw.hex'.\n");

    return EXIT_SUCCESS;
}