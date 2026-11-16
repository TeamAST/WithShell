#include "WSRDPBridge.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include <winpr/crt.h>
#include <winpr/input.h>
#include <winpr/synch.h>
#include <winpr/thread.h>

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/codec/color.h>
#include <freerdp/graphics.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/channels/disp.h>
#include <freerdp/utils/helpers.h>

struct ws_rdp_session {
    rdpContext *context;
    ws_rdp_callbacks callbacks;
    HANDLE thread;
    HANDLE command_event;

    pthread_mutex_t lock;
    bool resize_pending;
    DISPLAY_CONTROL_MONITOR_LAYOUT pending_layout;

    DispClientContext *disp;
    volatile bool connected;

    /* 클립보드: 로컬 텍스트(UTF-16LE, NUL 포함)와 원격 공지 대기 여부 */
    CliprdrClientContext *clip;
    WCHAR *local_text;
    size_t local_text_bytes;
    bool clip_announce_pending;
    bool clip_ready;
};

typedef struct {
    rdpPointer pointer;
    BYTE *bgra;
} ws_pointer;

typedef struct {
    rdpClientContext common;
    ws_rdp_session *session;
} ws_context;

static ws_rdp_session *session_of(rdpContext *context) {
    return context ? ((ws_context *)context)->session : NULL;
}

/* MS-RDPEDISP: 너비는 짝수, 200~8192 */
static void clamp_size(uint32_t *width, uint32_t *height) {
    if (*width < 200) *width = 200;
    if (*height < 200) *height = 200;
    if (*width > 8192) *width = 8192;
    if (*height > 8192) *height = 8192;
    *width &= ~1u;
}

/* ---------------------------------------------------------------- 그래픽 */

static BOOL ws_begin_paint(rdpContext *context) {
    rdpGdi *gdi = context->gdi;
    if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd)
        gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}

static BOOL ws_end_paint(rdpContext *context) {
    ws_rdp_session *session = session_of(context);
    rdpGdi *gdi = context->gdi;
    if (!session || !gdi || !gdi->primary || !gdi->primary->hdc) return TRUE;

    HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    if (!hwnd || !hwnd->invalid || hwnd->invalid->null) return TRUE;

    if (session->callbacks.on_frame) {
        session->callbacks.on_frame(session->callbacks.user, gdi->primary_buffer, gdi->width, gdi->height,
                                    gdi->stride, hwnd->invalid->x, hwnd->invalid->y, hwnd->invalid->w,
                                    hwnd->invalid->h);
    }
    return TRUE;
}

static void notify_full_frame(ws_rdp_session *session) {
    rdpGdi *gdi = session->context->gdi;
    if (!gdi || !session->callbacks.on_frame) return;
    session->callbacks.on_frame(session->callbacks.user, gdi->primary_buffer, gdi->width, gdi->height, gdi->stride,
                                0, 0, (int32_t)gdi->width, (int32_t)gdi->height);
}

static BOOL ws_desktop_resize(rdpContext *context) {
    ws_rdp_session *session = session_of(context);
    rdpSettings *settings = context->settings;
    const UINT32 width = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    const UINT32 height = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
    if (!gdi_resize(context->gdi, width, height)) return FALSE;
    if (session && session->callbacks.on_resize)
        session->callbacks.on_resize(session->callbacks.user, width, height);
    if (session) notify_full_frame(session);
    return TRUE;
}

/* ---------------------------------------------------------------- 커서 */

static BOOL ws_pointer_new(rdpContext *context, rdpPointer *pointer) {
    ws_pointer *p = (ws_pointer *)pointer;
    rdpGdi *gdi = context->gdi;
    if (!gdi || pointer->width == 0 || pointer->height == 0) return TRUE;
    const size_t size = (size_t)pointer->width * pointer->height * 4;
    p->bgra = winpr_aligned_malloc(size, 16);
    if (!p->bgra) return FALSE;
    if (!freerdp_image_copy_from_pointer_data(p->bgra, PIXEL_FORMAT_BGRA32, 0, 0, 0, pointer->width,
                                              pointer->height, pointer->xorMaskData, pointer->lengthXorMask,
                                              pointer->andMaskData, pointer->lengthAndMask, pointer->xorBpp,
                                              &gdi->palette)) {
        winpr_aligned_free(p->bgra);
        p->bgra = NULL;
        return FALSE;
    }
    return TRUE;
}

