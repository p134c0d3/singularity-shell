using GLib;
using Gtk;
using Gee;

namespace Singularity {

    public class ScreenshotTool : Singularity.Shell.ShellDialog {
        private static ScreenshotTool? _instance = null;

        public void* focused_handle { get; set; default = null; }

        private Button _seg_screen;
        private Button _seg_window;
        private Button _seg_region;
        private string _active_mode = "screen";
        private Gtk.Entry _delay_entry;
        private Gtk.Switch _cursor_switch;
        private ulong screenshot_handler_id = 0;
        private bool _pending_region = false;
        private bool _pending_window = false;
        private Gee.HashMap<uint, string> _screenshot_notification_actions = new Gee.HashMap<uint, string>();

        public static ScreenshotTool get_default(Gtk.Application? app = null) {
            if (_instance == null) {
                _instance = new ScreenshotTool(app);
            }
            return _instance;
        }

        private ScreenshotTool(Gtk.Application? app) {
            Object(
                application: app as Gtk.Application,
                anchor_bottom: true,
                margin_bottom_value: 80
            );
        }

        construct {
            setup_styles();
            add_css_class("screenshot-tool");

            ScreenshotPortal.get_default().screenshot_failed.connect((err) => {
                if (err.down().contains("cancel")) return;
                _show_unavailable_dialog();
            });

            // Same surface as every other shell dialog: the ShellDialog window
            // is transparent, the visible card is a `.dialog-card` child, and a
            // gutter around it (SHADOW_MARGIN = 20px) leaves room for its shadow.
            var gutter = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            gutter.margin_top = 20;
            gutter.margin_bottom = 20;
            gutter.margin_start = 20;
            gutter.margin_end = 20;
            content_box.append(gutter);

            var card = new Gtk.Box(Gtk.Orientation.VERTICAL, 0);
            card.add_css_class("dialog-card");
            gutter.append(card);

            var box = new Gtk.Box(Gtk.Orientation.VERTICAL, 12);
            box.margin_top = 12;
            box.margin_bottom = 12;
            box.margin_start = 14;
            box.margin_end = 14;
            card.append(box);

            // Single row, left to right: mode selector, delay stepper,
            // video/photo capture, cursor switch.
            var row = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 16);
            row.halign = Gtk.Align.CENTER;
            box.append(row);

            // 1. Mode selector (three icons: screen, window, region).
            var seg_inner = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            seg_inner.add_css_class("segmented-inner");
            var seg_wrap = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            seg_wrap.add_css_class("segmented-control");
            seg_wrap.valign = Gtk.Align.CENTER;
            seg_wrap.append(seg_inner);

            _seg_screen = make_mode_button("video-display-symbolic", "Screen", "screen");
            _seg_screen.add_css_class("active");
            seg_inner.append(_seg_screen);

            _seg_window = make_mode_button("focus-windows-symbolic", "Window", "window");
            seg_inner.append(_seg_window);

            _seg_region = make_mode_button("selection-mode-symbolic", "Region", "region");
            seg_inner.append(_seg_region);

            row.append(seg_wrap);

            // 2. Delay field - leading timer icon, then a -/value/+ stepper.
            var delay_field = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 2);
            delay_field.add_css_class("screenshot-delay-field");
            delay_field.valign = Gtk.Align.CENTER;

            var timer_icon = new Gtk.Image.from_icon_name("alarm-symbolic");
            timer_icon.add_css_class("dim-label");
            timer_icon.margin_end = 4;
            delay_field.append(timer_icon);

            var minus_btn = new Gtk.Button.from_icon_name("list-remove-symbolic");
            minus_btn.add_css_class("flat");
            minus_btn.add_css_class("delay-step");
            minus_btn.tooltip_text = _("Decrease delay");
            minus_btn.clicked.connect(() => adjust_delay(-1));
            delay_field.append(minus_btn);

            _delay_entry = new Gtk.Entry();
            _delay_entry.text = "0";
            _delay_entry.width_chars = 2;
            _delay_entry.max_width_chars = 3;
            _delay_entry.xalign = 0.5f;
            _delay_entry.input_purpose = Gtk.InputPurpose.DIGITS;
            _delay_entry.add_css_class("flat");
            _delay_entry.valign = Gtk.Align.CENTER;
            delay_field.append(_delay_entry);

            var plus_btn = new Gtk.Button.from_icon_name("list-add-symbolic");
            plus_btn.add_css_class("flat");
            plus_btn.add_css_class("delay-step");
            plus_btn.tooltip_text = _("Increase delay");
            plus_btn.clicked.connect(() => adjust_delay(1));
            delay_field.append(plus_btn);

            row.append(delay_field);

