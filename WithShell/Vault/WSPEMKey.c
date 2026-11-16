#include "WSPEMKey.h"

#include <string.h>

#include <openssl/bio.h>
#include <openssl/bn.h>
#include <openssl/core_names.h>
#include <openssl/crypto.h>
#include <openssl/err.h>
#include <openssl/evp.h>
#include <openssl/pem.h>

typedef struct {
    const char *passphrase;
    int asked;
} pass_context;

/* 암호화된 키일 때만 호출된다. 패스프레이즈가 없으면 실패시켜 프롬프트를 띄우지 않는다. */
static int password_callback(char *buf, int size, int rwflag, void *userdata) {
    (void)rwflag;
    pass_context *ctx = (pass_context *)userdata;
    ctx->asked = 1;
    if (!ctx->passphrase || !*ctx->passphrase) return -1;
    size_t len = strlen(ctx->passphrase);
    if (len > (size_t)size) return -1;
    memcpy(buf, ctx->passphrase, len);
    return (int)len;
}

static int copy_bn(EVP_PKEY *pkey, const char *name, ws_pem_component *out) {
    BIGNUM *bn = NULL;
    if (!EVP_PKEY_get_bn_param(pkey, name, &bn)) return 0;
    int len = BN_num_bytes(bn);
    int ok = len > 0 && (size_t)len <= sizeof(out->bytes);
    if (ok) out->length = (size_t)BN_bn2bin(bn, out->bytes);
    BN_clear_free(bn);
    return ok;
}

static void set_error(ws_pem_key *out) {
    unsigned long code = ERR_peek_last_error();
    if (code) ERR_error_string_n(code, out->error, sizeof(out->error));
    ERR_clear_error();
}

ws_pem_status ws_pem_decode(const char *pem, const char *passphrase, ws_pem_key *out) {
    memset(out, 0, sizeof(*out));
    ERR_clear_error();

    BIO *bio = BIO_new_mem_buf(pem, -1);
    if (!bio) return WS_PEM_MALFORMED;

    pass_context ctx = { passphrase, 0 };
    EVP_PKEY *pkey = PEM_read_bio_PrivateKey(bio, NULL, password_callback, &ctx);
    BIO_free(bio);

    if (!pkey) {
        set_error(out);
        return ctx.asked ? WS_PEM_DECRYPT_FAILED : WS_PEM_MALFORMED;
    }

    ws_pem_status status = WS_PEM_OK;
    switch (EVP_PKEY_get_base_id(pkey)) {
    case EVP_PKEY_RSA:
        out->type = WS_PEM_KEY_RSA;
        if (!copy_bn(pkey, OSSL_PKEY_PARAM_RSA_N, &out->parts[0]) ||
            !copy_bn(pkey, OSSL_PKEY_PARAM_RSA_E, &out->parts[1]) ||
            !copy_bn(pkey, OSSL_PKEY_PARAM_RSA_D, &out->parts[2]) ||
            !copy_bn(pkey, OSSL_PKEY_PARAM_RSA_COEFFICIENT1, &out->parts[3]) ||
            !copy_bn(pkey, OSSL_PKEY_PARAM_RSA_FACTOR1, &out->parts[4]) ||
            !copy_bn(pkey, OSSL_PKEY_PARAM_RSA_FACTOR2, &out->parts[5])) {
            status = WS_PEM_MALFORMED;
        }
        break;

    case EVP_PKEY_EC: {
        out->type = WS_PEM_KEY_EC;
        char group[64] = { 0 };
        size_t group_len = 0;
        if (!EVP_PKEY_get_utf8_string_param(pkey, OSSL_PKEY_PARAM_GROUP_NAME, group, sizeof(group), &group_len)) {
            status = WS_PEM_MALFORMED;
            break;
        }
        if (strcmp(group, "prime256v1") == 0 || strcmp(group, "P-256") == 0) {
            strcpy(out->curve, "nistp256");
        } else if (strcmp(group, "secp384r1") == 0 || strcmp(group, "P-384") == 0) {
            strcpy(out->curve, "nistp384");
        } else if (strcmp(group, "secp521r1") == 0 || strcmp(group, "P-521") == 0) {
            strcpy(out->curve, "nistp521");
        } else {
            snprintf(out->error, sizeof(out->error), "%s", group);
            status = WS_PEM_UNSUPPORTED;
            break;
        }
        /* 공개점은 비압축(0x04 || X || Y) 형식으로 받는다 */
        EVP_PKEY_set_utf8_string_param(pkey, OSSL_PKEY_PARAM_EC_POINT_CONVERSION_FORMAT,
                                       OSSL_PKEY_EC_POINT_CONVERSION_FORMAT_UNCOMPRESSED);
        size_t point_len = 0;
        if (!EVP_PKEY_get_octet_string_param(pkey, OSSL_PKEY_PARAM_PUB_KEY, out->parts[0].bytes,
                                             sizeof(out->parts[0].bytes), &point_len) ||
            !copy_bn(pkey, OSSL_PKEY_PARAM_PRIV_KEY, &out->parts[1])) {
            status = WS_PEM_MALFORMED;
            break;
        }
        out->parts[0].length = point_len;
        break;
    }

    case EVP_PKEY_ED25519: {
        out->type = WS_PEM_KEY_ED25519;
        size_t pub_len = sizeof(out->parts[0].bytes), priv_len = sizeof(out->parts[1].bytes);
        if (!EVP_PKEY_get_raw_public_key(pkey, out->parts[0].bytes, &pub_len) ||
            !EVP_PKEY_get_raw_private_key(pkey, out->parts[1].bytes, &priv_len) ||
            pub_len != 32 || priv_len != 32) {
            status = WS_PEM_MALFORMED;
            break;
        }
        out->parts[0].length = pub_len;
        out->parts[1].length = priv_len;
        break;
    }

    default:
        snprintf(out->error, sizeof(out->error), "%s", EVP_PKEY_get0_type_name(pkey));
        status = WS_PEM_UNSUPPORTED;
        break;
    }

    if (status == WS_PEM_MALFORMED) set_error(out);
    EVP_PKEY_free(pkey);
    if (status != WS_PEM_OK) {
        char error[sizeof(out->error)];
        memcpy(error, out->error, sizeof(error));
        ws_pem_key_clear(out);
        memcpy(out->error, error, sizeof(error));
    }
    return status;
}

void ws_pem_key_clear(ws_pem_key *key) {
    OPENSSL_cleanse(key, sizeof(*key));
}
