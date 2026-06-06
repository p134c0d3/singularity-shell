using Gtk;
using Vte;
using Singularity.Widgets;

namespace Singularity {

    public class DeveloperPage : SettingsPage {

        private static string LOG_FILE = GLib.Path.build_filename(
            GLib.Environment.get_user_state_dir(), "singularity", "singularity-desktop.log");

        /* Live-state labels (updated by timer) */
        private class ProcLabels {
            public Label pid;
            public Label cpu;
            public Label mem;
        }

        private Label _focused_val;
        private Label _wins_val;
        private Label _running_val;
        private Label _wallpaper_val;
        private Label _total_cpu_val;
        private Label _total_mem_val;
        private Gee.HashMap<string, ProcLabels> _proc_labels_map;

        /* Vte log terminal */
        private Vte.Terminal? _terminal = null;

        /* Signal handler IDs that must be disconnected on dispose */
        private ulong _sig_dbg_mode   = 0;
        private ulong _sig_hud        = 0;
        private ulong _sig_devtools   = 0;
        private ulong _sig_log        = 0;

        /* Refresh timer (only runs while page is mapped) */
        private uint _timer_id = 0;

        /* Optional per-display CSS provider for widget-border debug mode */
        private Gtk.CssProvider? _border_css = null;

        /* GSettings for tiling (kept alive as field) */
        private GLib.Settings _tiling_settings;

