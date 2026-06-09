/*
 * vkbd.c - Type text into the focused window via a Wayland virtual keyboard.
 *
 * Binds zwp_virtual_keyboard_manager_v1 on the GDK display, creates a virtual
 * keyboard for the seat, and for each codepoint uploads a minimal one-key xkb
 * keymap mapping the key to that Unicode codepoint, then presses and releases
 * it. This is the approach wtype uses, and lets the emoji picker insert the
 * chosen emoji straight into whatever app currently has focus.
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#include <wayland-client.h>
#include <glib.h>
#include <gdk/gdk.h>
#include <gdk/wayland/gdkwayland.h>

#include "virtual-keyboard-unstable-v1-client-protocol.h"
#include "vkbd.h"

static struct zwp_virtual_keyboard_manager_v1 *vk_manager = NULL;
static struct zwp_virtual_keyboard_v1 *vkbd = NULL;
static struct wl_display *wl_disp = NULL;
static uint32_t key_time = 0;

static void reg_global(void *data, struct wl_registry *r, uint32_t name,
                       const char *iface, uint32_t ver) {
    (void) data; (void) ver;
    if (strcmp(iface, zwp_virtual_keyboard_manager_v1_interface.name) == 0) {
        vk_manager = wl_registry_bind(
            r, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
    }
}
static void reg_remove(void *data, struct wl_registry *r, uint32_t name) {
    (void) data; (void) r; (void) name;
}
static const struct wl_registry_listener reg_listener = { reg_global, reg_remove };

/* Build a memfd holding a one-key xkb keymap whose single key emits the given
 * Unicode codepoint. Returns the fd (caller closes) and sets *size_out. */
static int make_keymap_fd(uint32_t cp, size_t *size_out) {
    char *str = g_strdup_printf(
        "xkb_keymap {\n"
        "xkb_keycodes \"(unnamed)\" { minimum = 8; maximum = 9; <K1> = 9; };\n"
        "xkb_types \"(unnamed)\" { type \"ONE_LEVEL\" { modifiers = none; level_name[Level1] = \"Any\"; }; };\n"
        "xkb_compatibility \"(unnamed)\" { };\n"
        "xkb_symbols \"(unnamed)\" { key <K1> { [ U%04X ] }; };\n"
        "};\n", cp);
    size_t size = strlen(str) + 1;
    int fd = memfd_create("singularity-vkbd-keymap", MFD_CLOEXEC);
    if (fd < 0) { g_free(str); return -1; }
    if (ftruncate(fd, (off_t) size) < 0) { close(fd); g_free(str); return -1; }
    void *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) { close(fd); g_free(str); return -1; }
    memcpy(map, str, size);
    munmap(map, size);
    g_free(str);
    *size_out = size;
    return fd;
}

static gboolean ensure_vkbd(void) {
    if (vkbd != NULL) return TRUE;
    GdkDisplay *gdk = gdk_display_get_default();
    if (gdk == NULL || !GDK_IS_WAYLAND_DISPLAY(gdk)) return FALSE;
    wl_disp = gdk_wayland_display_get_wl_display(gdk);
    if (wl_disp == NULL) return FALSE;
    if (vk_manager == NULL) {
        struct wl_registry *reg = wl_display_get_registry(wl_disp);
        wl_registry_add_listener(reg, &reg_listener, NULL);
        wl_display_roundtrip(wl_disp);
    }
    if (vk_manager == NULL) {
        g_warning("vkbd: compositor has no virtual keyboard manager");
        return FALSE;
    }
    GdkSeat *gseat = gdk_display_get_default_seat(gdk);
    if (gseat == NULL) return FALSE;
    struct wl_seat *seat = gdk_wayland_seat_get_wl_seat(gseat);
    if (seat == NULL) return FALSE;
    vkbd = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(vk_manager, seat);
    return vkbd != NULL;
}

void singularity_type_text(const char *utf8) {
    if (utf8 == NULL || *utf8 == '\0') return;
    if (!ensure_vkbd()) return;

    const char *p = utf8;
    while (*p != '\0') {
        gunichar cp = g_utf8_get_char(p);
        p = g_utf8_next_char(p);
        if (cp == 0) continue;

        size_t size = 0;
        int fd = make_keymap_fd((uint32_t) cp, &size);
        if (fd < 0) continue;
        zwp_virtual_keyboard_v1_keymap(
            vkbd, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, (uint32_t) size);
        close(fd);
        /* No modifiers; the single key sits at level 1. */
        zwp_virtual_keyboard_v1_modifiers(vkbd, 0, 0, 0, 0);
        zwp_virtual_keyboard_v1_key(vkbd, key_time++, 1, WL_KEYBOARD_KEY_STATE_PRESSED);
        zwp_virtual_keyboard_v1_key(vkbd, key_time++, 1, WL_KEYBOARD_KEY_STATE_RELEASED);
    }
    wl_display_flush(wl_disp);
}
