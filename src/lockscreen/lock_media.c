/*
 * lock_media.c - MPRIS data source for the session lock.
 *
 * Reads title/artist/playback status and the controls capability over the
 * session bus, and loads the now-playing cover that the shell pre-caches at
 * ~/.cache/singularity/now-playing-cover (so the locker never downloads art
 * itself). All work runs on the GLib default main context, which lock_main.c
 * integrates into its Wayland poll loop.
 */
#include "lock_media.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <gio/gio.h>
#include <gdk-pixbuf/gdk-pixbuf.h>

static GDBusConnection *bus = NULL;
static GDBusProxy *player = NULL;
static char player_name[256] = "";
static LockMediaState state;
static void (*change_cb)(void) = NULL;
static char cover_path[1024] = "";
static char last_art[1024] = "";
static GFileMonitor *cover_monitor = NULL;

static cairo_surface_t *pixbuf_to_surface(GdkPixbuf *pb) {
    int w = gdk_pixbuf_get_width(pb), h = gdk_pixbuf_get_height(pb);
    int nch = gdk_pixbuf_get_n_channels(pb);
    int prs = gdk_pixbuf_get_rowstride(pb);
    const guint8 *pix = gdk_pixbuf_get_pixels(pb);
    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_RGB24, w, h);
    unsigned char *data = cairo_image_surface_get_data(s);
    int crs = cairo_image_surface_get_stride(s);
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            const guint8 *p = pix + y * prs + x * nch;
            uint32_t *dp = (uint32_t *)(data + y * crs + x * 4);
            *dp = ((uint32_t)p[0] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[2];
        }
    }
    cairo_surface_mark_dirty(s);
    return s;
}

static void load_cover(void) {
    if (state.cover) { cairo_surface_destroy(state.cover); state.cover = NULL; }
    if (cover_path[0] == '\0') return;
    GdkPixbuf *pb = gdk_pixbuf_new_from_file_at_scale(cover_path, 128, 128, TRUE, NULL);
    if (!pb) return;
    state.cover = pixbuf_to_surface(pb);
    g_object_unref(pb);
}

static bool get_bool_prop(const char *name, bool fallback) {
    GVariant *v = g_dbus_proxy_get_cached_property(player, name);
    if (!v) return fallback;
    bool r = fallback;
    if (g_variant_is_of_type(v, G_VARIANT_TYPE_BOOLEAN)) r = g_variant_get_boolean(v);
    g_variant_unref(v);
    return r;
}

static void update_from_proxy(void) {
    state.title[0] = '\0';
    state.artist[0] = '\0';
    state.playing = false;
    state.has_player = false;
    state.can_next = false;
    state.can_prev = false;

    if (!player) {
        if (change_cb) change_cb();
        return;
    }

    GVariant *status = g_dbus_proxy_get_cached_property(player, "PlaybackStatus");
    const char *st = NULL;
    if (status) st = g_variant_get_string(status, NULL);
    bool show = st && (strcmp(st, "Playing") == 0 || strcmp(st, "Paused") == 0);
    state.playing = st && strcmp(st, "Playing") == 0;

    if (show) {
        state.has_player = true;
        state.can_next = get_bool_prop("CanGoNext", true);
        state.can_prev = get_bool_prop("CanGoPrevious", true);

        GVariant *md = g_dbus_proxy_get_cached_property(player, "Metadata");
        const char *art_url = "";
        if (md) {
            GVariant *tv = g_variant_lookup_value(md, "xesam:title", G_VARIANT_TYPE_STRING);
            if (tv) { g_strlcpy(state.title, g_variant_get_string(tv, NULL), sizeof state.title); g_variant_unref(tv); }

            GVariant *av = g_variant_lookup_value(md, "xesam:artist", NULL);
            if (av) {
                if (g_variant_is_of_type(av, G_VARIANT_TYPE_STRING_ARRAY)) {
                    gsize n = 0;
                    const gchar **arr = g_variant_get_strv(av, &n);
                    if (arr && n > 0 && arr[0]) g_strlcpy(state.artist, arr[0], sizeof state.artist);
                    g_free(arr);
                } else if (g_variant_is_of_type(av, G_VARIANT_TYPE_STRING)) {
                    g_strlcpy(state.artist, g_variant_get_string(av, NULL), sizeof state.artist);
                }
                g_variant_unref(av);
            }

            GVariant *artv = g_variant_lookup_value(md, "mpris:artUrl", G_VARIANT_TYPE_STRING);
            if (artv) { art_url = g_variant_get_string(artv, NULL); }
            if (strcmp(art_url, last_art) != 0) {
                g_strlcpy(last_art, art_url, sizeof last_art);
                load_cover();
            }
            if (artv) g_variant_unref(artv);
            g_variant_unref(md);
        }
    } else {
        last_art[0] = '\0';
        if (state.cover) { cairo_surface_destroy(state.cover); state.cover = NULL; }
    }

    if (status) g_variant_unref(status);
    if (change_cb) change_cb();
}

