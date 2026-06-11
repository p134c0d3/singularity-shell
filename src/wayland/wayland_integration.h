#ifndef WAYLAND_INTEGRATION_H
#define WAYLAND_INTEGRATION_H

#include <stdint.h>
#include <glib.h>

typedef void (*AppOpenedCallback)(void* handle, const char* app_id, void* data);
typedef void (*AppClosedCallback)(void* handle, void* data);
typedef void (*AppFocusedCallback)(void* handle, void* data);
typedef void (*AppTitleChangedCallback)(void* handle, const char* title, void* data);
typedef void (*AppStateChangedCallback)(void* handle, int is_maximized, int is_fullscreen, int is_minimized, void* data);

typedef void (*WorkspaceCreatedCallback)(void* handle, const char* name, void* data);
typedef void (*WorkspaceDestroyedCallback)(void* handle, void* data);
typedef void (*WorkspaceStateCallback)(void* handle, uint32_t state, void* data);
typedef void (*WindowOutputChangedCallback)(void* handle, void* data);

void singularity_wayland_init(
    AppOpenedCallback opened_cb, 
    AppClosedCallback closed_cb, 
    AppFocusedCallback focused_cb,
    AppTitleChangedCallback title_cb,
    AppStateChangedCallback state_cb,
    WorkspaceCreatedCallback ws_created_cb,
    WorkspaceDestroyedCallback ws_destroyed_cb,
    WorkspaceStateCallback ws_state_cb,
    void* user_data
);
void singularity_wayland_set_window_output_changed_callback(WindowOutputChangedCallback cb, void* user_data);

void singularity_wayland_minimize_window(void* handle);
void singularity_wayland_unminimize_window(void* handle);
void singularity_wayland_close_window(void* handle);
void singularity_wayland_activate_window(void* handle);
void singularity_wayland_activate_workspace(void* handle);
void singularity_wayland_assign_toplevel(void* workspace_handle, void* toplevel_handle);
void singularity_wayland_create_workspace(const char* name);
void singularity_wayland_remove_workspace(void* handle);

typedef void (*PreviewCallback)(int width, int height, int stride, void *data, void *user_data);
void singularity_wayland_capture_preview(void *toplevel_handle, PreviewCallback callback, void *user_data, GDestroyNotify destroy);
/* Returns an opaque token; pass to singularity_wayland_cancel_capture() to abort. */
void* singularity_wayland_capture_preview_cancellable(void *toplevel_handle, PreviewCallback callback, void *user_data, GDestroyNotify destroy);
void  singularity_wayland_cancel_capture(void *token);
/* Free idle recycled preview SHM buffers (call when the overview closes). */
void  singularity_wayland_preview_pool_trim(void);

void singularity_wayland_begin_output_config(uint32_t serial);
void singularity_wayland_config_head(void *head_handle, int enabled, int x, int y, double scale, int transform, int mode_width, int mode_height, int mode_refresh);
void singularity_wayland_config_head_v2(void *head_handle, int enabled, int x, int y, double scale, int transform, int mode_width, int mode_height, int mode_refresh, int adaptive_sync);
void singularity_wayland_finish_output_config();

/* Called by Vala to receive adaptive sync state updates from the compositor. */
void singularity_display_manager_update_adaptive_sync(void* head_handle, uint32_t state);

void singularity_wayland_set_geometry(void* toplevel_handle, int32_t x, int32_t y, int32_t width, int32_t height);
int singularity_wayland_get_window_geometry(void* toplevel_handle,
        int* x, int* y, int* w, int* h, int* maximized, int* fullscreen, char** connector);
void singularity_wayland_set_tiled(void* toplevel_handle, uint32_t tiled);
void singularity_wayland_snap_view(void* toplevel_handle, uint32_t direction);
void singularity_wayland_move_to_workspace(void* toplevel_handle, uint32_t workspace_index);

/* Night light via wlr-gamma-control.
 * temperature: colour temperature in Kelvin (e.g. 4500 for warm, 6500 for neutral).
 * Calling set reapplies the ramp to every known output.
 * Calling reset destroys all gamma control objects, restoring compositor defaults. */
void singularity_wayland_set_night_light(int temperature);
void singularity_wayland_reset_night_light();

/* Returns the GdkMonitor* (as void*) for the monitor this toplevel is on.
 * Returns NULL if unknown. Transfer full - caller must g_object_unref when done. */
void* singularity_wayland_get_window_monitor(void *handle);

/* Newline-separated list of Wayland global interfaces the running compositor
 * advertises. Caller frees with g_free(). */
char* singularity_wayland_list_globals(void);

#endif
