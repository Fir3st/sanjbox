/* Compile the exact adapter with deterministic seams only in this test target. */
#define ARD_TESTING 1
#define ard_crypto_response ard_test_random_response
#include "../../Sources/CArdCrypto/ard_crypto.c"