        public DeveloperPage (SettingsView view) {
            base(_("Developer"));

            var dbg = DebugManager.get_default ();
            _tiling_settings = new GLib.Settings ("dev.sinty.desktop");

            // Debug Control
            var debug_group = new PreferencesGroup (_("Debug"));
            debug_group.description = "Runtime instrumentation and overlay tools";

            var dbg_switch = new SwitchRow (_("Debug Mode"),
                "Enable verbose logging and activate debug sections");
            dbg_switch.active = dbg.debug_mode;
            _sig_dbg_mode = dbg.notify["debug-mode"].connect (() => {
                dbg_switch.active = dbg.debug_mode;
            });
            dbg_switch.switch_btn.notify["active"].connect (() => {
                dbg.debug_mode = dbg_switch.switch_btn.active;
            });
            debug_group.add_row (dbg_switch);

            var hud_switch = new SwitchRow (_("Show HUD Overlay"),
                "Floating live-stats panel above the shell");
            hud_switch.active = dbg.hud_visible;
            _sig_hud = dbg.notify["hud-visible"].connect (() => {
                hud_switch.active = dbg.hud_visible;
            });
            hud_switch.switch_btn.notify["active"].connect (() => {
                dbg.hud_visible = hud_switch.switch_btn.active;
            });
            debug_group.add_row (hud_switch);

            var devtools_switch = new SwitchRow (_("DevTools Overlay"),
                "Modular inspector: live values, widget tree, realtime events");
            devtools_switch.active = dbg.devtools_visible;
            _sig_devtools = dbg.notify["devtools-visible"].connect (() => {
                devtools_switch.active = dbg.devtools_visible;
            });
            devtools_switch.switch_btn.notify["active"].connect (() => {
                dbg.devtools_visible = devtools_switch.switch_btn.active;
            });
            debug_group.add_row (devtools_switch);

            var pin_switch = new SwitchRow (_("Keep Sidebar Open"),
                "Prevent sidebar from closing when focus is lost");
            pin_switch.active = dbg.sidebar_pinned;
            pin_switch.switch_btn.notify["active"].connect (() => {
                dbg.sidebar_pinned = pin_switch.switch_btn.active;
            });
            debug_group.add_row (pin_switch);

            var pin_overview = new SwitchRow (_("Keep Overview Open"),
                "Prevent the apps overview from closing when focus is lost (for screenshots)");
            pin_overview.active = dbg.overview_pinned;
            pin_overview.switch_btn.notify["active"].connect (() => {
                dbg.overview_pinned = pin_overview.switch_btn.active;
            });
            debug_group.add_row (pin_overview);

            var pin_workspaces = new SwitchRow (_("Keep Workspaces Open"),
                "Prevent the workspaces overview from closing when focus is lost (for screenshots)");
            pin_workspaces.active = dbg.workspaces_pinned;
            pin_workspaces.switch_btn.notify["active"].connect (() => {
                dbg.workspaces_pinned = pin_workspaces.switch_btn.active;
            });
            debug_group.add_row (pin_workspaces);

            add_group (debug_group);

            // GTK Rendering Tools
            var gtk_group = new PreferencesGroup (_("GTK Rendering Tools"));

            var inspector_row = new ActionRow (_("Open GTK Inspector"),
                "Inspect widget tree, CSS nodes and render tree",
                "applications-engineering-symbolic");
            var inspector_btn = new Button.with_label (_("Open"));
            inspector_btn.valign = Gtk.Align.CENTER;
            inspector_btn.add_css_class ("pill");
            inspector_btn.clicked.connect (() => {
                Gtk.Window.set_interactive_debugging (true);
            });
            inspector_row.add_suffix (inspector_btn);
            inspector_row.activated.connect (() => {
                Gtk.Window.set_interactive_debugging (true);
            });
            gtk_group.add_row (inspector_row);

            var anim_switch = new SwitchRow (_("Enable Animations"),
                "Toggle GTK animation system-wide");
            anim_switch.active = Gtk.Settings.get_default ().gtk_enable_animations;
            anim_switch.switch_btn.notify["active"].connect (() => {
                Gtk.Settings.get_default ().gtk_enable_animations = anim_switch.switch_btn.active;
            });
            gtk_group.add_row (anim_switch);

            var borders_switch = new SwitchRow (_("Show Widget Borders"),
                "Overlay accent-colored borders on every widget");
            borders_switch.switch_btn.notify["active"].connect (() => {
                toggle_widget_borders (borders_switch.switch_btn.active);
            });
            gtk_group.add_row (borders_switch);

            add_group (gtk_group);

            // App System
            var as_expander = new ExpanderRow (_("App System"),
                "Windows, running apps, focus state",
                "application-x-executable-symbolic");

            _focused_val  = make_val_label ("-");
            _wins_val     = make_val_label ("0");
            _running_val  = make_val_label ("0");

            as_expander.add_row (make_kv_row ("Focused App",   _focused_val));
            as_expander.add_row (make_kv_row ("Open Windows",  _wins_val));
            as_expander.add_row (make_kv_row ("Running Apps",  _running_val));

            var reload_apps = new ActionRow (_("Force apps-changed Signal"), null,
                "view-refresh-symbolic");
            reload_apps.activated.connect (() => {
                AppSystem.get_default ().apps_changed ();
            });
            as_expander.add_row (reload_apps);

            var appsys_group = new PreferencesGroup (_("App System"));
            appsys_group.add_row (as_expander);
            add_group (appsys_group);

            // Wallpaper Manager
            var wp_expander = new ExpanderRow (_("Wallpaper Manager"),
                "Current wallpaper and reload controls",
                "image-x-generic-symbolic");

            _wallpaper_val = make_val_label ("-");
            _wallpaper_val.ellipsize = Pango.EllipsizeMode.MIDDLE;
            _wallpaper_val.max_width_chars = 26;
            wp_expander.add_row (make_kv_row ("Current Path", _wallpaper_val));

            var wp_reload = new ActionRow (_("Reload Wallpaper"), null, "view-refresh-symbolic");
            wp_reload.activated.connect (() => {
                WallpaperManager.get_default ().reload ();
            });
            wp_expander.add_row (wp_reload);

            var wp_group = new PreferencesGroup (_("Wallpaper"));
            wp_group.add_row (wp_expander);
            add_group (wp_group);

            // Tiling Manager
            var tiling_group = new PreferencesGroup (_("Tiling Manager"));

            var tiling_switch = new SwitchRow (_("Auto-Tiling"),
                "Automatically tile windows on the active workspace");
            tiling_switch.active = _tiling_settings.get_boolean ("tiling-enabled");
            tiling_switch.switch_btn.notify["active"].connect (() => {
                _tiling_settings.set_boolean ("tiling-enabled", tiling_switch.switch_btn.active);
            });
            tiling_group.add_row (tiling_switch);

            var retile_row = new ActionRow (_("Apply Layout Now"), null, "view-grid-symbolic");
            retile_row.activated.connect (() => {
                DebugManager.get_default ().tiling_manager?.apply_layout ();
            });
            tiling_group.add_row (retile_row);

            add_group (tiling_group);

            // Hot Corners
            var hc_group = new PreferencesGroup (_("Hot Corners"));
            hc_group.description = "Simulate corner triggers programmatically";

            string[] corner_labels = { "Top-Left", "Top-Right", "Bottom-Left", "Bottom-Right" };
            string[] corner_icons  = {
                "go-up-symbolic", "go-up-symbolic",
                "go-down-symbolic", "go-down-symbolic"
            };
            for (int i = 0; i < 4; i++) {
                int idx = i;
                var row = new ActionRow (
                    "Trigger %s Corner".printf (corner_labels[i]),
                    null, corner_icons[i]);
                var btn = new Button.with_label (_("Trigger"));
                btn.valign = Gtk.Align.CENTER;
                btn.add_css_class ("pill");
                btn.clicked.connect (() => {
                    DebugManager.get_default ().hot_corner_manager?.simulate_corner (idx);
                });
                row.add_suffix (btn);
                hc_group.add_row (row);
            }
            add_group (hc_group);

            // Desktop Resources
            var dr_group = new PreferencesGroup (_("Desktop Resources"));
            dr_group.description = "CPU/RAM usage for desktop processes";

            var cpu_val = make_val_label ("0.0%");
            var mem_val = make_val_label ("0 MB");
            _total_cpu_val = cpu_val;
            _total_mem_val = mem_val;

            var procs_box = new Box (Orientation.VERTICAL, 0);
            procs_box.add_css_class ("linked");
            procs_box.margin_top = 6;
            procs_box.margin_bottom = 6;
            dr_group.add_row (procs_box);

            _proc_labels_map = new Gee.HashMap<string, ProcLabels> ();
            // Add process rows
            string[] desktop_procs = {
                "singularity-pol",
                "singularity-desktop",
                "labwc"
            };

            foreach (string proc in desktop_procs) {
                var row = new ActionRow (proc, null);
                var pid_val = make_val_label ("-");
                var cpu_val_proc = make_val_label ("0.0%");
                var mem_val_proc = make_val_label ("0 MB");

                row.add_suffix (pid_val);
                row.add_suffix (cpu_val_proc);
                row.add_suffix (mem_val_proc);

                procs_box.append (row);
                _proc_labels_map.set (proc, new ProcLabels () { pid = pid_val, cpu = cpu_val_proc, mem = mem_val_proc });
            }

            // Add total row
            var total_row = new ActionRow (_("TOTAL"), null);
            total_row.add_css_class ("bold");
            var lbl_total_cpu = make_val_label ("0.0%");
            var lbl_total_mem = make_val_label ("0 MB");
            _total_cpu_val = lbl_total_cpu;
            _total_mem_val = lbl_total_mem;
            total_row.add_suffix (lbl_total_cpu);
            total_row.add_suffix (lbl_total_mem);
            procs_box.append (total_row);

            add_group (dr_group);

            // Notifications
            var notif_group = new PreferencesGroup (_("Notifications"));

            var test_notif = new ActionRow (_("Send Test Notification"),
                "Bypass DND and inject directly into the notification display",
                "dialog-information-symbolic");
            test_notif.activated.connect (() => {
                // Emit new_notification directly to bypass DND for debug purposes
                SystemMonitor.get_default ().notifications.new_notification (
                    999999u, "Singularity Debug",
                    "Debug Test Notification",
                    "Sent from the Developer Debug Panel.",
                    "dialog-information", new string[0]);
            });
            notif_group.add_row (test_notif);

            add_group (notif_group);

            // XDG Portal
            var portal_group = new PreferencesGroup (_("XDG Portal"));
            portal_group.description = "Test connectivity with the Singularity Portal backend";

            var portal_status_val = make_val_label ("Unknown");
            var portal_status_row = make_kv_row ("Portal Backend Status", portal_status_val);

            var check_portal_btn = new Button.with_label (_("Check"));
            check_portal_btn.valign = Gtk.Align.CENTER;
            check_portal_btn.add_css_class ("pill");
            check_portal_btn.clicked.connect (() => {
                check_portal_status (portal_status_val);
            });
            portal_status_row.add_suffix (check_portal_btn);
            portal_group.add_row (portal_status_row);

            var test_screenshot_row = new ActionRow (_("Test Screenshot Portal"),
                "Trigger a screenshot request via XDG Desktop Portal",
                "camera-photo-symbolic");
            var screenshot_btn = new Button.with_label (_("Trigger"));
            screenshot_btn.valign = Gtk.Align.CENTER;
            screenshot_btn.add_css_class ("pill");
            screenshot_btn.clicked.connect (() => {
                ScreenshotPortal.get_default ().take_screenshot.begin (true);
            });
            test_screenshot_row.add_suffix (screenshot_btn);
            portal_group.add_row (test_screenshot_row);

            var test_chooser_row = new ActionRow (_("Test App Chooser"),
                "Trigger the application selection dialog via XDG Portal",
                "application-x-executable-symbolic");
            var chooser_btn = new Button.with_label (_("Trigger"));
            chooser_btn.valign = Gtk.Align.CENTER;
            chooser_btn.add_css_class ("pill");
            chooser_btn.clicked.connect (() => {
                test_app_chooser.begin ();
            });
            test_chooser_row.add_suffix (chooser_btn);
            portal_group.add_row (test_chooser_row);

            add_group (portal_group);

            // Window Preview
            var preview_group = new PreferencesGroup (_("Window Preview"));

            var preview_image = new Picture ();
            preview_image.content_fit = ContentFit.CONTAIN;
            preview_image.height_request = 180;
            preview_image.add_css_class ("workspace-preview");

            var preview_row = new ActionRow (_("First Window"), null, "view-app-grid-symbolic");
            var preview_btn = new Button.with_label (_("Capture"));
            preview_btn.valign = Gtk.Align.CENTER;
            preview_btn.add_css_class ("pill");
            preview_btn.clicked.connect (() => {
                capture_window_preview (preview_image);
            });
            preview_row.add_suffix (preview_btn);
            preview_group.add_row (preview_row);
            preview_group.add_row (preview_image);

            add_group (preview_group);

            // Shell Log
            var log_expander = new ExpanderRow (_("Shell Log"),
                "Live tail of " + LOG_FILE,
                "utilities-terminal-symbolic");
            log_expander.expanded = false;

            // Feed DebugManager log() calls into the terminal
            _sig_log = DebugManager.get_default ().log_message.connect ((module, level, msg) => {
                if (_terminal != null)
                    _terminal.feed ("[%s][%s] %s\r\n".printf (level, module, msg).data);
            });

            var log_btns = new Box (Orientation.HORIZONTAL, 6);
            log_btns.halign = Gtk.Align.END;
            log_btns.margin_end    = 8;
            log_btns.margin_top    = 4;
            log_btns.margin_bottom = 4;
            var clear_btn = new Button.with_label (_("Clear"));
            clear_btn.add_css_class ("pill");
            clear_btn.clicked.connect (() => ensure_terminal (log_expander).reset (true, true));
            var restart_log_btn = new Button.with_label (_("Restart Tail"));
            restart_log_btn.add_css_class ("pill");
            restart_log_btn.clicked.connect (() => start_tail (log_expander));

            // Restart Shell - must be a Button (ActionRow.activated won't fire in Box)
            var restart_shell_btn = new Button.with_label (_("Restart Shell"));
            restart_shell_btn.add_css_class ("pill");
            restart_shell_btn.add_css_class ("destructive-action");
            restart_shell_btn.clicked.connect (() => {
                Posix.kill ((Posix.pid_t) Posix.getpid (), Posix.Signal.USR1);
            });

            log_btns.append (clear_btn);
            log_btns.append (restart_log_btn);
            log_btns.append (restart_shell_btn);
            log_expander.add_row (log_btns);

            var log_group = new PreferencesGroup (_("Diagnostics"));
            log_group.add_row (log_expander);
            add_group (log_group);

            log_expander.notify["expanded"].connect (() => {
                if (log_expander.expanded && _terminal == null)
                    start_tail (log_expander);
            });
            update_live_labels ();
            update_desktop_resources ();

            map.connect (() => start_update_timer ());
            unmap.connect (() => stop_update_timer ());
        }

