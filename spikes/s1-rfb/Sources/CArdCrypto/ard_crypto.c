/* Repository-authored public-API adapter. Cryptography is OpenSSL 3.5.9. */
#include "include/ard_crypto.h"
#include <string.h>
#include <openssl/bn.h>
#include <openssl/core_names.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <openssl/param_build.h>
#include <openssl/provider.h>
#include <openssl/rand.h>
#include <openssl/opensslv.h>

#if OPENSSL_VERSION_MAJOR != 3 || OPENSSL_VERSION_MINOR != 5 || OPENSSL_VERSION_PATCH != 9
#error "WP1.A3 is approved and reviewed only with pinned OpenSSL 3.5.9"
#endif

static int digest(OSSL_LIB_CTX *ctx, const uint8_t *input, size_t len, uint8_t out[16]) {
    EVP_MD *md = EVP_MD_fetch(ctx, "MD5", "provider=default");
    unsigned int written = 0;
    int ok = md && EVP_Digest(input, len, out, &written, md, NULL) == 1 && written == 16;
    EVP_MD_free(md);
    return ok;
}

static int encrypt(OSSL_LIB_CTX *ctx, const uint8_t key[16], const uint8_t input[128], uint8_t out[128]) {
    EVP_CIPHER *cipher = EVP_CIPHER_fetch(ctx, "AES-128-ECB", "provider=default");
    EVP_CIPHER_CTX *cc = EVP_CIPHER_CTX_new();
    uint8_t scratch[144] = {0};
    int first = 0, last = 0;
    int ok = cc && cipher && EVP_EncryptInit_ex2(cc, cipher, key, NULL, NULL) == 1
        && EVP_CIPHER_CTX_set_padding(cc, 0) == 1
        && EVP_EncryptUpdate(cc, scratch, &first, input, 128) == 1
        && first == 128 && EVP_EncryptFinal_ex(cc, scratch + first, &last) == 1 && last == 0;
    if (ok) memcpy(out, scratch, 128);
    OPENSSL_cleanse(scratch, sizeof(scratch));
    EVP_CIPHER_CTX_free(cc);
    EVP_CIPHER_free(cipher);
    return ok;
}

static EVP_PKEY *import_key(OSSL_LIB_CTX *ctx, BIGNUM *p, BIGNUM *g,
    BIGNUM *pub, BIGNUM *priv, int selection) {
    EVP_PKEY *key = NULL;
    OSSL_PARAM_BLD *bld = OSSL_PARAM_BLD_new();
    OSSL_PARAM *params = NULL;
    EVP_PKEY_CTX *kc = EVP_PKEY_CTX_new_from_name(ctx, "DH", "provider=default");
    if (!bld || !kc || !OSSL_PARAM_BLD_push_BN(bld, OSSL_PKEY_PARAM_FFC_P, p)
        || !OSSL_PARAM_BLD_push_BN(bld, OSSL_PKEY_PARAM_FFC_G, g)
        || (pub && !OSSL_PARAM_BLD_push_BN(bld, OSSL_PKEY_PARAM_PUB_KEY, pub))
        || (priv && !OSSL_PARAM_BLD_push_BN(bld, OSSL_PKEY_PARAM_PRIV_KEY, priv))) goto done;
    params = OSSL_PARAM_BLD_to_param(bld);
    if (!params || EVP_PKEY_fromdata_init(kc) != 1
        || EVP_PKEY_fromdata(kc, &key, selection, params) != 1) {
        EVP_PKEY_free(key); key = NULL;
    }
done:
    OSSL_PARAM_free(params);
    OSSL_PARAM_BLD_free(bld);
    EVP_PKEY_CTX_free(kc);
    return key;
}

/* The deterministic branch is compiled ONLY into the test-support target. The
 * production worker has neither a deterministic wire command nor this entry point. */
