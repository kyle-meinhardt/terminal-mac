#include "CVNCBridge.h"
#include <rfb/rfbclient.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>
#include <mach-o/dyld.h>

// Load only the bundled, patched library or a sibling development .build artifact.
// Never search the working directory or DYLD paths, or load an ordinary console-only VNC library.
static void *library;
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int (*virtual_session)(rfbClient *);
static uint32_t (*last_message)(rfbClient *), (*last_encoding)(rfbClient *);
static rfbBool (*scroll_event)(rfbClient *, int, int, int, int);
static uint32_t (*last_stage)(void), (*last_flags)(void), (*last_allowed)(void), (*last_status)(void);
#define FUNCTIONS(X) \
 X(rfbGetClient) X(rfbClientCleanup) X(rfbInitClient) X(SetClientAuthSchemes) \
 X(rfbClientSetClientData) X(rfbClientGetClientData) X(WaitForMessage) \
 X(HandleRFBServerMessage) X(SendFramebufferUpdateRequest) X(SendPointerEvent) X(SendKeyEvent)
#define DECLARE(name) static __typeof__(&name) api_##name;
FUNCTIONS(DECLARE)
static void quiet(const char *format, ...) { (void)format; }
static int try_library(const char *path) {
    void *candidate = dlopen(path, RTLD_LOCAL | RTLD_NOW);
    if (!candidate) return 0;
    virtual_session = dlsym(candidate, "terminal_mac_virtual_session");
    int (*version)(void) = dlsym(candidate, "terminal_mac_session_api_version");
    scroll_event = dlsym(candidate, "terminal_mac_scroll");
    if (!virtual_session || !version || version() != 2 || !scroll_event) { dlclose(candidate); return 0; }
    library = candidate;
    last_message = dlsym(candidate, "terminal_mac_last_message");
    last_encoding = dlsym(candidate, "terminal_mac_last_encoding");
    last_stage = dlsym(candidate, "terminal_mac_last_stage");
    last_flags = dlsym(candidate, "terminal_mac_last_flags");
    last_allowed = dlsym(candidate, "terminal_mac_last_allowed");
    last_status = dlsym(candidate, "terminal_mac_last_status");
    return 1;
}
static void load_library(void) {
    char executable[PATH_MAX], resolved[PATH_MAX], candidate[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0 || !realpath(executable, resolved)) return;
    char *slash = strrchr(resolved, '/'); if (!slash) return; *slash = 0;
    snprintf(candidate, sizeof(candidate), "%s/../Frameworks/libvncclient-session.dylib", resolved);
    try_library(candidate);
    // Swift test bundles nest more deeply than the executable. Find their .build ancestor.
    while (!library) {
        slash = strrchr(resolved, '/'); if (!slash) break;
        if (strcmp(slash + 1, ".build") == 0) {
            snprintf(candidate, sizeof(candidate), "%s/session-libs/libvncclient-session.dylib", resolved);
            try_library(candidate); break;
        }
        *slash = 0;
    }
    if (!library) return;
#define LOAD(name) api_##name = dlsym(library, #name); if (!api_##name) { library = NULL; return; }
    FUNCTIONS(LOAD)
    // LibVNCClient's logs must never appear on MCP stdout, or disclose server auth material.
    rfbClientLogProc *log = dlsym(library, "rfbClientLog"), *err = dlsym(library, "rfbClientErr");
    if (log) *log = quiet;
    if (err) *err = quiet;
}
int tm_vnc_available(void) { pthread_once(&once, load_library); return library != NULL; }

