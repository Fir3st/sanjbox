/* Test-only independent system backend. No OpenSSL linkage or implementation reuse. */
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    uint8_t header[2], shared[512], plain[128], key[16], cipher[128]; size_t written=0;
    if(fread(header,1,2,stdin)!=2)return 1;
    size_t width=(size_t)header[0]*256+header[1];
    if(width<128||width>512||fread(shared,1,width,stdin)!=width||fread(plain,1,128,stdin)!=128||getchar()!=EOF)return 2;
    if(!CC_MD5(shared,(CC_LONG)width,key))return 3;
    if(CCCrypt(kCCEncrypt,kCCAlgorithmAES,kCCOptionECBMode,key,16,NULL,plain,128,cipher,128,&written)!=kCCSuccess||written!=128)return 4;
    for(size_t i=0;i<16;i++)printf("%02x",key[i]);
    putchar('\n');
    for(size_t i=0;i<128;i++)printf("%02x",cipher[i]);
    putchar('\n');
    return 0;
}
