#include <stddef.h>
#include <stdint.h>
#include <membership.h>
int ard_test_response(uint16_t, const uint8_t *, const uint8_t *, size_t,
    const uint8_t *, size_t, const uint8_t *, size_t, const uint8_t *, const uint8_t *,
    const uint8_t *, uint8_t *, uint8_t *, int);
int ard_test_digest(const uint8_t *, size_t, uint8_t *);
int ard_test_encrypt(const uint8_t *, const uint8_t *, uint8_t *);
int ard_test_has_named_group(const uint8_t *, size_t, uint16_t);
int ard_oracle_decrypt(const uint8_t *, size_t, const uint8_t *, uint8_t *);