static void ws_pointer_free(rdpContext *context, rdpPointer *pointer) {
    (void)context;
    ws_pointer *p = (ws_pointer *)pointer;
    winpr_aligned_free(p->bgra);
    p->bgra = NULL;
}

static void emit_cursor(rdpContext *context, int kind, const ws_pointer *p) {
    ws_rdp_session *session = session_of(context);
    if (!session || !session->callbacks.on_cursor) return;
    if (kind == 0 && p && p->bgra) {
        session->callbacks.on_cursor(session->callbacks.user, 0, p->bgra, p->pointer.width, p->pointer.height,
                                     p->pointer.xPos, p->pointer.yPos);
    } else {
        session->callbacks.on_cursor(session->callbacks.user, kind == 0 ? 2 : kind, NULL, 0, 0, 0, 0);
    }
}

static BOOL ws_pointer_set(rdpContext *context, rdpPointer *pointer) {
    emit_cursor(context, 0, (ws_pointer *)pointer);
    return TRUE;
}

static BOOL ws_pointer_set_null(rdpContext *context) {
    emit_cursor(context, 1, NULL);
    return TRUE;
}

static BOOL ws_pointer_set_default(rdpContext *context) {
    emit_cursor(context, 2, NULL);
    return TRUE;
}

static BOOL ws_pointer_set_position(rdpContext *context, UINT32 x, UINT32 y) {
    (void)context;
    (void)x;
    (void)y;
    return TRUE; /* 로컬 커서를 서버가 옮기는 것은 무시 */
}

static void register_pointer(rdpContext *context) {
    rdpPointer pointer = { 0 };
    pointer.size = sizeof(ws_pointer);
    pointer.New = ws_pointer_new;
    pointer.Free = ws_pointer_free;
    pointer.Set = ws_pointer_set;
    pointer.SetNull = ws_pointer_set_null;
    pointer.SetDefault = ws_pointer_set_default;
    pointer.SetPosition = ws_pointer_set_position;
    graphics_register_pointer(context->graphics, &pointer);
}

/* ---------------------------------------------------------------- 클립보드 (텍스트) */

static ws_rdp_session *clip_session(CliprdrClientContext *clip) {
    return clip ? (ws_rdp_session *)clip->custom : NULL;
}

static UINT clipboard_send_format_list(ws_rdp_session *session) {
    CliprdrClientContext *clip = session->clip;
    if (!clip || !session->clip_ready) return CHANNEL_RC_OK;

    pthread_mutex_lock(&session->lock);
    const bool has_text = session->local_text != NULL;
    pthread_mutex_unlock(&session->lock);

    CLIPRDR_FORMAT format = { 0 };
    format.formatId = CF_UNICODETEXT;
    CLIPRDR_FORMAT_LIST list = { 0 };
    list.common.msgType = CB_FORMAT_LIST;
    list.numFormats = has_text ? 1 : 0;
    list.formats = has_text ? &format : NULL;
    return clip->ClientFormatList(clip, &list);
}

static UINT ws_clip_monitor_ready(CliprdrClientContext *clip, const CLIPRDR_MONITOR_READY *ready) {
    (void)ready;
    ws_rdp_session *session = clip_session(clip);
    if (!session) return ERROR_INVALID_PARAMETER;

    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    general.capabilitySetType = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version = CB_CAPS_VERSION_2;
    general.generalFlags = CB_USE_LONG_FORMAT_NAMES;
    CLIPRDR_CAPABILITIES caps = { 0 };
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets = (CLIPRDR_CAPABILITY_SET *)&general;
    const UINT rc = clip->ClientCapabilities(clip, &caps);
    if (rc != CHANNEL_RC_OK) return rc;

    session->clip_ready = true;
    return clipboard_send_format_list(session);
}