static int response(uint16_t generator, const uint8_t *modulus, const uint8_t *peer,
    size_t width, const uint8_t *username, size_t username_len,
    const uint8_t *password, size_t password_len, uint8_t *out
#ifdef ARD_TESTING
    , const uint8_t *fixed_private, const uint8_t *fixed_public,
    const uint8_t *fixed_padding, uint8_t *shared_out, int fail_stage
#endif
) {
    int result = ARD_INPUT;
    OSSL_LIB_CTX *ctx = NULL;
    OSSL_PROVIDER *provider = NULL;
    BIGNUM *p = NULL, *g = NULL, *y = NULL, *public_value = NULL;
    EVP_PKEY *parameters = NULL, *remote = NULL, *local = NULL;
    EVP_PKEY_CTX *check = NULL, *keygen = NULL, *derive = NULL;
    uint8_t shared[512] = {0}, key[16] = {0}, plaintext[128] = {0};
    size_t shared_len = 0;
    unsigned int pad = 1;
    OSSL_PARAM derive_params[] = {
        OSSL_PARAM_uint(OSSL_EXCHANGE_PARAM_PAD, &pad), OSSL_PARAM_END
    };
    if (out && width >= 128 && width <= 512) memset(out, 0, 128 + width);
    if (!out || !modulus || !peer || (username_len && !username) || (password_len && !password)
        || width < 128 || width > 512 || generator < 2 || username_len > 63 || password_len > 63)
        return ARD_INPUT;
    memset(out, 0, 128 + width);
#ifdef ARD_TESTING
    if (shared_out) memset(shared_out, 0, width);
#endif
    /* Refuse another build even if headers and a different archive were mixed. */
    result = ARD_BACKEND;
    if (OpenSSL_version_num() != OPENSSL_VERSION_NUMBER
        || !OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG, NULL)) goto done;
    ctx = OSSL_LIB_CTX_new();
    if (!ctx || !(provider = OSSL_PROVIDER_load(ctx, "default"))) goto done;
    p = BN_bin2bn(modulus, (int)width, NULL);
    g = BN_new();
    y = BN_bin2bn(peer, (int)width, NULL);
    if (!p || !g || !y || !BN_set_word(g, generator)) goto done;
    result = ARD_PARAMETERS;
    if (BN_num_bits(p) < 1024 || BN_num_bits(p) > 4096) goto done;
    parameters = import_key(ctx, p, g, NULL, NULL, EVP_PKEY_KEY_PARAMETERS);
    check = parameters ? EVP_PKEY_CTX_new_from_pkey(ctx, parameters, "provider=default") : NULL;
    if (!check || EVP_PKEY_param_check(check) != 1) goto done;
    EVP_PKEY_CTX_free(check); check = NULL;
    /* q is absent on the wire. Full parameter checking validates a safe prime;
     * this peer check is a RANGE check, not an order-q membership claim. */
    result = ARD_PEER;
    remote = import_key(ctx, p, g, y, NULL, EVP_PKEY_PUBLIC_KEY);
    check = remote ? EVP_PKEY_CTX_new_from_pkey(ctx, remote, "provider=default") : NULL;
    if (!check || EVP_PKEY_public_check(check) != 1) goto done;
    EVP_PKEY_CTX_free(check); check = NULL;
    result = ARD_BACKEND;
#ifdef ARD_TESTING
    if (fail_stage == 1) goto done; /* key generation/entropy failure seam */
    if (fixed_private && fixed_public && fixed_padding) {
        BIGNUM *x = BN_secure_new(), *a = BN_bin2bn(fixed_public, (int)width, NULL);
        if (x && a && BN_bin2bn(fixed_private, (int)width, x))
            local = import_key(ctx, p, g, a, x, EVP_PKEY_KEYPAIR);
        BN_clear_free(x); BN_clear_free(a);
        check = local ? EVP_PKEY_CTX_new_from_pkey(ctx, local, "provider=default") : NULL;
        if (!check || EVP_PKEY_private_check(check) != 1 || EVP_PKEY_pairwise_check(check) != 1) goto done;
        EVP_PKEY_CTX_free(check); check = NULL;
    } else
#endif
    {
        keygen = EVP_PKEY_CTX_new_from_pkey(ctx, parameters, "provider=default");
        if (!keygen || EVP_PKEY_keygen_init(keygen) != 1 || EVP_PKEY_generate(keygen, &local) != 1) goto done;
    }
    if (!EVP_PKEY_get_bn_param(local, OSSL_PKEY_PARAM_PUB_KEY, &public_value)
        || BN_bn2binpad(public_value, out + 128, (int)width) != (int)width) goto done;
    derive = EVP_PKEY_CTX_new_from_pkey(ctx, local, "provider=default");
    if (!derive || EVP_PKEY_derive_init(derive) != 1
        || EVP_PKEY_CTX_set_params(derive, derive_params) != 1
        || EVP_PKEY_derive_set_peer(derive, remote) != 1
        || EVP_PKEY_derive(derive, NULL, &shared_len) != 1
        || shared_len == 0 || shared_len > width) goto done;
    /* EVP pads to effective p width; S4 hashes the original negotiated wire width. */
    size_t required = shared_len;
    if (EVP_PKEY_derive(derive, shared + width - required, &shared_len) != 1
        || shared_len != required) goto done;
#ifdef ARD_TESTING
    if (fail_stage == 2) goto done;
