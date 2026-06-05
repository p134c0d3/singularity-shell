/* singularity-screenshot - native Wayland screenshot using wlr-screencopy-unstable-v1
 *
 * Usage: singularity-screenshot [-c] [-o output] [-g "x,y WxH"] <file.png>
 *   -c          include cursor
 *   -o <name>   capture named output only
 *   -g "x,y WxH" capture region (grim-compatible format)
 *   (no flags)  capture all outputs composited side-by-side
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <png.h>
#include <wayland-client.h>
#include "wlr-screencopy-unstable-v1-client-protocol.h"
#include "xdg-output-unstable-v1-client-protocol.h"
#include "ext-image-capture-source-v1-client-protocol.h"
#include "ext-image-copy-capture-v1-client-protocol.h"

#define MAX_OUTPUTS 16

/* ── Output tracking ─────────────────────────────────────────────────────── */

typedef struct {
    struct wl_output *wl;
    int32_t  x, y;           /* logical compositor position (from xdg-output or wl_output.geometry) */
    int32_t  mode_w, mode_h; /* pixel dimensions */
    int32_t  logical_w, logical_h; /* logical dimensions from xdg-output */
    int32_t  scale;
    char     name[64];
    int      xdg_done;       /* xdg_output done event received */
} Output;

typedef struct {
    struct wl_display                 *display;
    struct wl_shm                     *shm;
    struct zwlr_screencopy_manager_v1 *screencopy;
    struct zxdg_output_manager_v1     *xdg_output_manager;
    struct ext_output_image_capture_source_manager_v1 *ext_source_mgr;
    struct ext_image_copy_capture_manager_v1          *ext_capture_mgr;
    Output   outputs[MAX_OUTPUTS];
    int      n_outputs;
} State;

/* ── Frame capture state ──────────────────────────────────────────────────── */

typedef struct {
    State    *state;
    uint32_t  format, width, height, stride;
    uint32_t  flags;
    int       fd;
    void     *data;
    size_t    size;
    struct wl_buffer *buffer;
    int  shm_received;
    int  bgr_order;  /* 1 if format is XBGR/ABGR (bytes R,G,B,X - no swap needed) */
    int  done;   /* 1=ready, -1=failed, 0=pending */
} Frame;

/* ── SHM buffer ───────────────────────────────────────────────────────────── */