static UINT ws_clip_server_capabilities(CliprdrClientContext *clip, const CLIPRDR_CAPABILITIES *caps) {
    (void)clip;
    (void)caps;
    return CHANNEL_RC_OK;
}

/* 서버 클립보드가 바뀜 → 텍스트가 있으면 바로 요청한다 */
static UINT ws_clip_server_format_list(CliprdrClientContext *clip, const CLIPRDR_FORMAT_LIST *list) {
    CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_LIST_RESPONSE;
    response.common.msgFlags = CB_RESPONSE_OK;
    UINT rc = clip->ClientFormatListResponse(clip, &response);
    if (rc != CHANNEL_RC_OK) return rc;

    for (UINT32 i = 0; i < list->numFormats; i++) {
        if (list->formats[i].formatId == CF_UNICODETEXT) {
            CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
            request.common.msgType = CB_FORMAT_DATA_REQUEST;
            request.requestedFormatId = CF_UNICODETEXT;
            return clip->ClientFormatDataRequest(clip, &request);
        }
    }
    return CHANNEL_RC_OK;
}

static UINT ws_clip_server_format_list_response(CliprdrClientContext *clip,
                                                const CLIPRDR_FORMAT_LIST_RESPONSE *response) {
    (void)clip;
    (void)response;
    return CHANNEL_RC_OK;
}

/* 서버가 우리 텍스트를 요청함 */
static UINT ws_clip_server_format_data_request(CliprdrClientContext *clip,
                                               const CLIPRDR_FORMAT_DATA_REQUEST *request) {
    ws_rdp_session *session = clip_session(clip);
    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    response.common.msgType = CB_FORMAT_DATA_RESPONSE;

    BYTE *copy = NULL;
    if (session && request->requestedFormatId == CF_UNICODETEXT) {
        pthread_mutex_lock(&session->lock);
        if (session->local_text && session->local_text_bytes <= UINT32_MAX) {
            copy = malloc(session->local_text_bytes);
            if (copy) {
                memcpy(copy, session->local_text, session->local_text_bytes);
                response.common.dataLen = (UINT32)session->local_text_bytes;
            }
        }
        pthread_mutex_unlock(&session->lock);
    }
    response.common.msgFlags = copy ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    response.requestedFormatData = copy;
    const UINT rc = clip->ClientFormatDataResponse(clip, &response);
    free(copy);
    return rc;
}

/* 요청한 서버 텍스트가 도착함 */
static UINT ws_clip_server_format_data_response(CliprdrClientContext *clip,
                                                const CLIPRDR_FORMAT_DATA_RESPONSE *response) {
    ws_rdp_session *session = clip_session(clip);
    if (!session || response->common.msgFlags != CB_RESPONSE_OK || !response->requestedFormatData)
        return CHANNEL_RC_OK;

    const size_t chars = response->common.dataLen / sizeof(WCHAR);
    char *utf8 = ConvertWCharNToUtf8Alloc((const WCHAR *)response->requestedFormatData, chars, NULL);
    if (utf8 && session->callbacks.on_remote_clipboard) {
        session->callbacks.on_remote_clipboard(session->callbacks.user, utf8);
    }
    free(utf8);
    return CHANNEL_RC_OK;
}

static void clipboard_attach(ws_rdp_session *session, CliprdrClientContext *clip) {
    session->clip = clip;
    session->clip_ready = false;
    clip->custom = session;
    clip->MonitorReady = ws_clip_monitor_ready;
    clip->ServerCapabilities = ws_clip_server_capabilities;
    clip->ServerFormatList = ws_clip_server_format_list;
    clip->ServerFormatListResponse = ws_clip_server_format_list_response;
    clip->ServerFormatDataRequest = ws_clip_server_format_data_request;
    clip->ServerFormatDataResponse = ws_clip_server_format_data_response;
}

/* ---------------------------------------------------------------- 채널 */