            // 3. Video (record) / photo (capture) as a segmented control.
            var act_inner = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            act_inner.add_css_class("segmented-inner");
            var act_wrap = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 0);
            act_wrap.add_css_class("segmented-control");
            act_wrap.valign = Gtk.Align.CENTER;
            act_wrap.append(act_inner);

            var video_btn = new Gtk.Button();
            video_btn.icon_name = "camera-video-symbolic";
            video_btn.tooltip_text = _("Record Video");
            video_btn.add_css_class("segmented-button");
            video_btn.has_frame = false;
            video_btn.clicked.connect(on_video_clicked);
            act_inner.append(video_btn);

            var photo_btn = new Gtk.Button();
            photo_btn.icon_name = "camera-photo-symbolic";
            photo_btn.tooltip_text = _("Take Screenshot");
            photo_btn.add_css_class("segmented-button");
            photo_btn.has_frame = false;
            photo_btn.clicked.connect(on_take_clicked);
            act_inner.append(photo_btn);

            row.append(act_wrap);

            // 4. Mouse icon with an include-cursor switch to its right.
            var cursor_box = new Gtk.Box(Gtk.Orientation.HORIZONTAL, 8);
            cursor_box.valign = Gtk.Align.CENTER;
            var mouse_icon = new Gtk.Image.from_icon_name("input-mouse-symbolic");
            cursor_box.append(mouse_icon);
            _cursor_switch = new Gtk.Switch();
            _cursor_switch.active = true;
            _cursor_switch.valign = Gtk.Align.CENTER;
            _cursor_switch.tooltip_text = _("Include cursor");
            cursor_box.append(_cursor_switch);
            row.append(cursor_box);

            var mgr = SystemMonitor.get_default().notifications;
            mgr.action_invoked.connect((id, action) => {
                _handle_notification_action(id, action);
            });
        }

        private Gtk.Button make_mode_button(string icon, string tooltip, string mode) {
            var btn = new Gtk.Button();
            btn.icon_name = icon;
            btn.tooltip_text = tooltip;
            btn.add_css_class("segmented-button");
            btn.has_frame = false;
            btn.clicked.connect(() => set_mode(mode));
            return btn;
        }

        // Current delay in seconds, parsed from the entry and clamped to >= 0.
        private int current_delay() {
            int v = int.parse(_delay_entry.text);
            return v < 0 ? 0 : v;
        }

        // Step the delay entry by `step` seconds, never below zero.
        private void adjust_delay(int step) {
            int v = current_delay() + step;
            if (v < 0) v = 0;
            _delay_entry.text = v.to_string();
        }

        private void set_mode(string mode) {
            _active_mode = mode;
            if (mode == "screen") {
                _seg_screen.add_css_class("active");
                _seg_window.remove_css_class("active");
                _seg_region.remove_css_class("active");
            } else if (mode == "window") {
                _seg_screen.remove_css_class("active");
                _seg_window.add_css_class("active");
                _seg_region.remove_css_class("active");
            } else {
                _seg_screen.remove_css_class("active");
                _seg_window.remove_css_class("active");
                _seg_region.add_css_class("active");
            }
        }

        private void on_take_clicked() {
            int delay_secs = current_delay();

            _pending_region = (_active_mode == "region");
            _pending_window = (_active_mode == "window");

            hide();

            if (delay_secs > 0) {
                GLib.Timeout.add_seconds(delay_secs, () => {
                    dispatch_capture();
                    return GLib.Source.REMOVE;
                });
            } else {
                dispatch_capture();
            }
        }

        private void on_video_clicked() {
            hide();
            _start_screencast();
        }

        private void _start_screencast() {
            _start_screencast_async.begin();
        }

        private async void _start_screencast_async() {
            string? found = Environment.find_program_in_path("wf-recorder");
            if (found != null) {
                try {
                    var now = new DateTime.now_local();
                    string out_path = Environment.get_home_dir()
                        + "/Videos/Recording %s.mp4".printf(now.format("%Y-%m-%d %H-%M-%S"));
                    Process.spawn_async(null,
                        {"wf-recorder", "-f", out_path},
                        null, SpawnFlags.SEARCH_PATH, null, null);
                    var mgr = SystemMonitor.get_default().notifications;
                    mgr.notify("Screenshot Tool", 0, "media-record-symbolic",
                        "Screen Recording", "Recording started", {},
                        new HashTable<string, Variant>(str_hash, str_equal), -1);
                } catch (Error e) {
                    warning("[ScreenshotTool] wf-recorder failed: %s", e.message);
                }
                return;
            }
            var mgr = SystemMonitor.get_default().notifications;
            mgr.notify("Screenshot Tool", 0, "media-record-symbolic",
                "Screen Recording", "Install wf-recorder for screen recording",
                {}, new HashTable<string, Variant>(str_hash, str_equal), -1);
        }

        private void _notify_screenshot(string msg, string? file_path) {
            var mgr = SystemMonitor.get_default().notifications;
            string icon = file_path ?? "accessories-screenshot-symbolic";
            string[] actions = {};
            string? saved_path = null;
            if (file_path != null) {
                saved_path = ScreenshotPortal.get_default().save_to_pictures("file://" + file_path);
            }
            string open_path = saved_path ?? file_path;
            if (open_path != null) {
                actions += "open";
                actions += "Open";
                actions += "show";
                actions += "Show in Files";
                icon = open_path;
            }
            uint nid = mgr.notify("Screenshot", 0, icon,
                "Screenshot", msg, actions,
                new HashTable<string, Variant>(str_hash, str_equal), -1);
            _screenshot_notification_actions.set(nid, open_path);
        }

        private void _handle_notification_action(uint id, string action) {
            string? path = _screenshot_notification_actions.get(id);
            if (path == null) return;
            if (action == "open") {
                try {
                    AppInfo.launch_default_for_uri("file://" + path, null);
                } catch (Error e) {
                    warning("[ScreenshotTool] Failed to open: %s", e.message);
                }
            } else if (action == "show") {
                try {
                    var file = File.new_for_path(path);
                    var parent = file.get_parent();
                    if (parent != null)
                        AppInfo.launch_default_for_uri(parent.get_uri(), null);
                    try {
                        var bus = Bus.get_sync(BusType.SESSION);
                        bus.call_sync("org.freedesktop.FileManager1",
                            "/org/freedesktop/FileManager1",
                            "org.freedesktop.FileManager1",
                            "ShowItems",
                            new Variant("(ass)", new string[]{file.get_uri()}, ""),
                            null, DBusCallFlags.NONE, -1, null);
                    } catch {}
                } catch (Error e) {
                    warning("[ScreenshotTool] Failed to show in files: %s", e.message);
                }
            }
            _screenshot_notification_actions.remove(id);
        }

        private void dispatch_capture() {
            if (!ensure_screenshots()) return;
            if (_pending_region) {
                _do_region();
            } else if (_pending_window) {
                _do_window();
            } else {
                _do_fullscreen();
            }
        }

        public bool ensure_screenshots() {
            if (!ScreenshotPortal.get_default().is_available()) {
                _show_unavailable_dialog();
                return false;
            }
            return true;
        }

        private void _show_unavailable_dialog() {
            var app = application as Gtk.Application;
            if (app == null) return;
            hide();
            new PowerConfirmDialog(
                app,
                _("Screenshots unavailable"),
                "camera-photo-symbolic",
                _("Singularity could not capture a screenshot. The screenshot service is not available in this session. This usually means you are not running inside the Singularity session, or xdg-desktop-portal-singularity is not installed. See the documentation for details."),
                _("Open documentation"),
                () => {
                    try {
                        AppInfo.launch_default_for_uri("https://sinty.dev/docs/troubleshooting/", null);
                    } catch (Error e) {
                        warning("[ScreenshotTool] could not open docs: %s", e.message);
                    }
                }
            ).open_dialog();
        }

        private void _do_fullscreen() {
            var portal = ScreenshotPortal.get_default();
            if (screenshot_handler_id != 0) {
                portal.disconnect(screenshot_handler_id);
                screenshot_handler_id = 0;
            }
            screenshot_handler_id = portal.screenshot_taken.connect((uri) => {
                if (screenshot_handler_id != 0) {
                    portal.disconnect(screenshot_handler_id);
                    screenshot_handler_id = 0;
                }
                var file = GLib.File.new_for_uri(uri);
                string? path = file.get_path();
                if (path != null) portal.copy_to_clipboard(path);
                portal.save_to_pictures(uri);
                Singularity.Shell.ScreenFlash.flash();
                _notify_screenshot("Saved and copied to clipboard", path);
            });
            portal.take_screenshot.begin(false);
        }

        private void _do_region() {
            var portal = ScreenshotPortal.get_default();
            if (screenshot_handler_id != 0) {
                portal.disconnect(screenshot_handler_id);
                screenshot_handler_id = 0;
            }
            screenshot_handler_id = portal.screenshot_taken.connect((uri) => {
                if (screenshot_handler_id != 0) {
                    portal.disconnect(screenshot_handler_id);
                    screenshot_handler_id = 0;
                }
                var file = GLib.File.new_for_uri(uri);
                string? path = file.get_path();
                if (path != null) portal.copy_to_clipboard(path);
                portal.save_to_pictures(uri);
                Singularity.Shell.ScreenFlash.flash();
                _notify_screenshot("Region saved and copied to clipboard", path);
            });
            portal.take_screenshot.begin(true);
        }

        private void _do_window() {
            void* handle = focused_handle;
            if (handle == null) {
                _do_fullscreen();
                return;
            }
            var app_system = AppSystem.get_default();
            var win = app_system.get_window_by_handle(handle);
            if (win == null || win.snap_type == 0) {
                _do_fullscreen();
                return;
            }
            var monitors = Gdk.Display.get_default().get_monitors();
            var monitor = monitors.get_item(0) as Gdk.Monitor;
            if (monitor == null) { _do_fullscreen(); return; }
            var mon = monitor.get_geometry();
            int mw = mon.width;
            int mh = mon.height;

            int panel_h = app_system.shell_panel_height;
            int dock_h = app_system.shell_dock_height;
            int uw = mw;
            int uh = mh - panel_h - dock_h;
            int ux = 0;
            int uy = panel_h;

            int x, y, w, h;
            switch (win.snap_type) {
                case TilingLayout.SNAP_LEFT:         x=ux;       y=uy;       w=uw/2;  h=uh;   break;
                case TilingLayout.SNAP_RIGHT:        x=ux+uw/2;  y=uy;       w=uw/2;  h=uh;   break;
                case TilingLayout.SNAP_TOP_LEFT:     x=ux;       y=uy;       w=uw/2;  h=uh/2; break;
                case TilingLayout.SNAP_TOP_RIGHT:    x=ux+uw/2;  y=uy;       w=uw/2;  h=uh/2; break;
                case TilingLayout.SNAP_BOTTOM_LEFT:  x=ux;       y=uy+uh/2;  w=uw/2;  h=uh/2; break;
                case TilingLayout.SNAP_BOTTOM_RIGHT: x=ux+uw/2;  y=uy+uh/2;  w=uw/2;  h=uh/2; break;
                default: x=ux; y=uy; w=uw; h=uh; break;
            }

            string temp_path;
            try {
                int fd = GLib.FileUtils.open_tmp("singularity-screenshot-XXXXXX.png", out temp_path);
                Posix.close(fd);
            } catch (Error e) {
                warning("[ScreenshotTool] temp file: %s", e.message);
                _do_fullscreen();
                return;
            }
            string geometry = "%d,%d %dx%d".printf(x, y, w, h);
            try {
                string[] argv = {"/usr/bin/grim", "-g", geometry, temp_path};
                var proc = new GLib.Subprocess.newv(argv,
                    GLib.SubprocessFlags.STDOUT_SILENCE | GLib.SubprocessFlags.STDERR_SILENCE);
                proc.wait_async.begin(null, (obj, res) => {
                    try { proc.wait_async.end(res); } catch {}
                    if (!GLib.FileUtils.test(temp_path, GLib.FileTest.EXISTS)) {
                        _do_fullscreen();
                        return;
                    }
                    var portal = ScreenshotPortal.get_default();
                    portal.copy_to_clipboard(temp_path);
                    portal.save_to_pictures("file://" + temp_path);
                    Singularity.Shell.ScreenFlash.flash();
                    _notify_screenshot("Window captured and copied to clipboard", temp_path);
                    GLib.Timeout.add(3000, () => { GLib.FileUtils.unlink(temp_path); return false; });
                });
            } catch (Error e) {
                warning("[ScreenshotTool] grim spawn failed: %s", e.message);
                _do_fullscreen();
            }
        }
        private void setup_styles() {
            var provider = new Gtk.CssProvider();
            provider.load_from_data(SCREENSHOT_CSS.data);
            Gtk.StyleContext.add_provider_for_display(
                Gdk.Display.get_default(), provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }

        private const string SCREENSHOT_CSS = """
/* Screenshot Tool. The card surface (background, border, shadow) comes from
   the shared `.dialog-card` style; only the inner controls are styled here. */
.screenshot-tool .segmented-button {
    padding: 6px 16px;
}
.screenshot-tool .screenshot-delay-field {
    background-color: alpha(@text_color, 0.06);
    border-radius: 8px;
    padding: 2px 6px;
}
.screenshot-tool .screenshot-delay-field button.delay-step {
    min-width: 18px;
    min-height: 18px;
    padding: 0;
    margin: 0;
}
.screenshot-tool .screenshot-delay-field button.delay-step image {
    -gtk-icon-size: 12px;
}
.screenshot-tool .screenshot-delay-field entry {
    background: none;
    box-shadow: none;
    border: none;
    outline: none;
    min-height: 24px;
    padding: 0;
}
""";
    }
}