struct TMVNC {
    rfbClient *client;
    char *username, *password;
    uint8_t *pixels;
    uint64_t sequence;
    int pixels_changed, has_frame;
    int width, height;
    char error[256];
};
static int tag;
static TMVNC *state(rfbClient *client) { return api_rfbClientGetClientData(client, &tag); }
static void set_error(TMVNC *c, const char *error) { snprintf(c->error, sizeof(c->error), "%s", error); }
static rfbBool allocate_frame(rfbClient *client) {
    TMVNC *c = state(client);
    size_t w = client->width, h = client->height;
    if (!w || !h || w > 8192 || h > 8192 || w * h > 16777216) {
        set_error(c, "Screen Sharing returned an unsupported framebuffer size (maximum 64 MiB)");
        return FALSE;
    }
    uint8_t *pixels = calloc(w * h, 4);
    if (!pixels) { set_error(c, "Cannot allocate Screen Sharing framebuffer"); return FALSE; }
    free(c->pixels); c->pixels = pixels;
    c->width = (int)w; c->height = (int)h;
    c->pixels_changed = 0;
    c->has_frame = 0;
    client->frameBuffer = pixels;
    return TRUE;
}
static void rectangle_updated(rfbClient *client, int x, int y, int width, int height) {
    (void)x; (void)y;
    if (width > 0 && height > 0) state(client)->pixels_changed = 1;
}
static void frame_finished(rfbClient *client) {
    TMVNC *c = state(client);
    // DisplayInfo and other pseudo-rectangles can complete an update before a
    // single pixel is received. Never publish the freshly calloc'd black buffer.
    if (c->pixels_changed) { c->sequence++; c->pixels_changed = 0; c->has_frame = 1; }
}
static rfbCredential *credential(rfbClient *client, int kind) {
    if (kind != rfbCredentialTypeUser) return NULL;
    TMVNC *c = state(client);
    rfbCredential *cred = calloc(1, sizeof(*cred));
    if (!cred) return NULL;
    cred->userCredential.username = strdup(c->username);
    cred->userCredential.password = strdup(c->password);
    return cred;
}
TMVNC *tm_vnc_create(const char *host, int port, const char *username, const char *password) {
    if (!tm_vnc_available() || !host || !username || !password || port < 1 || port > 65535) return NULL;
    if (strcmp(host, "127.0.0.1") && strcmp(host, "::1")) return NULL;
    if (strlen(username) > 63 || strlen(password) > 63) return NULL;
    TMVNC *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->username = strdup(username); c->password = strdup(password);
    c->client = api_rfbGetClient(8, 3, 4);
    if (!c->username || !c->password || !c->client) { tm_vnc_destroy(c); return NULL; }
    rfbClient *client = c->client;
    api_rfbClientSetClientData(client, &tag, c);
    free(client->serverHost); client->serverHost = strdup(host); client->serverPort = port;
    client->connectTimeout = 5; client->readTimeout = 5;
    client->GetCredential = credential;
    client->GetPassword = NULL;
    client->MallocFrameBuffer = allocate_frame;
    client->GotFrameBufferUpdate = rectangle_updated;
    client->FinishedFrameBufferUpdate = frame_finished;
    client->canHandleNewFBSize = TRUE;
    client->appData.shareDesktop = TRUE;
    client->appData.useRemoteCursor = FALSE;
    client->appData.encodingsString = "zrle hextile raw";
    client->format.bitsPerPixel = 32; client->format.depth = 24;
    client->format.bigEndian = FALSE; client->format.trueColour = TRUE;
    client->format.redMax = client->format.greenMax = client->format.blueMax = 255;
    client->format.redShift = 16; client->format.greenShift = 8; client->format.blueShift = 0;
    // Require username/password ARD. Never fall back to a password that shares the physical console.
    const uint32_t schemes[] = {rfbARD, 0};
    api_SetClientAuthSchemes(client, schemes, -1);
    return c;
}
int tm_vnc_connect(TMVNC *c) {
    if (!c || !c->client) return 0;
    int argc = 0;
    if (!api_rfbInitClient(c->client, &argc, NULL)) {
        // rfbInitClient already frees its client on failure, but not our framebuffer.
        c->client = NULL;
        if (!c->error[0]) snprintf(c->error, sizeof(c->error), "Screen Sharing handshake failed (stage=%u, flags=%u, allowed=%u, status=%u). Check the agent login, tunnel and Screen Sharing access.", last_stage ? last_stage() : 0, last_flags ? last_flags() : UINT32_MAX, last_allowed ? last_allowed() : UINT32_MAX, last_status ? last_status() : UINT32_MAX);
        return 0;
    }
    if (!virtual_session(c->client)) {
        set_error(c, "The server did not grant a separate virtual session; refusing console access");
        api_rfbClientCleanup(c->client); c->client = NULL;
        return 0;
    }
    // Apple can grant the session before its virtual display exists. The patched
    // decoder learns the real dimensions through DisplayInfo (1101); never request 0x0.
    for (int attempt = 0; (c->width == 0 || c->height == 0) && attempt < 100; attempt++) {
        if (tm_vnc_poll(c, 50) < 0) break;
    }
    if (c->width == 0 || c->height == 0) {
        if (!c->error[0]) set_error(c, "The virtual session was granted, but its display did not become ready. Keep the agent logged in and reconnect.");
        api_rfbClientCleanup(c->client); c->client = NULL;
        return 0;
    }
    // The credentials callback is only needed during authentication.
    if (c->password) { memset(c->password, 0, strlen(c->password)); free(c->password); c->password = NULL; }
    return 1;
}
void tm_vnc_destroy(TMVNC *c) {
    if (!c) return;
    if (c->client) api_rfbClientCleanup(c->client);
    if (c->password) { memset(c->password, 0, strlen(c->password)); free(c->password); }
    free(c->username); free(c->pixels); free(c);
}
const char *tm_vnc_error(TMVNC *c) { return c ? c->error : "Cannot initialize LibVNCClient"; }
int tm_vnc_width(TMVNC *c) { return c->width; }
int tm_vnc_height(TMVNC *c) { return c->height; }
uint64_t tm_vnc_sequence(TMVNC *c) { return c->has_frame ? c->sequence : 0; }
const uint8_t *tm_vnc_pixels(TMVNC *c) { return c->pixels; }
int tm_vnc_poll(TMVNC *c, unsigned int milliseconds) {
    if (!c || !c->client) return -1;
    int ready = api_WaitForMessage(c->client, milliseconds * 1000);
    if (ready < 0 || (ready && !api_HandleRFBServerMessage(c->client))) {
        uint32_t message = last_message ? last_message(c->client) : UINT32_MAX;
        uint32_t encoding = last_encoding ? last_encoding(c->client) : UINT32_MAX;
        snprintf(c->error, sizeof(c->error), "Screen Sharing disconnected (message=%u, encoding=%u); reconnect and verify the agent desktop before enabling input", message, encoding);
        return -1;
    }
    return ready > 0;
}
int tm_vnc_request_frame(TMVNC *c) {
    return c && c->client && c->width > 0 && c->height > 0 && api_SendFramebufferUpdateRequest(c->client, 0, 0, c->width, c->height, FALSE);
}
int tm_vnc_pointer(TMVNC *c, int x, int y, int mask) {
    return c && c->client && api_SendPointerEvent(c->client, x, y, mask);
}
int tm_vnc_key(TMVNC *c, uint32_t keysym, int down) {
    return c && c->client && api_SendKeyEvent(c->client, keysym, down);
}
int tm_vnc_scroll(TMVNC *c, int x, int y, int dx, int dy) {
    return c && c->client && scroll_event(c->client, x, y, dx, dy);
}