        // Helpers

        private Label make_val_label (string text) {
            var lbl = new Label (text);
            lbl.halign = Gtk.Align.END;
            lbl.hexpand = true;
            lbl.add_css_class ("caption");
            return lbl;
        }

        private ActionRow make_kv_row (string key, Widget value_widget) {
            var row = new ActionRow (key, null);
            row.add_suffix (value_widget);
            return row;
        }

        private void check_portal_status (Label status_label) {
            status_label.set_text ("Checking...");
            try {
                var conn = Bus.get_sync (BusType.SESSION);
                var proxy = new GLib.DBusProxy.for_bus_sync (
                    BusType.SESSION,
                    DBusProxyFlags.NONE,
                    null,
                    "org.freedesktop.DBus",
                    "/org/freedesktop/DBus",
                    "org.freedesktop.DBus"
                );

                var result = proxy.call_sync (
                    "GetNameOwner",
                    new Variant ("(s)", "org.freedesktop.impl.portal.desktop.singularity"),
                    DBusCallFlags.NONE,
                    -1,
                    null
                );

                if (result != null) {
                    string owner;
                    result.get ("(s)", out owner);
                    status_label.set_text ("Active (%s)".printf (owner));
                }
            } catch (Error e) {
                status_label.set_text ("Inactive (Not Running)");
            }
        }