static void ws_on_channel_connected(void *context, const ChannelConnectedEventArgs *e) {
    ws_context *ctx = (ws_context *)context;
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        ctx->session->disp = (DispClientContext *)e->pInterface;
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        clipboard_attach(ctx->session, (CliprdrClientContext *)e->pInterface);
    } else {
        freerdp_client_OnChannelConnectedEventHandler(&ctx->common, e);
    }
}

static void ws_on_channel_disconnected(void *context, const ChannelDisconnectedEventArgs *e) {
    ws_context *ctx = (ws_context *)context;
    if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0) {
        ctx->session->disp = NULL;
    } else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0) {
        ctx->session->clip = NULL;
        ctx->session->clip_ready = false;
    } else {
        freerdp_client_OnChannelDisconnectedEventHandler(&ctx->common, e);
    }
}

/* ---------------------------------------------------------------- 연결 단계 */

static BOOL ws_pre_connect(freerdp *instance) {
    rdpSettings *settings = instance->context->settings;
    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMajorType, OSMAJORTYPE_MACINTOSH)) return FALSE;
    if (!freerdp_settings_set_uint32(settings, FreeRDP_OsMinorType, OSMINORTYPE_MACINTOSH)) return FALSE;
    if (PubSub_SubscribeChannelConnected(instance->context->pubSub, ws_on_channel_connected) < 0) return FALSE;
    if (PubSub_SubscribeChannelDisconnected(instance->context->pubSub, ws_on_channel_disconnected) < 0) return FALSE;
    return TRUE;
}

static BOOL ws_post_connect(freerdp *instance) {
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;

    rdpContext *context = instance->context;
    context->update->BeginPaint = ws_begin_paint;
    context->update->EndPaint = ws_end_paint;
    context->update->DesktopResize = ws_desktop_resize;
    register_pointer(context);

    ws_rdp_session *session = session_of(context);
    if (session) {
        rdpGdi *gdi = context->gdi;
        if (session->callbacks.on_resize)
            session->callbacks.on_resize(session->callbacks.user, gdi->width, gdi->height);
        session->connected = true;
        if (session->callbacks.on_state)
            session->callbacks.on_state(session->callbacks.user, WS_RDP_STATE_CONNECTED, 0, NULL, NULL);
    }
    return TRUE;
}

static void ws_post_disconnect(freerdp *instance) {
    if (!instance || !instance->context) return;
    ws_rdp_session *session = session_of(instance->context);
    if (session) {
        session->connected = false;
        session->disp = NULL;
    }
    PubSub_UnsubscribeChannelConnected(instance->context->pubSub, ws_on_channel_connected);
    PubSub_UnsubscribeChannelDisconnected(instance->context->pubSub, ws_on_channel_disconnected);
    gdi_free(instance);
}

/* 비밀번호는 연결 전에 미리 넣는다. 비어 있으면 묻지 않고 실패시킨다. */
static BOOL ws_authenticate(freerdp *instance, char **username, char **password, char **domain,
                            rdp_auth_reason reason) {
    (void)instance;
    (void)domain;
    (void)reason;
    return (username && *username && **username && password && *password && **password) ? TRUE : FALSE;
}

static DWORD ws_verify_certificate(freerdp *instance, const char *host, UINT16 port, const char *common_name,
                                   const char *subject, const char *issuer, const char *fingerprint,
                                   DWORD flags) {
    (void)flags;
    ws_rdp_session *session = session_of(instance->context);
    if (!session || !session->callbacks.verify_certificate) return WS_RDP_CERT_REJECT;
    return session->callbacks.verify_certificate(session->callbacks.user, host, port, common_name, subject, issuer,
                                                 fingerprint, NULL);
}

static DWORD ws_verify_changed_certificate(freerdp *instance, const char *host, UINT16 port,
                                           const char *common_name, const char *subject, const char *issuer,
                                           const char *new_fingerprint, const char *old_subject,
                                           const char *old_issuer, const char *old_fingerprint, DWORD flags) {
    (void)old_subject;
    (void)old_issuer;
    (void)flags;
    ws_rdp_session *session = session_of(instance->context);
    if (!session || !session->callbacks.verify_certificate) return WS_RDP_CERT_REJECT;
    return session->callbacks.verify_certificate(session->callbacks.user, host, port, common_name, subject, issuer,
                                                 new_fingerprint, old_fingerprint ? old_fingerprint : "");
}