static void on_props_changed(GDBusProxy *p, GVariant *changed, GStrv invalidated, gpointer ud) {
    (void)p; (void)changed; (void)invalidated; (void)ud;
    update_from_proxy();
}

static void connect_player(const char *name) {
    if (player) { g_object_unref(player); player = NULL; }
    GError *e = NULL;
    player = g_dbus_proxy_new_sync(bus, G_DBUS_PROXY_FLAGS_NONE, NULL,
        name, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", NULL, &e);
    if (!player) { if (e) g_error_free(e); return; }
    g_strlcpy(player_name, name, sizeof player_name);
    last_art[0] = '\0';
    g_signal_connect(player, "g-properties-changed", G_CALLBACK(on_props_changed), NULL);
    update_from_proxy();
}

static void find_player(void) {
    GError *e = NULL;
    GVariant *r = g_dbus_connection_call_sync(bus,
        "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
        "ListNames", NULL, G_VARIANT_TYPE("(as)"),
        G_DBUS_CALL_FLAGS_NONE, -1, NULL, &e);
    if (!r) { if (e) g_error_free(e); return; }

    GVariant *arr = g_variant_get_child_value(r, 0);
    GVariantIter it;
    g_variant_iter_init(&it, arr);
    const char *name;
    char *best = NULL;
    while (g_variant_iter_next(&it, "&s", &name)) {
        if (!g_str_has_prefix(name, "org.mpris.MediaPlayer2.")) continue;
        if (!best) best = g_strdup(name);
        GDBusProxy *p = g_dbus_proxy_new_sync(bus, G_DBUS_PROXY_FLAGS_NONE, NULL,
            name, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", NULL, NULL);
        if (p) {
            GVariant *stv = g_dbus_proxy_get_cached_property(p, "PlaybackStatus");
            bool playing = stv && strcmp(g_variant_get_string(stv, NULL), "Playing") == 0;
            if (stv) g_variant_unref(stv);
            g_object_unref(p);
            if (playing) { g_free(best); best = g_strdup(name); break; }
        }
    }
    g_variant_unref(arr);
    g_variant_unref(r);

    if (best) { connect_player(best); g_free(best); }
}

static void on_name_owner_changed(GDBusConnection *c, const char *sender,
        const char *path, const char *iface, const char *sig,
        GVariant *params, gpointer ud) {
    (void)c; (void)sender; (void)path; (void)iface; (void)sig; (void)ud;
    const char *name = NULL, *old_owner = NULL, *new_owner = NULL;
    g_variant_get(params, "(&s&s&s)", &name, &old_owner, &new_owner);
    if (!name || !g_str_has_prefix(name, "org.mpris.MediaPlayer2.")) return;
    if (new_owner && new_owner[0] != '\0') {
        if (!player) connect_player(name);
    } else if (strcmp(name, player_name) == 0) {
        if (player) { g_object_unref(player); player = NULL; }
        player_name[0] = '\0';
        find_player();
        if (!player) update_from_proxy();
    }
}

static void on_cover_changed(GFileMonitor *m, GFile *f, GFile *o,
        GFileMonitorEvent ev, gpointer ud) {
    (void)m; (void)f; (void)o; (void)ev; (void)ud;
    load_cover();
    if (change_cb) change_cb();
}

void lock_media_init(void (*on_change)(void)) {
    change_cb = on_change;
    memset(&state, 0, sizeof state);

    snprintf(cover_path, sizeof cover_path, "%s/singularity/now-playing-cover",
             g_get_user_cache_dir());

    GError *e = NULL;
    bus = g_bus_get_sync(G_BUS_TYPE_SESSION, NULL, &e);
    if (!bus) { if (e) g_error_free(e); return; }

    g_dbus_connection_signal_subscribe(bus,
        "org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
        "/org/freedesktop/DBus", NULL, G_DBUS_SIGNAL_FLAGS_NONE,
        on_name_owner_changed, NULL, NULL);

    GFile *cf = g_file_new_for_path(cover_path);
    cover_monitor = g_file_monitor_file(cf, G_FILE_MONITOR_NONE, NULL, NULL);
    if (cover_monitor)
        g_signal_connect(cover_monitor, "changed", G_CALLBACK(on_cover_changed), NULL);
    g_object_unref(cf);

    find_player();
}

const LockMediaState *lock_media_get(void) { return &state; }

static void call_player(const char *method) {
    if (!player) return;
    g_dbus_proxy_call(player, method, NULL, G_DBUS_CALL_FLAGS_NONE, -1, NULL, NULL, NULL);
}

void lock_media_play_pause(void) { call_player("PlayPause"); }
void lock_media_next(void)       { if (state.can_next) call_player("Next"); }
void lock_media_prev(void)       { if (state.can_prev) call_player("Previous"); }