static struct wl_buffer *alloc_shm_buffer(Frame *f) {
    f->size = (size_t)f->stride * f->height;
    f->fd = memfd_create("screenshot", MFD_CLOEXEC);
    if (f->fd < 0) { perror("memfd_create"); return NULL; }
    if (ftruncate(f->fd, (off_t)f->size) < 0) {
        perror("ftruncate"); close(f->fd); f->fd = -1; return NULL;
    }
    f->data = mmap(NULL, f->size, PROT_READ | PROT_WRITE, MAP_SHARED, f->fd, 0);
    if (f->data == MAP_FAILED) {
        perror("mmap"); close(f->fd); f->fd = -1; return NULL;
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(f->state->shm, f->fd, (int32_t)f->size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0,
        (int32_t)f->width, (int32_t)f->height, (int32_t)f->stride, f->format);
    wl_shm_pool_destroy(pool);
    return buf;
}

static void frame_cleanup(Frame *f) {
    if (f->buffer)  { wl_buffer_destroy(f->buffer); f->buffer = NULL; }
    if (f->data && f->data != MAP_FAILED) { munmap(f->data, f->size); f->data = NULL; }
    if (f->fd >= 0) { close(f->fd); f->fd = -1; }
}

/* ── Frame event listeners ────────────────────────────────────────────────── */

static void frame_ev_buffer(void *data, struct zwlr_screencopy_frame_v1 *obj,
    uint32_t format, uint32_t w, uint32_t h, uint32_t stride)
{
    (void)obj;
    Frame *f = data;
    /* Accept common 32bpp wl_shm and DRM fourcc formats.
     * XR24=0x34325258 (XRGB, bytes B,G,R,X), XB24=0x34324258 (XBGR, bytes R,G,B,X),
     * and their ARGB/ABGR variants. */
    int is_bgr = (format == 0x34324258 || format == 0x34324241);
    if (format == WL_SHM_FORMAT_ARGB8888 || format == WL_SHM_FORMAT_XRGB8888 ||
        format == 0x34325241 || format == 0x34325258 ||
        format == 0x34324241 || format == 0x34324258) {
        f->format = format;
        f->width = w; f->height = h; f->stride = stride;
        f->shm_received = 1;
        f->bgr_order = is_bgr;
    }
}

static void frame_ev_flags(void *data, struct zwlr_screencopy_frame_v1 *obj, uint32_t flags) {
    (void)obj; ((Frame *)data)->flags = flags;
}

static void frame_ev_ready(void *data, struct zwlr_screencopy_frame_v1 *obj,
    uint32_t hi, uint32_t lo, uint32_t ns)
{
    (void)obj; (void)hi; (void)lo; (void)ns;
    ((Frame *)data)->done = 1;
}

static void frame_ev_failed(void *data, struct zwlr_screencopy_frame_v1 *obj) {
    (void)obj; Frame *f = data; f->done = -1;
}

static void frame_ev_damage(void *data, struct zwlr_screencopy_frame_v1 *obj,
    uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{
    (void)data; (void)obj; (void)x; (void)y; (void)w; (void)h;
}

static void frame_ev_linux_dmabuf(void *data, struct zwlr_screencopy_frame_v1 *obj,
    uint32_t fmt, uint32_t w, uint32_t h)
{
    (void)data; (void)obj; (void)fmt; (void)w; (void)h;
}

/* v3: all buffer-type events have been sent; allocate shm and start the copy */
static void frame_ev_buffer_done(void *data, struct zwlr_screencopy_frame_v1 *obj) {
    Frame *f = data;
    if (!f->shm_received) { f->done = -1; return; }
    f->buffer = alloc_shm_buffer(f);
    if (!f->buffer) { f->done = -1; return; }
    zwlr_screencopy_frame_v1_copy(obj, f->buffer);
}

static const struct zwlr_screencopy_frame_v1_listener frame_listener = {
    .buffer       = frame_ev_buffer,
    .flags        = frame_ev_flags,
    .ready        = frame_ev_ready,
    .failed       = frame_ev_failed,
    .damage       = frame_ev_damage,
    .linux_dmabuf = frame_ev_linux_dmabuf,
    .buffer_done  = frame_ev_buffer_done,
};

typedef struct {
    Frame *f;
    int    session_done;
} ExtCtx;

static void ext_session_buffer_size(void *data,
    struct ext_image_copy_capture_session_v1 *s, uint32_t w, uint32_t h)
{
    (void)s; Frame *f = ((ExtCtx *)data)->f;
    f->width = w; f->height = h;
}

static void ext_session_shm_format(void *data,
    struct ext_image_copy_capture_session_v1 *s, uint32_t format)
{
    (void)s; Frame *f = ((ExtCtx *)data)->f;
    if (format == WL_SHM_FORMAT_ARGB8888 || format == WL_SHM_FORMAT_XRGB8888)
        f->format = format;
    else if (!f->shm_received)
        f->format = format;
    f->shm_received = 1;
}

static void ext_session_dmabuf_device(void *data,
    struct ext_image_copy_capture_session_v1 *s, struct wl_array *dev) { (void)data; (void)s; (void)dev; }
static void ext_session_dmabuf_format(void *data,
    struct ext_image_copy_capture_session_v1 *s, uint32_t fmt, struct wl_array *mods) { (void)data; (void)s; (void)fmt; (void)mods; }

static void ext_session_done(void *data, struct ext_image_copy_capture_session_v1 *s) {
    (void)s; ((ExtCtx *)data)->session_done = 1;
}
static void ext_session_stopped(void *data, struct ext_image_copy_capture_session_v1 *s) {
    (void)s; ExtCtx *c = data; c->session_done = 1; c->f->done = -1;
}

static const struct ext_image_copy_capture_session_v1_listener ext_session_listener = {
    .buffer_size   = ext_session_buffer_size,
    .shm_format    = ext_session_shm_format,
    .dmabuf_device = ext_session_dmabuf_device,
    .dmabuf_format = ext_session_dmabuf_format,
    .done          = ext_session_done,
    .stopped       = ext_session_stopped,
};

static void ext_frame_transform(void *data,
    struct ext_image_copy_capture_frame_v1 *fr, uint32_t transform) { (void)data; (void)fr; (void)transform; }
static void ext_frame_damage(void *data, struct ext_image_copy_capture_frame_v1 *fr,
    int32_t x, int32_t y, int32_t w, int32_t h) { (void)data; (void)fr; (void)x; (void)y; (void)w; (void)h; }
static void ext_frame_presentation_time(void *data, struct ext_image_copy_capture_frame_v1 *fr,
    uint32_t hi, uint32_t lo, uint32_t ns) { (void)data; (void)fr; (void)hi; (void)lo; (void)ns; }
static void ext_frame_ready(void *data, struct ext_image_copy_capture_frame_v1 *fr) {
    (void)fr; ((ExtCtx *)data)->f->done = 1;
}
static void ext_frame_failed(void *data, struct ext_image_copy_capture_frame_v1 *fr, uint32_t reason) {
    (void)fr; (void)reason; ((ExtCtx *)data)->f->done = -1;
}

static const struct ext_image_copy_capture_frame_v1_listener ext_frame_listener = {
    .transform         = ext_frame_transform,
    .damage            = ext_frame_damage,
    .presentation_time = ext_frame_presentation_time,
    .ready             = ext_frame_ready,
    .failed            = ext_frame_failed,
};

static int capture_output_ext(State *state, Output *out, int cursor, Frame *f) {
    if (!state->ext_source_mgr || !state->ext_capture_mgr) return -1;

    memset(f, 0, sizeof(*f));
    f->state = state;
    f->fd = -1;
    ExtCtx ctx = { .f = f, .session_done = 0 };

    struct ext_image_capture_source_v1 *src =
        ext_output_image_capture_source_manager_v1_create_source(state->ext_source_mgr, out->wl);
    uint32_t opts = cursor ? EXT_IMAGE_COPY_CAPTURE_MANAGER_V1_OPTIONS_PAINT_CURSORS : 0;
    struct ext_image_copy_capture_session_v1 *sess =
        ext_image_copy_capture_manager_v1_create_session(state->ext_capture_mgr, src, opts);
    ext_image_copy_capture_session_v1_add_listener(sess, &ext_session_listener, &ctx);
    wl_display_flush(state->display);

    int rc = -1;
    struct ext_image_copy_capture_frame_v1 *frame = NULL;

    while (!ctx.session_done && f->done == 0)
        if (wl_display_dispatch(state->display) < 0) goto out;

    if (f->done == -1 || f->width == 0 || f->height == 0) goto out;

    f->stride = f->width * 4;
    f->bgr_order = (f->format == 0x34324258 || f->format == 0x34324241);
    f->buffer = alloc_shm_buffer(f);
    if (!f->buffer) goto out;

    frame = ext_image_copy_capture_session_v1_create_frame(sess);
    ext_image_copy_capture_frame_v1_add_listener(frame, &ext_frame_listener, &ctx);
    ext_image_copy_capture_frame_v1_attach_buffer(frame, f->buffer);
    ext_image_copy_capture_frame_v1_damage_buffer(frame, 0, 0, (int32_t)f->width, (int32_t)f->height);
    ext_image_copy_capture_frame_v1_capture(frame);
    wl_display_flush(state->display);

    while (f->done == 0)
        if (wl_display_dispatch(state->display) < 0) break;

    f->flags = 0;
    rc = (f->done == 1) ? 0 : -1;

out:
    if (frame) ext_image_copy_capture_frame_v1_destroy(frame);
    ext_image_copy_capture_session_v1_destroy(sess);
    ext_image_capture_source_v1_destroy(src);
    return rc;
}

/* ── wl_output listeners ──────────────────────────────────────────────────── */

static void output_geometry(void *data, struct wl_output *wl,
    int32_t x, int32_t y, int32_t pw, int32_t ph, int32_t sp,
    const char *make, const char *model, int32_t tf)
{
    (void)wl; (void)pw; (void)ph; (void)sp; (void)make; (void)model; (void)tf;
    Output *o = data; o->x = x; o->y = y;
}

static void output_mode(void *data, struct wl_output *wl,
    uint32_t flags, int32_t w, int32_t h, int32_t refresh)
{
    (void)wl; (void)refresh;
    Output *o = data;
    if (flags & WL_OUTPUT_MODE_CURRENT) { o->mode_w = w; o->mode_h = h; }
}

static void output_done(void *data, struct wl_output *wl) { (void)data; (void)wl; }

static void output_scale(void *data, struct wl_output *wl, int32_t scale) {
    (void)wl; ((Output *)data)->scale = scale;
}

static void output_name(void *data, struct wl_output *wl, const char *name) {
    (void)wl;
    Output *o = data;
    strncpy(o->name, name ? name : "", sizeof(o->name) - 1);
}

static void output_description(void *data, struct wl_output *wl, const char *desc) {
    (void)data; (void)wl; (void)desc;
}

static const struct wl_output_listener output_listener = {
    .geometry    = output_geometry,
    .mode        = output_mode,
    .done        = output_done,
    .scale       = output_scale,
    .name        = output_name,
    .description = output_description,
};

/* ── xdg_output listeners (override x,y with authoritative logical coords) ── */

static void xdg_output_logical_position(void *data,
    struct zxdg_output_v1 *xdg_out, int32_t x, int32_t y)
{
    (void)xdg_out;
    Output *o = data;
    o->x = x;
    o->y = y;
}

static void xdg_output_logical_size(void *data,
    struct zxdg_output_v1 *xdg_out, int32_t w, int32_t h)
{
    (void)xdg_out;
    Output *o = data;
    o->logical_w = w;
    o->logical_h = h;
}

static void xdg_output_done(void *data, struct zxdg_output_v1 *xdg_out) {
    (void)xdg_out;
    ((Output *)data)->xdg_done = 1;
}

static void xdg_output_name(void *data, struct zxdg_output_v1 *xdg_out, const char *name) {
    (void)xdg_out;
    /* xdg_output name may duplicate wl_output name - only use as fallback */
    Output *o = data;
    if (o->name[0] == '\0' && name)
        strncpy(o->name, name, sizeof(o->name) - 1);
}

static void xdg_output_description(void *data, struct zxdg_output_v1 *xdg_out,
    const char *desc) { (void)data; (void)xdg_out; (void)desc; }

static const struct zxdg_output_v1_listener xdg_output_listener = {
    .logical_position = xdg_output_logical_position,
    .logical_size     = xdg_output_logical_size,
    .done             = xdg_output_done,
    .name             = xdg_output_name,
    .description      = xdg_output_description,
};

/* ── Registry ─────────────────────────────────────────────────────────────── */

static void registry_global(void *data, struct wl_registry *reg,
    uint32_t name, const char *iface, uint32_t version)
{
    State *s = data;
    if (strcmp(iface, wl_shm_interface.name) == 0) {
        s->shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    } else if (strcmp(iface, zwlr_screencopy_manager_v1_interface.name) == 0) {
        s->screencopy = wl_registry_bind(reg, name,
            &zwlr_screencopy_manager_v1_interface, version < 3 ? version : 3);
    } else if (strcmp(iface, zxdg_output_manager_v1_interface.name) == 0) {
        s->xdg_output_manager = wl_registry_bind(reg, name,
            &zxdg_output_manager_v1_interface, version < 3 ? version : 3);
    } else if (strcmp(iface, ext_output_image_capture_source_manager_v1_interface.name) == 0) {
        s->ext_source_mgr = wl_registry_bind(reg, name,
            &ext_output_image_capture_source_manager_v1_interface, 1);
    } else if (strcmp(iface, ext_image_copy_capture_manager_v1_interface.name) == 0) {
        s->ext_capture_mgr = wl_registry_bind(reg, name,
            &ext_image_copy_capture_manager_v1_interface, 1);
    } else if (strcmp(iface, wl_output_interface.name) == 0 && s->n_outputs < MAX_OUTPUTS) {
        Output *o = &s->outputs[s->n_outputs++];
        memset(o, 0, sizeof(*o));
        o->scale = 1;
        o->wl = wl_registry_bind(reg, name, &wl_output_interface, version < 4 ? version : 4);
        wl_output_add_listener(o->wl, &output_listener, o);
    }
}

static void registry_global_remove(void *data, struct wl_registry *reg, uint32_t name) {
    (void)data; (void)reg; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global        = registry_global,
    .global_remove = registry_global_remove,
};

/* ── PNG write ────────────────────────────────────────────────────────────── */

/* Write BGRA or RGBA pixel data as PNG.
 * For BGRA (ARGB8888 / XRGB8888 in LE memory), swap B↔R.
 * For RGBA (ABGR8888 / XBGR8888 in LE memory), bytes are already R,G,B,A - no swap.
 * Pass y_invert=1 when the ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT flag is set. */
static int write_png_bgra(const char *path, const uint8_t *data,
    uint32_t width, uint32_t height, uint32_t stride, int y_invert, int already_rgb)
{
    FILE *fp = fopen(path, "wb");
    if (!fp) { perror(path); return -1; }

    png_structp png  = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    png_infop   info = png_create_info_struct(png);
    if (!png || !info) { fclose(fp); return -1; }

    if (setjmp(png_jmpbuf(png))) {
        png_destroy_write_struct(&png, &info); fclose(fp); return -1;
    }

    png_init_io(png, fp);
    png_set_IHDR(png, info, width, height, 8, PNG_COLOR_TYPE_RGBA,
        PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    png_write_info(png, info);

    uint8_t *row = malloc(stride);
    if (!row) { png_destroy_write_struct(&png, &info); fclose(fp); return -1; }

    for (uint32_t y = 0; y < height; y++) {
        uint32_t sy = y_invert ? (height - 1 - y) : y;
        memcpy(row, data + (size_t)sy * stride, stride);
        if (!already_rgb) {
            for (uint32_t x = 0; x < width; x++) {
                uint8_t b = row[x * 4];
                row[x * 4]     = row[x * 4 + 2];
                row[x * 4 + 2] = b;
            }
        }
        png_write_row(png, row);
    }
    free(row);

    png_write_end(png, NULL);
    png_destroy_write_struct(&png, &info);
    fclose(fp);
    return 0;
}

/* ── Core capture ─────────────────────────────────────────────────────────── */

static int do_capture(State *state, struct zwlr_screencopy_frame_v1 *frame_obj, Frame *frame) {
    memset(frame, 0, sizeof(*frame));
    frame->state = state;
    frame->fd    = -1;
    zwlr_screencopy_frame_v1_add_listener(frame_obj, &frame_listener, frame);
    wl_display_flush(state->display);

    uint32_t ver = zwlr_screencopy_frame_v1_get_version(frame_obj);

    if (ver >= 3) {
        /* frame_ev_buffer_done allocates the buffer and calls copy */
        while (frame->done == 0) {
            if (wl_display_dispatch(state->display) < 0) return -1;
        }
    } else {
        /* v1/v2: send copy after receiving the wl_shm buffer event */
        while (!frame->shm_received && frame->done == 0) {
            if (wl_display_dispatch(state->display) < 0) return -1;
        }
        if (frame->done != 0) return frame->done == 1 ? 0 : -1;
        frame->buffer = alloc_shm_buffer(frame);
        if (!frame->buffer) return -1;
        zwlr_screencopy_frame_v1_copy(frame_obj, frame->buffer);
        while (frame->done == 0) {
            if (wl_display_dispatch(state->display) < 0) return -1;
        }
    }

    return frame->done == 1 ? 0 : -1;
}

/* ── Capture variants ─────────────────────────────────────────────────────── */

static int capture_one(State *state, Output *out, int cursor, Frame *f) {
    if (capture_output_ext(state, out, cursor, f) == 0)
        return 0;
    frame_cleanup(f);
    if (!state->screencopy) return -1;
    struct zwlr_screencopy_frame_v1 *fo =
        zwlr_screencopy_manager_v1_capture_output(state->screencopy, cursor, out->wl);
    int rc = do_capture(state, fo, f);
    zwlr_screencopy_frame_v1_destroy(fo);
    return rc;
}

static int capture_output(State *state, Output *out, int cursor, const char *path) {
    Frame f;
    int rc = capture_one(state, out, cursor, &f);
    if (rc == 0) {
        int inv = (f.flags & ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) != 0;
        rc = write_png_bgra(path, f.data, f.width, f.height, f.stride, inv, f.bgr_order);
    } else {
        fprintf(stderr, "capture failed for output %s\n", out->name);
    }
    frame_cleanup(&f);
    return rc;
}

static int capture_region(State *state,
    int32_t gx, int32_t gy, int32_t gw, int32_t gh,
    int cursor, const char *path)
{
    /* Find the output that contains the region origin in compositor space.
     * Prefer xdg-output logical dimensions (logical_w/h) when available,
     * fall back to mode_w/scale for compositors without xdg-output. */
    Output *tgt = NULL;
    for (int i = 0; i < state->n_outputs; i++) {
        Output *o = &state->outputs[i];
        int32_t lw = (o->xdg_done && o->logical_w > 0) ? o->logical_w
                     : (o->scale > 0 ? o->mode_w / o->scale : o->mode_w);
        int32_t lh = (o->xdg_done && o->logical_h > 0) ? o->logical_h
                     : (o->scale > 0 ? o->mode_h / o->scale : o->mode_h);
        if (gx >= o->x && gx < o->x + lw && gy >= o->y && gy < o->y + lh) {
            tgt = o; break;
        }
    }
    if (!tgt) tgt = &state->outputs[0];

    if (state->screencopy) {
        struct zwlr_screencopy_frame_v1 *fo =
            zwlr_screencopy_manager_v1_capture_output_region(
                state->screencopy, cursor, tgt->wl,
                gx - tgt->x, gy - tgt->y, gw, gh);
        Frame f;
        int rc = do_capture(state, fo, &f);
        zwlr_screencopy_frame_v1_destroy(fo);
        if (rc == 0) {
            int inv = (f.flags & ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) != 0;
            rc = write_png_bgra(path, f.data, f.width, f.height, f.stride, inv, f.bgr_order);
            frame_cleanup(&f);
            return rc;
        }
        frame_cleanup(&f);
    }

    Frame ef;
    if (capture_one(state, tgt, cursor, &ef) != 0) {
        fprintf(stderr, "region capture failed\n");
        frame_cleanup(&ef);
        return -1;
    }
    int scale = tgt->scale > 0 ? tgt->scale : 1;
    if (ef.width > 0 && tgt->logical_w > 0) scale = (int)(ef.width / tgt->logical_w);
    if (scale < 1) scale = 1;
    int32_t px = (gx - tgt->x) * scale;
    int32_t py = (gy - tgt->y) * scale;
    if (px < 0) px = 0;
    if (py < 0) py = 0;
    uint32_t pw = (uint32_t)gw * scale;
    uint32_t ph = (uint32_t)gh * scale;
    if ((uint32_t)px + pw > ef.width)  pw = ef.width  > (uint32_t)px ? ef.width  - (uint32_t)px : 0;
    if ((uint32_t)py + ph > ef.height) ph = ef.height > (uint32_t)py ? ef.height - (uint32_t)py : 0;
    if (pw == 0 || ph == 0) {
        fprintf(stderr, "region outside output\n");
        frame_cleanup(&ef);
        return -1;
    }
    uint32_t cstride = pw * 4;
    uint8_t *crop = malloc((size_t)cstride * ph);
    if (!crop) { frame_cleanup(&ef); return -1; }
    for (uint32_t row = 0; row < ph; row++) {
        memcpy(crop + (size_t)row * cstride,
               (const uint8_t *)ef.data + (size_t)(py + row) * ef.stride + (size_t)px * 4,
               cstride);
    }
    int rc = write_png_bgra(path, crop, pw, ph, cstride, 0, ef.bgr_order);
    free(crop);
    frame_cleanup(&ef);
    return rc;
}

static int capture_all(State *state, int cursor, const char *path) {
    int n = state->n_outputs;
    if (n == 0) { fprintf(stderr, "no outputs\n"); return -1; }
    if (n == 1) return capture_output(state, &state->outputs[0], cursor, path);

    Frame frames[MAX_OUTPUTS];
    memset(frames, 0, sizeof(frames));

    for (int i = 0; i < n; i++) {
        if (capture_one(state, &state->outputs[i], cursor, &frames[i]) < 0) {
            fprintf(stderr, "capture failed for output %d\n", i);
            for (int j = 0; j <= i; j++)
                frame_cleanup(&frames[j]);
            return -1;
        }
    }

    /* Sort index by logical X so outputs are arranged left-to-right */
    int order[MAX_OUTPUTS];
    for (int i = 0; i < n; i++) order[i] = i;
    for (int i = 0; i < n - 1; i++)
        for (int j = 0; j < n - 1 - i; j++)
            if (state->outputs[order[j]].x > state->outputs[order[j + 1]].x) {
                int t = order[j]; order[j] = order[j + 1]; order[j + 1] = t;
            }

    uint32_t total_w = 0, total_h = 0;
    for (int i = 0; i < n; i++) {
        total_w += frames[i].width;
        if (frames[i].height > total_h) total_h = frames[i].height;
    }

    uint32_t canvas_stride = total_w * 4;
    uint8_t *canvas = calloc(total_h, canvas_stride);
    if (!canvas) {
        for (int i = 0; i < n; i++)
            frame_cleanup(&frames[i]);
        return -1;
    }

    uint32_t x_off = 0;
    for (int oi = 0; oi < n; oi++) {
        int i = order[oi];
        Frame *f = &frames[i];
        int inv = (f->flags & ZWLR_SCREENCOPY_FRAME_V1_FLAGS_Y_INVERT) != 0;
        for (uint32_t y = 0; y < f->height && y < total_h; y++) {
            uint32_t sy = inv ? (f->height - 1 - y) : y;
            memcpy(canvas + (size_t)y * canvas_stride + x_off * 4,
                   (const uint8_t *)f->data + (size_t)sy * f->stride, f->width * 4);
        }
        x_off += f->width;
    }

    /* For multi-monitor canvas, swap bytes matching the first output's format */
    int canvas_bgr = (n > 0) ? frames[0].bgr_order : 0;
    int rc = write_png_bgra(path, canvas, total_w, total_h, canvas_stride, 0, canvas_bgr);
    free(canvas);
    for (int i = 0; i < n; i++)
        frame_cleanup(&frames[i]);
    return rc;
}

/* ── main ─────────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[]) {
    const char *output_name = NULL, *geometry = NULL, *out_file = NULL;
    int cursor = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-c") == 0) {
            cursor = 1;
        } else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) {
            output_name = argv[++i];
        } else if (strcmp(argv[i], "-g") == 0 && i + 1 < argc) {
            geometry = argv[++i];
        } else if (argv[i][0] != '-') {
            out_file = argv[i];
        } else {
            fprintf(stderr, "usage: singularity-screenshot [-c] [-o output] [-g \"x,y WxH\"] <file.png>\n");
            return 1;
        }
    }

    if (!out_file) {
        fprintf(stderr, "usage: singularity-screenshot [-c] [-o output] [-g \"x,y WxH\"] <file.png>\n");
        return 1;
    }

    struct wl_display *display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "failed to connect to Wayland display\n"); return 1; }

    State state = {0};
    state.display = display;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, &state);
    wl_display_roundtrip(display); /* enumerate globals */
    wl_display_roundtrip(display); /* flush output events (geometry, mode, scale, name) */

    /* Create xdg_output for each wl_output to get authoritative logical positions */
    struct zxdg_output_v1 *xdg_outs[MAX_OUTPUTS] = {0};
    if (state.xdg_output_manager) {
        for (int i = 0; i < state.n_outputs; i++) {
            xdg_outs[i] = zxdg_output_manager_v1_get_xdg_output(
                state.xdg_output_manager, state.outputs[i].wl);
            zxdg_output_v1_add_listener(xdg_outs[i], &xdg_output_listener, &state.outputs[i]);
        }
        wl_display_roundtrip(display); /* flush xdg-output events */
    }

    int have_ext = state.ext_source_mgr && state.ext_capture_mgr;
    if (!state.shm || state.n_outputs == 0 || (!state.screencopy && !have_ext)) {
        fprintf(stderr, "required Wayland interfaces not available\n");
        wl_display_disconnect(display);
        return 1;
    }

    int ret;
    if (geometry) {
        int32_t gx, gy, gw, gh;
        if (sscanf(geometry, "%d,%d %dx%d", &gx, &gy, &gw, &gh) != 4) {
            fprintf(stderr, "invalid geometry: '%s'  (expected x,y WxH)\n", geometry);
            wl_display_disconnect(display);
            return 1;
        }
        ret = capture_region(&state, gx, gy, gw, gh, cursor, out_file);
    } else if (output_name) {
        Output *tgt = NULL;
        for (int i = 0; i < state.n_outputs; i++)
            if (strcmp(state.outputs[i].name, output_name) == 0) {
                tgt = &state.outputs[i]; break;
            }
        if (!tgt) {
            fprintf(stderr, "output '%s' not found\n", output_name);
            wl_display_disconnect(display);
            return 1;
        }
        ret = capture_output(&state, tgt, cursor, out_file);
    } else {
        ret = capture_all(&state, cursor, out_file);
    }

    for (int i = 0; i < state.n_outputs; i++) {
        if (xdg_outs[i]) zxdg_output_v1_destroy(xdg_outs[i]);
        wl_output_destroy(state.outputs[i].wl);
    }
    if (state.xdg_output_manager) zxdg_output_manager_v1_destroy(state.xdg_output_manager);
    if (state.ext_capture_mgr) ext_image_copy_capture_manager_v1_destroy(state.ext_capture_mgr);
    if (state.ext_source_mgr) ext_output_image_capture_source_manager_v1_destroy(state.ext_source_mgr);
    if (state.screencopy) zwlr_screencopy_manager_v1_destroy(state.screencopy);
    wl_shm_destroy(state.shm);
    wl_registry_destroy(registry);
    wl_display_disconnect(display);
    return ret == 0 ? 0 : 1;
}
