#ifndef SANJBOX_ARD_CRYPTO_H
#define SANJBOX_ARD_CRYPTO_H
#include <stddef.h>
#include <stdint.h>
enum { ARD_OK = 0, ARD_INPUT = 1, ARD_PARAMETERS = 2, ARD_PEER = 3, ARD_BACKEND = 4 };
/* Synthetic-only type-30 operation. out has 128 + width bytes; cleared on failure. */
int ard_crypto_response(uint16_t generator, const uint8_t *modulus,
    const uint8_t *peer, size_t width, const uint8_t *username, size_t username_len,
    const uint8_t *password, size_t password_len, uint8_t *out);
#endif
