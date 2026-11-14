#include <ard_crypto.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <openssl/crypto.h>

/* Binary stdin only: A3D1 | g:u16 | width:u16 | userLen:u16 | passLen:u16 |
 * modulus | peer | username | password. Exactly one frame followed by EOF.
 * stdout: A3R1 | status:u16 | length:u16 | response; never diagnostics. */
static unsigned u16(const uint8_t *p) { return (unsigned)p[0] * 256 + p[1]; }
int main(int argc, char **argv) {
    uint8_t input[1163] = {0}, output[648] = {'A','3','R','1',0,0,0,0};
    size_t count = 0, sent = 0, output_len = 8;
    int status = ARD_INPUT;
    if (argc != 2 || strcmp(argv[1], "--synthetic-stdio-v1")) return 2;
    for (;;) {
        ssize_t got = read(STDIN_FILENO, input + count, sizeof(input) - count);
        if (got < 0 && errno == EINTR) continue;
        if (got < 0) goto done;
        if (got == 0) break;
        count += (size_t)got;
        if (count == sizeof(input)) goto done;
    }
    if (count < 12 || memcmp(input,"A3D1",4)) goto done;
    size_t width = u16(input+6), user_len = u16(input+8), pass_len = u16(input+10);
    if (width < 128 || width > 512 || user_len > 63 || pass_len > 63
        || count != 12 + 2*width + user_len + pass_len) goto done;
    status = ard_crypto_response((uint16_t)u16(input+4), input+12, input+12+width,
        width, input+12+2*width, user_len, input+12+2*width+user_len, pass_len, output+8);
    if (status == ARD_OK) {
        output_len += 128+width;
        output[6] = (uint8_t)((128+width)>>8); output[7] = (uint8_t)(128+width);
    }
done:
    output[5] = (uint8_t)status;
    OPENSSL_cleanse(input,sizeof(input));
    while (sent < output_len) {
        ssize_t n = write(STDOUT_FILENO,output+sent,output_len-sent);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { OPENSSL_cleanse(output,sizeof(output)); return 3; }
        sent += (size_t)n;
    }
    OPENSSL_cleanse(output,sizeof(output));
    return 0;
}