static BOOL ws_client_new(freerdp *instance, rdpContext *context) {
    (void)context;
    instance->PreConnect = ws_pre_connect;
    instance->PostConnect = ws_post_connect;
    instance->PostDisconnect = ws_post_disconnect;
    instance->AuthenticateEx = ws_authenticate;
    instance->VerifyCertificateEx = ws_verify_certificate;
    instance->VerifyChangedCertificateEx = ws_verify_changed_certificate;
    return TRUE;
}

static void ws_client_free(freerdp *instance, rdpContext *context) {
    (void)instance;
    (void)context;
}

static int ws_client_start(rdpContext *context) {
    (void)context;
    return 0;
}

static int ws_client_stop(rdpContext *context) {
    (void)context;
    return 0;
}

/* ---------------------------------------------------------------- 연결 스레드 */

static void apply_pending_commands(ws_rdp_session *session) {
    DISPLAY_CONTROL_MONITOR_LAYOUT layout;
    bool resize = false;
    bool announce = false;

    pthread_mutex_lock(&session->lock);
    if (session->resize_pending) {
        layout = session->pending_layout;
        session->resize_pending = false;
        resize = true;
    }
    announce = session->clip_announce_pending;
    session->clip_announce_pending = false;
    ResetEvent(session->command_event);
    pthread_mutex_unlock(&session->lock);

    if (announce) (void)clipboard_send_format_list(session);

    if (resize && session->disp && session->disp->SendMonitorLayout) {
        (void)session->disp->SendMonitorLayout(session->disp, 1, &layout);
    }
}

static void report_closed(ws_rdp_session *session, bool failed) {
    if (!session->callbacks.on_state) return;
    UINT32 code = freerdp_get_last_error(session->context);
    /* 사용자가 끊은 경우(취소)는 실패가 아니다 */
    if (code != FREERDP_ERROR_CONNECT_CANCELLED && (failed || code != FREERDP_ERROR_SUCCESS)) {
        session->callbacks.on_state(session->callbacks.user, WS_RDP_STATE_FAILED, code,
                                    freerdp_get_last_error_name(code), freerdp_get_last_error_string(code));
    } else {
        session->callbacks.on_state(session->callbacks.user, WS_RDP_STATE_DISCONNECTED, code, NULL, NULL);
    }
}

static DWORD WINAPI ws_thread_proc(LPVOID arg) {
    ws_rdp_session *session = (ws_rdp_session *)arg;
    freerdp *instance = session->context->instance;

    if (session->callbacks.on_state)
        session->callbacks.on_state(session->callbacks.user, WS_RDP_STATE_CONNECTING, 0, NULL, NULL);

    if (!freerdp_connect(instance)) {
        const UINT32 code = freerdp_get_last_error(session->context);
        freerdp_disconnect(instance);
        report_closed(session, code != FREERDP_ERROR_CONNECT_CANCELLED && code != FREERDP_ERROR_SUCCESS);
        return 0;
    }

    bool failed = false;
    HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
    while (!freerdp_shall_disconnect_context(session->context)) {
        DWORD count = freerdp_get_event_handles(session->context, handles, ARRAYSIZE(handles) - 1);
        if (count == 0) { failed = true; break; }
        handles[count++] = session->command_event;

        const DWORD status = WaitForMultipleObjects(count, handles, FALSE, INFINITE);
        if (status == WAIT_FAILED) { failed = true; break; }

        apply_pending_commands(session);

        if (!freerdp_check_event_handles(session->context)) {
            failed = freerdp_get_last_error(session->context) != FREERDP_ERROR_SUCCESS;
            break;
        }
    }

    freerdp_disconnect(instance);
    report_closed(session, failed);
    return 0;
}

/* ---------------------------------------------------------------- 공개 API */

