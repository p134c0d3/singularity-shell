[CCode (cheader_filename = "wayland_integration.h")]
namespace Singularity {
    [CCode (has_target = false)]
    public delegate void AppOpenedCallback(void* handle, string app_id, void* data);
    [CCode (has_target = false)]
    public delegate void AppClosedCallback(void* handle, void* data);
    [CCode (has_target = false)]
    public delegate void AppFocusedCallback(void* handle, void* data);
    [CCode (has_target = false)]
    public delegate void AppTitleChangedCallback(void* handle, string title, void* data);
    [CCode (has_target = false)]
    public delegate void AppStateChangedCallback(void* handle, int is_maximized, int is_fullscreen, int is_minimized, void* data);
    
    [CCode (has_target = false)]
    public delegate void WorkspaceCreatedCallback(void* handle, string name, void* data);
    [CCode (has_target = false)]
    public delegate void WorkspaceDestroyedCallback(void* handle, void* data);
    [CCode (has_target = false)]
    public delegate void WorkspaceStateCallback(void* handle, uint32 state, void* data);

    [CCode (cname = "singularity_wayland_init")]
    public void wayland_init(
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

    [CCode (cname = "singularity_wayland_activate_window")]
    public void wayland_activate_window(void* handle);

    [CCode (cname = "singularity_wayland_activate_workspace")]
    public void wayland_activate_workspace(void* handle);

    [CCode (cname = "singularity_wayland_assign_toplevel")]
    public void wayland_assign_toplevel(void* workspace_handle, void* toplevel_handle);
    
    [CCode (cname = "singularity_wayland_create_workspace")]
    public void wayland_create_workspace(string name);
    
    [CCode (cname = "singularity_wayland_remove_workspace")]
    public void wayland_remove_workspace(void* handle);

    [CCode (cname = "singularity_wayland_minimize_window")]
    public void minimize_window(void* handle);

    [CCode (cname = "singularity_wayland_unminimize_window")]
    public void unminimize_window(void* handle);

    [CCode (cname = "singularity_wayland_close_window")]
    public void close_window(void* handle);

    [CCode (cname = "PreviewCallback")]
    public delegate void PreviewCallback(int width, int height, int stride, void* data);

    [CCode (cname = "singularity_wayland_capture_preview")]
    public void wayland_capture_preview(void* toplevel_handle, owned PreviewCallback callback);

    [CCode (cname = "singularity_wayland_capture_preview_cancellable")]
    public void* wayland_capture_preview_cancellable(void* toplevel_handle, owned PreviewCallback callback);

    [CCode (cname = "singularity_wayland_cancel_capture")]
    public void wayland_cancel_capture(void* token);

    [CCode (cname = "singularity_wayland_preview_pool_trim")]
    public void wayland_preview_pool_trim();

    [CCode (cname = "singularity_wayland_begin_output_config")]
    public void wayland_begin_output_config(uint32 serial);

    [CCode (cname = "singularity_wayland_config_head")]
    public void wayland_config_head(void* head_handle, int enabled, int x, int y, double scale, int transform, int mode_width, int mode_height, int mode_refresh);

    [CCode (cname = "singularity_wayland_config_head_v2")]
    public void wayland_config_head_v2(void* head_handle, int enabled, int x, int y, double scale, int transform, int mode_width, int mode_height, int mode_refresh, int adaptive_sync);

    [CCode (cname = "singularity_wayland_finish_output_config")]
    public void wayland_finish_output_config();

    [CCode (cname = "singularity_wayland_set_geometry")]
    public void wayland_set_geometry(void* toplevel_handle, int x, int y, int width, int height);

    [CCode (cname = "singularity_wayland_get_window_geometry")]
    public bool wayland_get_window_geometry(void* toplevel_handle,
        out int x, out int y, out int width, out int height,
        out int maximized, out int fullscreen, out string? connector);

    [CCode (cname = "singularity_wayland_set_tiled")]
    public void wayland_set_tiled(void* toplevel_handle, uint32 tiled);

    [CCode (cname = "singularity_wayland_snap_view")]
    public void wayland_snap_view(void* toplevel_handle, uint32 direction);

    [CCode (cname = "singularity_wayland_set_night_light")]
    public void wayland_set_night_light(int temperature);

    [CCode (cname = "singularity_wayland_reset_night_light")]
    public void wayland_reset_night_light();

    [CCode (cname = "singularity_wayland_get_window_monitor")]
    public Gdk.Monitor? wayland_get_window_monitor(void* handle);

    [CCode (has_target = false)]
    public delegate void WindowOutputChangedCallback(void* handle, void* data);
    [CCode (cname = "singularity_wayland_set_window_output_changed_callback")]
    public void wayland_set_window_output_changed_callback(WindowOutputChangedCallback cb, void* data);

    [CCode (cname = "singularity_wayland_list_globals")]
    public string wayland_list_globals();

    [CCode (cname = "singularity_request_surface_blur", cheader_filename = "blur_surface.h")]
    public void request_surface_blur(Gtk.Widget widget, uint32 radius);

    [CCode (cname = "singularity_surface_set_input_passthrough", cheader_filename = "blur_surface.h")]
    public void surface_set_input_passthrough(Gtk.Widget widget);

    [CCode (cname = "singularity_type_text", cheader_filename = "vkbd.h")]
    public void type_text(string text);

    [CCode (cname = "singularity_xwayland_icon", cheader_filename = "xwl_icon.h")]
    public Gdk.Texture? xwayland_icon(string? app_id, string? title);
}