        private async void test_app_chooser () {
            try {
                var conn = yield Bus.get (BusType.SESSION);
                var options = new VariantBuilder (new VariantType ("a{sv}"));
                
                // Add some dummy choices to force the dialog to appear
                string[] choices = { "org.gnome.TextEditor", "dev.sinty.edit", "firefox" };
                options.add ("{sv}", "choices", new Variant.strv (choices));
                options.add ("{sv}", "heading", new Variant.string ("Test Portal App Chooser"));

                yield conn.call (
                    "org.freedesktop.portal.Desktop",
                    "/org/freedesktop/portal/desktop",
                    "org.freedesktop.portal.AppChooser",
                    "OpenAppChooser",
                    new Variant ("(ssa{sv})", "", "", options),
                    null,
                    DBusCallFlags.NONE,
                    -1,
                    null
                );
            } catch (Error e) {
                warning ("Failed to trigger AppChooser portal: %s", e.message);
            }
        }

        // Widget borders debug CSS

        private void toggle_widget_borders (bool on) {
            if (on) {
                if (_border_css == null) {
                    _border_css = new Gtk.CssProvider ();
                    _border_css.load_from_string (
                        "* { box-shadow: inset 0 0 0 1px alpha(@accent_color, 0.55); }");
                }
                Gtk.StyleContext.add_provider_for_display (
                    Gdk.Display.get_default (), _border_css,
                    Gtk.STYLE_PROVIDER_PRIORITY_USER + 100);
            } else if (_border_css != null) {
                Gtk.StyleContext.remove_provider_for_display (
                    Gdk.Display.get_default (), _border_css);
            }
        }

