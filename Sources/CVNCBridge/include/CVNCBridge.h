#ifndef TM_VNC_BRIDGE_H
#define TM_VNC_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
typedef struct TMVNC TMVNC;
// Runtime-loaded LibVNCClient: ordinary VM mode has no external library dependency.
int tm_vnc_available(void);
TMVNC *tm_vnc_create(const char *host, int port, const char *username, const char *password);
int tm_vnc_connect(TMVNC *connection);
void tm_vnc_destroy(TMVNC *connection);
const char *tm_vnc_error(TMVNC *connection);
int tm_vnc_width(TMVNC *connection);
int tm_vnc_height(TMVNC *connection);
uint64_t tm_vnc_sequence(TMVNC *connection);
const uint8_t *tm_vnc_pixels(TMVNC *connection);
// Polls/decodes updates, returning -1 on disconnect, 0 on timeout, 1 on update.
int tm_vnc_poll(TMVNC *connection, unsigned int milliseconds);
int tm_vnc_request_frame(TMVNC *connection);
int tm_vnc_pointer(TMVNC *connection, int x, int y, int mask);
int tm_vnc_key(TMVNC *connection, uint32_t keysym, int down);
int tm_vnc_scroll(TMVNC *connection, int x, int y, int dx, int dy);
#endif
