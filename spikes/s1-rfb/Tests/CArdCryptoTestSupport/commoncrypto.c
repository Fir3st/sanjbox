/* Test-only independent system implementation; legacy MD5 is required by S4. */
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <stddef.h>
#include <stdint.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
int ard_oracle_decrypt(const uint8_t *shared, size_t width, const uint8_t *cipher, uint8_t *plain) {
    uint8_t key[16]; size_t count=0;
    if(!CC_MD5(shared,(CC_LONG)width,key))return 0;
    return CCCrypt(kCCDecrypt,kCCAlgorithmAES,kCCOptionECBMode,key,16,NULL,cipher,128,plain,128,&count)==kCCSuccess && count==128;
}
#pragma clang diagnostic pop