        // Live label refresh

        private void update_live_labels () {
            var as = AppSystem.get_default ();
            _focused_val.set_text (as.get_focused_app_id () ?? "-");
            _wins_val.set_text (as.get_windows ().length ().to_string ());
            _running_val.set_text (as.get_running_apps ().length ().to_string ());

            var wp = WallpaperManager.get_default ().wallpaper_path;
            _wallpaper_val.set_text (wp != null ? GLib.Path.get_basename (wp) : "-");
        }

        // Desktop Resources

        private void update_desktop_resources () {
            if (_total_cpu_val == null || _total_mem_val == null || _proc_labels_map == null) return;

            try {
                double total_cpu = 0.0;
                double total_mem = 0.0;
                var seen = new Gee.HashSet<string> ();

                string ps_output;
                int exit_status;
                GLib.Process.spawn_command_line_sync (
                    "ps -eo pid=,pcpu=,rss=,comm= --sort=-rss",
                    out ps_output, null, out exit_status);
                if (exit_status != 0 || ps_output == null || ps_output.strip () == "") {
                    _total_cpu_val.set_text ("0.0%");
                    _total_mem_val.set_text ("0 MB");
                    return;
                }

                string[] lines = ps_output.strip ().split ("\n");

                foreach (string raw_line in lines) {
                    string line = raw_line.strip ();
                    if (line == "") continue;

                    while (line.contains ("  "))
                        line = line.replace ("  ", " ");

                    string[] parts = line.split (" ", 4);
                    if (parts.length < 4) continue;

                    int pid = int.parse (parts[0]);
                    double cpu = double.parse (parts[1]);
                    double rss_kb = double.parse (parts[2]);
                    double mem = rss_kb / 1024.0;
                    string comm = parts[3];

                    string matched_proc = null;
                    if (comm == "labwc") {
                        matched_proc = "labwc";
                    } else if (comm.has_prefix ("singularity-pol")) {
                        matched_proc = "singularity-pol";
                    } else if (comm.has_prefix ("singularity-des")) {
                        matched_proc = "singularity-desktop";
                    }
                    if (matched_proc == null) continue;
                    if (seen.contains (matched_proc)) continue;
                    seen.add (matched_proc);

                    if (_proc_labels_map.has_key (matched_proc)) {
                        var labels = _proc_labels_map.get (matched_proc);
                        labels.pid.set_text (pid.to_string ());
                        labels.mem.set_text ("%.1f MB".printf (mem));
                        labels.cpu.set_text ("%.2f%%".printf (cpu));
                        total_mem += mem;
                        total_cpu += cpu;
                    }
                }

                _total_cpu_val.set_text ("%.1f%%".printf (total_cpu));
                _total_mem_val.set_text ("%.1f MB".printf (total_mem));
            } catch (Error e) {
                warning ("Failed to update desktop resources: %s", e.message);
                _total_cpu_val.set_text ("0.0%");
                _total_mem_val.set_text ("0 MB");
            }
        }