void ws_rdp_global_init(void) {
    static bool done = false;
    if (done) return;
    done = true;

    /* FreeRDP 로그를 파일로 남긴다: ~/Library/Logs/WithShell/freerdp.log (샌드박스 컨테이너 안)
     * 이미 환경 변수가 있으면(테스트 등) 그대로 둔다. */
    const char *home = getenv("HOME");
    if (home && !getenv("WLOG_APPENDER")) {
        char dir[1024];
        snprintf(dir, sizeof(dir), "%s/Library/Logs/WithShell", home);
        mkdir(dir, 0755);
        setenv("WLOG_APPENDER", "FILE", 0);
        setenv("WLOG_FILEAPPENDER_OUTPUT_FILE_PATH", dir, 0);
        setenv("WLOG_FILEAPPENDER_OUTPUT_FILE_NAME", "freerdp.log", 0);
        setenv("WLOG_LEVEL", "INFO", 0);
    }
    /* 설정·인증서 저장 위치: ~/.config/teamast/WithShell (샌드박스 컨테이너 안) */
    (void)freerdp_setApplicationDetails("teamast", "WithShell", -1);
}

static bool set_string(rdpSettings *settings, FreeRDP_Settings_Keys_String key, const char *value) {
    return value == NULL || *value == '\0' || freerdp_settings_set_string(settings, key, value);
}

ws_rdp_session *ws_rdp_create(const ws_rdp_callbacks *callbacks, const ws_rdp_config *config) {
    ws_rdp_global_init();

    RDP_CLIENT_ENTRY_POINTS entry = { 0 };
    entry.Version = RDP_CLIENT_INTERFACE_VERSION;
    entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
    entry.ContextSize = sizeof(ws_context);
    entry.ClientNew = ws_client_new;
    entry.ClientFree = ws_client_free;
    entry.ClientStart = ws_client_start;
    entry.ClientStop = ws_client_stop;

    rdpContext *context = freerdp_client_context_new(&entry);
    if (!context) return NULL;

    ws_rdp_session *session = calloc(1, sizeof(ws_rdp_session));
    if (!session) {
        freerdp_client_context_free(context);
        return NULL;
    }
    session->context = context;
    session->callbacks = *callbacks;
    session->command_event = CreateEventA(NULL, TRUE, FALSE, NULL);
    pthread_mutex_init(&session->lock, NULL);
    ((ws_context *)context)->session = session;

    uint32_t width = config->width, height = config->height;
    clamp_size(&width, &height);

    rdpSettings *s = context->settings;
    bool ok = freerdp_settings_set_string(s, FreeRDP_ServerHostname, config->host)
        && freerdp_settings_set_uint32(s, FreeRDP_ServerPort, config->port)
        && set_string(s, FreeRDP_Username, config->username)
        && set_string(s, FreeRDP_Domain, config->domain)
        && set_string(s, FreeRDP_Password, config->password)
        && freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, width)
        && freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, height)
        && freerdp_settings_set_uint32(s, FreeRDP_DesktopScaleFactor, config->desktop_scale)
        && freerdp_settings_set_uint32(s, FreeRDP_DeviceScaleFactor, config->device_scale)
        && freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32)
        && freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE)
        && freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE)
        && freerdp_settings_set_bool(s, FreeRDP_DynamicResolutionUpdate, TRUE)
        && freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, TRUE)
        && freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, FALSE)
        && freerdp_settings_set_bool(s, FreeRDP_AutoReconnectionEnabled, TRUE)
        && freerdp_set_connection_type(s, CONNECTION_TYPE_AUTODETECT);

    if (!ok) {
        ws_rdp_destroy(session);
        return NULL;
    }
    return session;
}

bool ws_rdp_start(ws_rdp_session *session) {
    if (!session || session->thread) return false;
    if (freerdp_client_start(session->context) != 0) return false;
    session->thread = CreateThread(NULL, 0, ws_thread_proc, session, 0, NULL);
    return session->thread != NULL;
}

void ws_rdp_stop(ws_rdp_session *session) {
    if (session && session->context) freerdp_abort_connect_context(session->context);
}

