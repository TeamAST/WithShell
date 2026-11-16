#ifndef WS_RDP_BRIDGE_H
#define WS_RDP_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

/*
 * WithShell ↔ FreeRDP 연결 계층.
 * Swift에서 FreeRDP 헤더를 직접 다루지 않도록 필요한 기능만 C 함수로 감싼다.
 * 모든 콜백은 RDP 연결 스레드에서 호출된다.
 */

typedef struct ws_rdp_session ws_rdp_session;

typedef enum {
    WS_RDP_STATE_CONNECTING = 0,
    WS_RDP_STATE_CONNECTED = 1,
    WS_RDP_STATE_DISCONNECTED = 2,
    WS_RDP_STATE_FAILED = 3,
} ws_rdp_state;

typedef enum {
    WS_RDP_CERT_REJECT = 0,
    WS_RDP_CERT_ACCEPT_PERMANENTLY = 1,
    WS_RDP_CERT_ACCEPT_ONCE = 2,
} ws_rdp_cert_decision;

typedef struct {
    void *user;

    /* 화면 일부가 갱신됨. buffer는 BGRA 32비트, 콜백이 끝나기 전까지만 유효하다. */
    void (*on_frame)(void *user, const uint8_t *buffer, uint32_t width, uint32_t height, uint32_t stride,
                     int32_t x, int32_t y, int32_t w, int32_t h);

    /* 원격 데스크톱 크기가 바뀜 */
    void (*on_resize)(void *user, uint32_t width, uint32_t height);

    /* 연결 상태 변경. 실패 시 error_name / error_message 제공 */
    void (*on_state)(void *user, ws_rdp_state state, uint32_t error_code,
                     const char *error_name, const char *error_message);

    /* 원격 커서 변경. kind: 0=이미지(bgra, w, h, 핫스팟), 1=숨김, 2=기본 화살표 */
    void (*on_cursor)(void *user, int kind, const uint8_t *bgra, uint32_t width, uint32_t height,
                      uint32_t hot_x, uint32_t hot_y);

    /* 원격 클립보드의 텍스트가 바뀜 (UTF-8) */
    void (*on_remote_clipboard)(void *user, const char *utf8);

    /* 서버 인증서 확인 (응답할 때까지 연결 스레드가 대기한다).
     * old_fingerprint가 NULL이 아니면 이전에 저장된 인증서와 다른 경우다. */
    ws_rdp_cert_decision (*verify_certificate)(void *user, const char *host, uint16_t port,
                                               const char *common_name, const char *subject,
                                               const char *issuer, const char *fingerprint,
                                               const char *old_fingerprint);
} ws_rdp_callbacks;

typedef struct {
    const char *host;
    uint16_t port;
    const char *username;
    const char *domain;
    const char *password;
    uint32_t width;   /* 픽셀 */
    uint32_t height;  /* 픽셀 */
    uint32_t desktop_scale;  /* 100~500 (%) */
    uint32_t device_scale;   /* 100, 140, 180 */
} ws_rdp_config;

/* 앱 시작 시 한 번 (설정 파일 경로 등) */
void ws_rdp_global_init(void);

ws_rdp_session *ws_rdp_create(const ws_rdp_callbacks *callbacks, const ws_rdp_config *config);
/* 연결 스레드를 시작한다. */
bool ws_rdp_start(ws_rdp_session *session);
/* 연결을 끊도록 요청한다 (즉시 반환). */
void ws_rdp_stop(ws_rdp_session *session);
/* 연결 스레드가 끝날 때까지 기다린 뒤 해제한다. 메인 스레드에서 부르지 말 것. */
void ws_rdp_destroy(ws_rdp_session *session);

/* 입력 (연결된 상태에서만 전송됨) */
void ws_rdp_send_mac_key(ws_rdp_session *session, uint16_t mac_keycode, bool down);
void ws_rdp_send_scancode(ws_rdp_session *session, uint16_t scancode, bool extended, bool down);
void ws_rdp_send_unicode(ws_rdp_session *session, uint16_t code_unit, bool down);
void ws_rdp_send_mouse(ws_rdp_session *session, uint16_t flags, uint16_t x, uint16_t y);

/* 로컬 클립보드 텍스트를 원격에 알린다 (UTF-8, NULL이면 비움) */
void ws_rdp_set_local_clipboard(ws_rdp_session *session, const char *utf8);

/* 창 크기 변경 → 원격 해상도 변경 요청 (Display Control 채널) */
void ws_rdp_request_resize(ws_rdp_session *session, uint32_t width, uint32_t height,
                           uint32_t desktop_scale, uint32_t device_scale);

/* 마우스 플래그 (FreeRDP PTR_FLAGS_* 값) */
enum {
    WS_PTR_MOVE = 0x0800,
    WS_PTR_DOWN = 0x8000,
    WS_PTR_BUTTON1 = 0x1000,
    WS_PTR_BUTTON2 = 0x2000,
    WS_PTR_BUTTON3 = 0x4000,
    WS_PTR_WHEEL = 0x0200,
    WS_PTR_HWHEEL = 0x0400,
    WS_PTR_WHEEL_NEGATIVE = 0x0100,
};

#endif