        private void start_update_timer () {
            if (_timer_id != 0) return;
            update_live_labels ();
            update_desktop_resources ();
            _timer_id = Timeout.add (2000, () => {
                update_live_labels ();
                update_desktop_resources ();
                return Source.CONTINUE;
            });
        }

        private void stop_update_timer () {
            if (_timer_id != 0) {
                Source.remove (_timer_id);
                _timer_id = 0;
            }
        }

        // Window preview

        private void capture_window_preview (Picture target) {
            var windows = AppSystem.get_default ().get_windows ();
            if (windows.length () == 0) return;
            var win = windows.nth_data (0);
            Singularity.wayland_capture_preview (win.handle, (w, h, s, data) => {
                if (data == null) return;
                unowned uint8[] buf = (uint8[]) data;
                buf.length = h * s;
                var bytes   = new Bytes (buf);
                var texture = new Gdk.MemoryTexture (
                    w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, bytes, s);
                target.set_paintable (texture);
            });
        }

        // Log tail

        private Vte.Terminal ensure_terminal (ExpanderRow log_expander) {
            if (_terminal != null)
                return _terminal;

            _terminal = new Vte.Terminal ();
            _terminal.set_size (80, 16);
            _terminal.height_request = 220;
            _terminal.vexpand = false;
            _terminal.hexpand = true;
            var bg = Gdk.RGBA (); bg.parse ("#1e1e1e");
            var fg = Gdk.RGBA (); fg.parse ("#ffffff");
            _terminal.set_color_background (bg);
            _terminal.set_color_foreground (fg);
            log_expander.add_row (_terminal);
            return _terminal;
        }

        private void start_tail (ExpanderRow log_expander) {
            try {
                var terminal = ensure_terminal (log_expander);
                terminal.reset (true, true);
                string[] argv = { "/usr/bin/tail", "-f", LOG_FILE };
                terminal.spawn_async (PtyFlags.DEFAULT, null, argv, null,
                    SpawnFlags.SEARCH_PATH, null, -1, null,
                    (term, pid, err) => {
                        if (err != null)
                            terminal.feed (
                                "Failed to start log tail: %s\r\n"
                                .printf (err.message).data);
                    });
            } catch (Error e) {
                warning ("Error starting tail: %s", e.message);
            }
        }

        // Lifecycle

        protected override void dispose () {
            stop_update_timer ();
            var dbg = DebugManager.get_default ();
            if (_sig_dbg_mode != 0) {
                GLib.SignalHandler.disconnect (dbg, _sig_dbg_mode);
                _sig_dbg_mode = 0;
            }
            if (_sig_hud != 0) {
                GLib.SignalHandler.disconnect (dbg, _sig_hud);
                _sig_hud = 0;
            }
            if (_sig_devtools != 0) {
                GLib.SignalHandler.disconnect (dbg, _sig_devtools);
                _sig_devtools = 0;
            }
            if (_sig_log != 0) {
                GLib.SignalHandler.disconnect (dbg, _sig_log);
                _sig_log = 0;
            }
            if (_border_css != null) {
                Gtk.StyleContext.remove_provider_for_display (
                    Gdk.Display.get_default (), _border_css);
                _border_css = null;
            }
            base.dispose ();
        }
    }
}
