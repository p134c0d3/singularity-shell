/*
 * xwl_icon.c - Read a window icon from an XWayland (X11) client.
 *
 * Wayland's foreign-toplevel protocol does not carry an application icon, so
 * windows whose app_id does not match a desktop entry (games, Wine, Discord,
 * many Java apps) show a generic dock/switcher icon. X11 clients, however,
 * embed their icon in the _NET_WM_ICON property. We match the toplevel to its
 * X11 window by WM_CLASS / _NET_WM_NAME and turn _NET_WM_ICON into a texture,
 * used as a last-resort fallback before the generic placeholder (#93).
 */
#include <stdint.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>

#include <xcb/xcb.h>
#include <gdk/gdk.h>

#include "xwl_icon.h"

static xcb_connection_t *conn = NULL;
static xcb_window_t root = 0;
static xcb_atom_t A_CLIENT_LIST, A_WM_ICON, A_WM_NAME, A_UTF8;

static xcb_atom_t intern(const char *name) {
    xcb_intern_atom_cookie_t c = xcb_intern_atom(conn, 0, (uint16_t)strlen(name), name);
    xcb_intern_atom_reply_t *r = xcb_intern_atom_reply(conn, c, NULL);
    xcb_atom_t a = r ? r->atom : XCB_ATOM_NONE;
    free(r);
    return a;
}

static gboolean ensure_conn(void) {
    if (conn) return !xcb_connection_has_error(conn);
    conn = xcb_connect(NULL, NULL);
    if (!conn || xcb_connection_has_error(conn)) { conn = NULL; return FALSE; }
    const xcb_setup_t *setup = xcb_get_setup(conn);
    xcb_screen_t *screen = xcb_setup_roots_iterator(setup).data;
    root = screen->root;
    A_CLIENT_LIST = intern("_NET_CLIENT_LIST");
    A_WM_ICON     = intern("_NET_WM_ICON");
    A_WM_NAME     = intern("_NET_WM_NAME");
    A_UTF8        = intern("UTF8_STRING");
    return TRUE;
}

/* Fetch a property's raw bytes. Caller frees the returned reply. */
static xcb_get_property_reply_t *get_prop(xcb_window_t w, xcb_atom_t prop,
                                          xcb_atom_t type, uint32_t len) {
    xcb_get_property_cookie_t c = xcb_get_property(conn, 0, w, prop, type, 0, len);
    return xcb_get_property_reply(conn, c, NULL);
}

/* True if the X11 window matches the given app_id (its WM_CLASS instance or
 * class) or, failing that, the title (its _NET_WM_NAME). */
static gboolean window_matches(xcb_window_t w, const char *app_id, const char *title) {
    gboolean match = FALSE;
    if (app_id && *app_id) {
        xcb_get_property_reply_t *r = get_prop(w, XCB_ATOM_WM_CLASS, XCB_ATOM_STRING, 256);
        if (r) {
            int len = xcb_get_property_value_length(r);
            const char *val = xcb_get_property_value(r);
            /* WM_CLASS is two NUL-terminated strings: instance\0class\0 */
            if (len > 0) {
                int inst_len = (int)strnlen(val, len);
                const char *inst = val;
                const char *cls = (inst_len + 1 < len) ? val + inst_len + 1 : "";
                if (strcasecmp(app_id, inst) == 0 || strcasecmp(app_id, cls) == 0)
                    match = TRUE;
            }
            free(r);
        }
    }
    if (!match && title && *title) {
        xcb_get_property_reply_t *r = get_prop(w, A_WM_NAME, A_UTF8, 256);
        if (r) {
            int len = xcb_get_property_value_length(r);
            if (len > 0) {
                char *name = g_strndup(xcb_get_property_value(r), len);
                if (strcasecmp(name, title) == 0) match = TRUE;
                g_free(name);
            }
            free(r);
        }
    }
    return match;
}

/* Read _NET_WM_ICON and build a texture from the largest image it contains. */
static GdkTexture *icon_texture(xcb_window_t w) {
    /* 1 MiB of 32-bit words is plenty for any embedded icon set. */
    xcb_get_property_reply_t *r = get_prop(w, A_WM_ICON, XCB_ATOM_CARDINAL, 256 * 1024);
    if (!r) return NULL;
    int words = xcb_get_property_value_length(r) / 4;
    const uint32_t *data = xcb_get_property_value(r);
    GdkTexture *tex = NULL;

    int best_w = 0, best_h = 0, best_off = -1;
    int i = 0;
    while (i + 2 <= words) {
        uint32_t iw = data[i], ih = data[i + 1];
        if (iw == 0 || ih == 0 || i + 2 + (int)(iw * ih) > words) break;
        /* Prefer the largest icon up to 256px, else just the largest. */
        if ((int)iw > best_w && (best_w > 256 ? (int)iw < best_w : 1)) {
            best_w = (int)iw; best_h = (int)ih; best_off = i + 2;
        }
        i += 2 + (int)(iw * ih);
    }

    if (best_off >= 0) {
        size_t npx = (size_t)best_w * best_h;
        /* _NET_WM_ICON pixels are 0xAARRGGBB CARDINALs; on little-endian that
         * is B,G,R,A in memory, matching GDK_MEMORY_B8G8R8A8 (straight alpha). */
        GBytes *bytes = g_bytes_new(data + best_off, npx * 4);
        tex = gdk_memory_texture_new(best_w, best_h, GDK_MEMORY_B8G8R8A8,
                                     bytes, (size_t)best_w * 4);
        g_bytes_unref(bytes);
    }
    free(r);
    return tex;
}

GdkTexture *singularity_xwayland_icon(const char *app_id, const char *title) {
    if (!ensure_conn()) return NULL;

    xcb_get_property_reply_t *r = get_prop(root, A_CLIENT_LIST, XCB_ATOM_WINDOW, 1024);
    if (!r) return NULL;
    int n = xcb_get_property_value_length(r) / 4;
    const xcb_window_t *wins = xcb_get_property_value(r);
    GdkTexture *tex = NULL;
    for (int i = 0; i < n; i++) {
        if (window_matches(wins[i], app_id, title)) {
            tex = icon_texture(wins[i]);
            if (tex) break;
        }
    }
    free(r);
    return tex;
}