void ws_rdp_destroy(ws_rdp_session *session) {
    if (!session) return;
    if (session->thread) {
        freerdp_abort_connect_context(session->context);
        WaitForSingleObject(session->thread, INFINITE);
        (void)CloseHandle(session->thread);
        (void)freerdp_client_stop(session->context);
    }
    freerdp_client_context_free(session->context);
    (void)CloseHandle(session->command_event);
    pthread_mutex_destroy(&session->lock);
    if (session->local_text) {
        memset(session->local_text, 0, session->local_text_bytes);
        free(session->local_text);
    }
    free(session);
}

/* ---------------------------------------------------------------- 입력 */

static rdpInput *input_of(ws_rdp_session *session) {
    return (session && session->connected && session->context) ? session->context->input : NULL;
}

void ws_rdp_send_mac_key(ws_rdp_session *session, uint16_t mac_keycode, bool down) {
    rdpInput *input = input_of(session);
    if (!input) return;
    const DWORD vkcode = GetVirtualKeyCodeFromKeycode(mac_keycode, WINPR_KEYCODE_TYPE_APPLE);
    const DWORD scancode = GetVirtualScanCodeFromVirtualKeyCode(vkcode, WINPR_KBD_TYPE_IBM_ENHANCED);
    if ((scancode & 0xFF) == 0) return;
    UINT16 flags = down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
    if (scancode & KBDEXT) flags |= KBD_FLAGS_EXTENDED;
    (void)freerdp_input_send_keyboard_event(input, flags, (UINT8)(scancode & 0xFF));
}

void ws_rdp_send_scancode(ws_rdp_session *session, uint16_t scancode, bool extended, bool down) {
    rdpInput *input = input_of(session);
    if (!input) return;
    UINT16 flags = down ? KBD_FLAGS_DOWN : KBD_FLAGS_RELEASE;
    if (extended) flags |= KBD_FLAGS_EXTENDED;
    (void)freerdp_input_send_keyboard_event(input, flags, (UINT8)scancode);
}

void ws_rdp_send_unicode(ws_rdp_session *session, uint16_t code_unit, bool down) {
    rdpInput *input = input_of(session);
    if (!input) return;
    (void)freerdp_input_send_unicode_keyboard_event(input, down ? 0 : KBD_FLAGS_RELEASE, code_unit);
}

void ws_rdp_send_mouse(ws_rdp_session *session, uint16_t flags, uint16_t x, uint16_t y) {
    rdpInput *input = input_of(session);
    if (!input) return;
    (void)freerdp_input_send_mouse_event(input, flags, x, y);
}

void ws_rdp_request_resize(ws_rdp_session *session, uint32_t width, uint32_t height, uint32_t desktop_scale,
                           uint32_t device_scale) {
    if (!session) return;
    clamp_size(&width, &height);

    DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Width = width;
    layout.Height = height;
    layout.Orientation = ORIENTATION_LANDSCAPE;
    layout.DesktopScaleFactor = desktop_scale;
    layout.DeviceScaleFactor = device_scale;
    /* 물리 크기(mm)는 96 DPI 기준으로 계산 */
    layout.PhysicalWidth = (UINT32)((double)width / 96.0 * 25.4);
    layout.PhysicalHeight = (UINT32)((double)height / 96.0 * 25.4);

    pthread_mutex_lock(&session->lock);
    session->pending_layout = layout;
    session->resize_pending = true;
    (void)SetEvent(session->command_event);
    pthread_mutex_unlock(&session->lock);
}

void ws_rdp_set_local_clipboard(ws_rdp_session *session, const char *utf8) {
    if (!session) return;
    size_t chars = 0;
    WCHAR *text = (utf8 && *utf8) ? ConvertUtf8ToWCharAlloc(utf8, &chars) : NULL;

    pthread_mutex_lock(&session->lock);
    if (session->local_text) {
        memset(session->local_text, 0, session->local_text_bytes);
        free(session->local_text);
    }
    session->local_text = text;
    session->local_text_bytes = text ? (chars + 1) * sizeof(WCHAR) : 0;
    session->clip_announce_pending = true;
    (void)SetEvent(session->command_event);
    pthread_mutex_unlock(&session->lock);
}
