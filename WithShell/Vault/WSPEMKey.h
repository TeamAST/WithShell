#ifndef WS_PEM_KEY_H
#define WS_PEM_KEY_H

#include <stddef.h>
#include <stdint.h>

/*
 * PEM 개인키 해석 (OpenSSL 사용).
 * 지원: PKCS#1 (BEGIN RSA PRIVATE KEY), SEC1 (BEGIN EC PRIVATE KEY), PKCS#8 (BEGIN PRIVATE KEY),
 *      암호화된 PKCS#8 (BEGIN ENCRYPTED PRIVATE KEY), 예전 OpenSSL 암호화(Proc-Type/DEK-Info).
 * 결과는 OpenSSH 형식으로 다시 쓰기 위한 원시 값(빅엔디언 정수 / 바이트열)이다.
 */

typedef enum {
    WS_PEM_OK = 0,
    WS_PEM_MALFORMED = 1,
    WS_PEM_DECRYPT_FAILED = 2,   /* 패스프레이즈가 없거나 틀림 */
    WS_PEM_UNSUPPORTED = 3,      /* DSA 등 지원하지 않는 종류, 지원하지 않는 곡선 */
} ws_pem_status;

typedef enum {
    WS_PEM_KEY_RSA = 1,
    WS_PEM_KEY_EC = 2,
    WS_PEM_KEY_ED25519 = 3,
} ws_pem_key_type;

#define WS_PEM_MAX_COMPONENT 1100  /* RSA 8192비트까지 */

typedef struct {
    uint8_t bytes[WS_PEM_MAX_COMPONENT];
    size_t length;
} ws_pem_component;

typedef struct {
    ws_pem_key_type type;
    /* EC 곡선의 OpenSSH 이름: "nistp256" / "nistp384" / "nistp521" */
    char curve[16];
    /* RSA: n, e, d, iqmp, p, q
     * EC: [0] 공개점 Q(비압축), [1] 개인 스칼라 d
     * Ed25519: [0] 공개키 32바이트, [1] 개인 시드 32바이트 */
    ws_pem_component parts[6];
    /* OpenSSL 오류 설명 (실패 시) */
    char error[256];
} ws_pem_key;

ws_pem_status ws_pem_decode(const char *pem, const char *passphrase, ws_pem_key *out);

/* 해석 결과의 개인 값을 지운다 */
void ws_pem_key_clear(ws_pem_key *key);

#endif