#endif
    if (!digest(ctx, shared, width, key)) goto done;
#ifdef ARD_TESTING
    if (fail_stage == 3) goto done; /* padding entropy failure seam */
    if (fixed_padding) memcpy(plaintext, fixed_padding, 128); else
#endif
    if (RAND_priv_bytes_ex(ctx, plaintext, 128, 0) != 1) goto done;
    if (username_len) memcpy(plaintext, username, username_len);
    plaintext[username_len] = 0;
    if (password_len) memcpy(plaintext + 64, password, password_len);
    plaintext[64 + password_len] = 0;
#ifdef ARD_TESTING
    if (fail_stage == 4) goto done;
#endif
    if (!encrypt(ctx, key, plaintext, out)) goto done;
#ifdef ARD_TESTING
    if (shared_out) memcpy(shared_out, shared, width);
#endif
    result = ARD_OK;
done:
    if (result != ARD_OK) memset(out, 0, 128 + width);
    OPENSSL_cleanse(shared, sizeof(shared));
    OPENSSL_cleanse(key, sizeof(key));
    OPENSSL_cleanse(plaintext, sizeof(plaintext));
    EVP_PKEY_CTX_free(check); EVP_PKEY_CTX_free(keygen); EVP_PKEY_CTX_free(derive);
    EVP_PKEY_free(parameters); EVP_PKEY_free(remote); EVP_PKEY_free(local);
    BN_clear_free(p); BN_clear_free(g); BN_clear_free(y); BN_clear_free(public_value);
    OSSL_PROVIDER_unload(provider); OSSL_LIB_CTX_free(ctx);
    return result;
}

int ard_crypto_response(uint16_t generator, const uint8_t *modulus,
    const uint8_t *peer, size_t width, const uint8_t *username, size_t username_len,
    const uint8_t *password, size_t password_len, uint8_t *out) {
    return response(generator, modulus, peer, width, username, username_len,
        password, password_len, out
#ifdef ARD_TESTING
        , NULL, NULL, NULL, NULL, 0
#endif
    );
}

#ifdef ARD_TESTING
int ard_test_has_named_group(const uint8_t *modulus, size_t width, uint16_t generator) {
    OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG, NULL);
    OSSL_LIB_CTX *ctx = OSSL_LIB_CTX_new();
    OSSL_PROVIDER *provider = ctx ? OSSL_PROVIDER_load(ctx, "default") : NULL;
    BIGNUM *p = BN_bin2bn(modulus,(int)width,NULL), *g = BN_new();
    EVP_PKEY *params = NULL;
    char name[80]; size_t written=0;
    if(provider && p && g && BN_set_word(g,generator)) params=import_key(ctx,p,g,NULL,NULL,EVP_PKEY_KEY_PARAMETERS);
    int named = params && EVP_PKEY_get_utf8_string_param(params,OSSL_PKEY_PARAM_GROUP_NAME,name,sizeof(name),&written)==1;
    EVP_PKEY_free(params); BN_free(p); BN_free(g);
    OSSL_PROVIDER_unload(provider); OSSL_LIB_CTX_free(ctx); return named;
}
int ard_test_response(uint16_t g, const uint8_t *p, const uint8_t *y, size_t width,
    const uint8_t *user, size_t user_len, const uint8_t *password, size_t password_len,
    const uint8_t *x, const uint8_t *pub, const uint8_t *padding,
    uint8_t *out, uint8_t *shared, int fail_stage) {
    return response(g,p,y,width,user,user_len,password,password_len,out,x,pub,padding,shared,fail_stage);
}
int ard_test_digest(const uint8_t *input, size_t len, uint8_t *out) {
    OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG, NULL);
    OSSL_LIB_CTX *ctx = OSSL_LIB_CTX_new();
    OSSL_PROVIDER *provider = ctx ? OSSL_PROVIDER_load(ctx, "default") : NULL;
    int ok = provider && digest(ctx,input,len,out);
    OSSL_PROVIDER_unload(provider); OSSL_LIB_CTX_free(ctx); return ok;
}
int ard_test_encrypt(const uint8_t *key, const uint8_t *input, uint8_t *out) {
    OPENSSL_init_crypto(OPENSSL_INIT_NO_LOAD_CONFIG, NULL);
    OSSL_LIB_CTX *ctx = OSSL_LIB_CTX_new();
    OSSL_PROVIDER *provider = ctx ? OSSL_PROVIDER_load(ctx, "default") : NULL;
    int ok = provider && encrypt(ctx,key,input,out);
    OSSL_PROVIDER_unload(provider); OSSL_LIB_CTX_free(ctx); return ok;
}
#endif
