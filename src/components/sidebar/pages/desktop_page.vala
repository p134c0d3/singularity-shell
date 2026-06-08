using Gtk;
using GLib;
using Gee;
using Singularity.Widgets;

namespace Singularity {

    internal class WallpaperCandidate : Object {
        public string uri { get; private set; }
        public bool is_recent { get; private set; }

        public WallpaperCandidate(string uri, bool is_recent) {
            this.uri = uri;
            this.is_recent = is_recent;
        }
    }

    public class DesktopPage : SettingsPage {
        private GLib.Settings settings;
        private GLib.Settings? wm_settings;
        private bool decorations_updating_ui = false;
        private bool decorations_ignore_change = false;
        private Box? decorations_start_box;
        private Box? decorations_end_box;
        private Button? decorations_close_btn;
        private Button? decorations_min_btn;
        private Button? decorations_max_btn;
        private SwitchRow? decorations_close_row;
        private SwitchRow? decorations_min_row;
        private SwitchRow? decorations_max_row;
        private SelectionRow? decorations_side_row;
        private WallpaperPreviewWidget preview_widget;
        private FlowBox wallpaper_grid;
        private int wallpaper_grid_generation = 0;
        private int wallpaper_accent_generation = 0;
        private string cached_wallpaper_accent = "#3584e4";
        private static bool wallpaper_css_loaded = false;

        // Inline custom color picker state (class fields - never capture mutable locals)
        private ExpanderRow? custom_picker_row = null;
        private FlowBox? accent_colors_box = null;
        private DrawingArea? picker_sv_area = null;
        private DrawingArea? picker_hue_bar = null;
        private Entry? picker_hex_entry = null;
        private double picker_h = 210.0;
        private double picker_s = 0.73;
        private double picker_v = 0.89;
        private bool picker_hex_updating = false;
        private bool _eyedrop_in_progress = false;
        private uint _eyedrop_token = 0;

        public DesktopPage(SettingsView view) {
            base(_("Desktop"));
            ensure_wallpaper_css();
            settings = new GLib.Settings("dev.sinty.desktop");
            back_clicked.connect(() => {
                view.go_home();
            });
            var reset_btn = new Button.from_icon_name("edit-undo-symbolic");
            reset_btn.has_frame = false;
            reset_btn.tooltip_text = _("Reset to Default");
            reset_btn.add_css_class("navigation-button");
            reset_btn.clicked.connect(() => {
                settings.reset("background-picture-uri");
                update_preview();
            });
            header.append(reset_btn);
            var preview_group = new PreferencesGroup(_("Current Wallpaper"));
            var preview_widget = new WallpaperPreviewWidget();
            preview_widget.select_clicked.connect(() => {
                int64 ts = GLib.get_real_time();
                // Hand the result back through the per-user runtime dir (0700)
                // rather than a predictable name in world-writable /tmp.
                string rdir = GLib.Path.build_filename(GLib.Environment.get_user_runtime_dir(), "singularity");
                GLib.DirUtils.create_with_parents(rdir, 0700);
                string result_path = GLib.Path.build_filename(rdir, "wallpaper-%lld.uris".printf(ts));
                try {
                    string exe = GLib.FileUtils.read_link("/proc/self/exe");
                    string exe_dir = GLib.Path.get_dirname(exe);
                    string files_bin = GLib.Path.build_filename(exe_dir, "singularity-files");
                    if (!GLib.FileUtils.test(files_bin, GLib.FileTest.IS_EXECUTABLE)) {
                        files_bin = "singularity-files";
                    }
                    var launcher = new GLib.SubprocessLauncher(
                        GLib.SubprocessFlags.STDIN_INHERIT |
                        GLib.SubprocessFlags.STDOUT_SILENCE |
                        GLib.SubprocessFlags.STDERR_SILENCE
                    );
                    launcher.setenv("SINGULARITY_PORTAL_RESULT_FILE", result_path, true);
                    string[] argv = { files_bin, "--portal-mode", "--title=Select Wallpaper" };
                    var proc = launcher.spawnv(argv);
                    proc.wait_async.begin(null, (obj, res) => {
                        try { proc.wait_async.end(res); } catch (Error e) {}
                        if (GLib.FileUtils.test(result_path, GLib.FileTest.EXISTS)) {
                            try {
                                string content;
                                GLib.FileUtils.get_contents(result_path, out content);
                                GLib.FileUtils.unlink(result_path);
                                foreach (var line in content.strip().split("\n")) {
                                    string uri = line.strip();
                                    if (uri.length > 0) {
                                        set_wallpaper(uri);
                                        break;
                                    }
                                }
                            } catch (Error e) {
                                GLib.FileUtils.unlink(result_path);
                            }
                        }
                    });
                } catch (Error e) {
                    warning("Wallpaper picker: could not launch singularity-files: %s", e.message);
                }
            });
            this.preview_widget = preview_widget;
            var preview_row = new PreferencesRow();
            preview_row.set_child(preview_widget);
            preview_group.add_row(preview_row);
            add_group(preview_group);
            var grid_group = new PreferencesGroup(_("Wallpapers"));
            wallpaper_grid = new FlowBox();
            wallpaper_grid.add_css_class("wallpaper-gallery");
            wallpaper_grid.valign = Align.START;
            wallpaper_grid.halign = Align.FILL;
            wallpaper_grid.hexpand = true;
            wallpaper_grid.max_children_per_line = 2;
            wallpaper_grid.min_children_per_line = 2; // always two columns; the sidebar is sized for it
            wallpaper_grid.selection_mode = SelectionMode.NONE;
            wallpaper_grid.column_spacing = 14;
            wallpaper_grid.row_spacing = 14;
            wallpaper_grid.margin_top = 10;
            wallpaper_grid.margin_bottom = 10;
            wallpaper_grid.margin_start = 10;
            wallpaper_grid.margin_end = 10;
            var grid_row = new PreferencesRow();
            grid_row.set_child(wallpaper_grid);
            grid_group.add_row(grid_row);
            add_group(grid_group);
            GLib.Idle.add(() => { populate_grid(); return GLib.Source.REMOVE; });
            refresh_wallpaper_accent_async();
            update_preview_async();
            var wm = WallpaperManager.get_default();
            wm.wallpaper_changed.connect(() => {
                update_preview_async();
            });
            settings.changed["background-picture-uri"].connect(() => {
                refresh_wallpaper_accent_async();
                update_preview_async();
                update_wallpaper_selection();
            });
            settings.changed["recent-wallpapers"].connect(() => {
                populate_grid();
            });
            var app_group = new PreferencesGroup(_("Appearance"));

            // Theme preview
            var theme_preview_row = new PreferencesRow();
            theme_preview_row.activatable = false;
            var theme_preview = new DrawingArea();
            theme_preview.set_size_request(-1, 120);
            theme_preview.margin_top = 8;
            theme_preview.margin_bottom = 8;
            theme_preview.set_draw_func((area, ctx, pw, ph) => {
                bool is_dark = settings.get_boolean("dark-mode");
                string accent_name = settings.get_string("accent-color");
                Gdk.RGBA ac = Gdk.RGBA();
                switch (accent_name) {
                    case "teal":   ac.parse("#2190a4"); break;
                    case "green":  ac.parse("#3a944a"); break;
                    case "yellow": ac.parse("#e5a50a"); break;
                    case "orange": ac.parse("#e66100"); break;
                    case "red":    ac.parse("#e01b24"); break;
                    case "pink":   ac.parse("#d56199"); break;
                    case "purple": ac.parse("#9141ac"); break;
                    case "slate":  ac.parse("#787878"); break;
                    case "custom": {
                        string chex = settings.get_string("custom-accent-color");
                        if (chex == "" || !ac.parse(chex)) ac.parse("#3584e4");
                        break;
                    }
                    case "wallpaper": {
                        string uri2 = settings.get_string("background-picture-uri");
                        string hex2 = "#3584e4";
                        if (uri2 != "") {
                            hex2 = cached_wallpaper_accent;
                        }
                        ac.parse(hex2);
                        break;
                    }
                    default: ac.parse("#3584e4"); break;
                }

                double PI = Math.PI;
                double fg   = is_dark ? 0.70 : 0.35;
                double fg2  = is_dark ? 0.40 : 0.60;
                double wbg  = is_dark ? 0.16 : 0.96;
                double hbg  = is_dark ? 0.12 : 0.91;
                double sbg  = is_dark ? 0.14 : 0.93;
                double rr   = 8.0;
                double m    = 12.0;  // margin around window
                double wx   = m;
                double wy   = m;
                double ww   = pw - m * 2;
                double wh   = ph - m * 2;
                double hbH  = 24.0;
                double sw   = 52.0;

                // Window background
                ctx.new_sub_path();
                ctx.arc(wx + rr, wy + rr, rr, PI, 1.5*PI);
                ctx.arc(wx + ww - rr, wy + rr, rr, 1.5*PI, 2*PI);
                ctx.arc(wx + ww - rr, wy + wh - rr, rr, 0, 0.5*PI);
                ctx.arc(wx + rr, wy + wh - rr, rr, 0.5*PI, PI);
                ctx.close_path();
                ctx.set_source_rgb(wbg, wbg, wbg);
                ctx.fill();

                // Headerbar
                ctx.new_sub_path();
                ctx.arc(wx + rr, wy + rr, rr, PI, 1.5*PI);
                ctx.arc(wx + ww - rr, wy + rr, rr, 1.5*PI, 2*PI);
                ctx.line_to(wx + ww, wy + hbH);
                ctx.line_to(wx, wy + hbH);
                ctx.close_path();
                ctx.set_source_rgb(hbg, hbg, hbg);
                ctx.fill();
                // separator
                ctx.set_source_rgba(fg2, fg2, fg2, 0.2);
                ctx.rectangle(wx, wy + hbH, ww, 0.5);
                ctx.fill();
                // title
                ctx.set_source_rgba(fg, fg, fg, 0.5);
                ctx.rectangle(wx + ww/2 - 20, wy + hbH/2 - 3, 40, 5);
                ctx.fill();
                // close button - simple circle
                double cx = wx + ww - 13;
                double cy = wy + hbH/2;
                ctx.set_source_rgba(fg, fg, fg, 0.25);
                ctx.arc(cx, cy, 5, 0, 2*PI);
                ctx.fill();

                // Sidebar
                ctx.set_source_rgb(sbg, sbg, sbg);
                ctx.rectangle(wx, wy + hbH, sw, wh - hbH);
                ctx.fill();
                ctx.set_source_rgba(fg2, fg2, fg2, 0.15);
                ctx.rectangle(wx + sw, wy + hbH, 0.5, wh - hbH);
                ctx.fill();

                for (int ni = 0; ni < 3; ni++) {
                    double iy = wy + hbH + 12 + ni * 18;
                    bool active = (ni == 1);
                    if (active) {
                        // accent pill bg
                        double pr = 5.0, px2 = wx + 5, pyw = sw - 10, pyh = 13;
                        ctx.set_source_rgba(ac.red, ac.green, ac.blue, is_dark ? 0.20 : 0.13);
                        ctx.new_sub_path();
                        ctx.arc(px2 + pr, iy + pr, pr, PI, 1.5*PI);
                        ctx.arc(px2 + pyw - pr, iy + pr, pr, 1.5*PI, 2*PI);
                        ctx.arc(px2 + pyw - pr, iy + pyh - pr, pr, 0, 0.5*PI);
                        ctx.arc(px2 + pr, iy + pyh - pr, pr, 0.5*PI, PI);
                        ctx.close_path();
                        ctx.fill();
                        // accent dot
                        ctx.set_source_rgba(ac.red, ac.green, ac.blue, 0.9);
                    } else {
                        ctx.set_source_rgba(fg, fg, fg, 0.25);
                    }
                    ctx.arc(wx + 17, iy + 6, 4, 0, 2*PI);
                    ctx.fill();
                    ctx.set_source_rgba(fg, fg, fg, active ? 0.6 : 0.2);
                    ctx.rectangle(wx + 27, iy + 4, 18, 4);
                    ctx.fill();
                }

                // Content
                double ccx = wx + sw + 8;
                double ccy = wy + hbH + 8;
                double ccw = wx + ww - ccx - 8;
                double cch = wh - hbH - 16;

                // title line
                ctx.set_source_rgba(fg, fg, fg, 0.55);
                ctx.rectangle(ccx, ccy + 4, ccw * 0.5, 5);
                ctx.fill();
                // body lines
                ctx.set_source_rgba(fg, fg, fg, 0.2);
                ctx.rectangle(ccx, ccy + 16, ccw * 0.82, 4);
                ctx.fill();
                ctx.rectangle(ccx, ccy + 24, ccw * 0.65, 4);
                ctx.fill();

                // accent button
                double bw = 36.0, bh = 13.0, br2 = 4.0;
                double bx2 = ccx + ccw - bw;
                double by2 = ccy + cch - bh;
                ctx.set_source_rgba(ac.red, ac.green, ac.blue, 0.9);
                ctx.new_sub_path();
                ctx.arc(bx2 + br2, by2 + br2, br2, PI, 1.5*PI);
                ctx.arc(bx2 + bw - br2, by2 + br2, br2, 1.5*PI, 2*PI);
                ctx.arc(bx2 + bw - br2, by2 + bh - br2, br2, 0, 0.5*PI);
                ctx.arc(bx2 + br2, by2 + bh - br2, br2, 0.5*PI, PI);
                ctx.close_path();
                ctx.fill();
                ctx.set_source_rgba(1, 1, 1, 0.8);
                ctx.rectangle(bx2 + bw/2 - 10, by2 + bh/2 - 2, 20, 4);
                ctx.fill();

                // Window border
                ctx.new_sub_path();
                ctx.arc(wx + rr, wy + rr, rr, PI, 1.5*PI);
                ctx.arc(wx + ww - rr, wy + rr, rr, 1.5*PI, 2*PI);
                ctx.arc(wx + ww - rr, wy + wh - rr, rr, 0, 0.5*PI);
                ctx.arc(wx + rr, wy + wh - rr, rr, 0.5*PI, PI);
                ctx.close_path();
                ctx.set_source_rgba(fg2, fg2, fg2, is_dark ? 0.35 : 0.20);
                ctx.set_line_width(0.8);
                ctx.stroke();
            });
            settings.changed["dark-mode"].connect(() => { theme_preview.queue_draw(); });
            settings.changed["accent-color"].connect(() => { theme_preview.queue_draw(); });
            settings.changed["background-picture-uri"].connect(() => { theme_preview.queue_draw(); });
            theme_preview_row.set_child(theme_preview);
            app_group.add_row(theme_preview_row);

            bool dark_mode = settings.get_boolean("dark-mode");
            var dark_row = new SwitchRow(_("Dark Mode"), _("Use dark theme"), dark_mode);
            dark_row.switch_btn.notify["active"].connect(() => {
                bool active = dark_row.switch_btn.active;
                settings.set_boolean("dark-mode", active);
                // color-scheme propagation is handled centrally by update_theme_mode()
                // via the settings.changed["dark-mode"] signal in main.vala.
            });
            app_group.add_row(dark_row);

            var accent_row = new PreferencesRow();
            var accent_box = new Box(Orientation.VERTICAL, 12);
            accent_box.margin_top = 12;
            accent_box.margin_bottom = 12;
            accent_box.margin_start = 12;
            accent_box.margin_end = 12;
            var accent_lbl = new Label(_("Accent Color"));
            accent_lbl.add_css_class("title");
            accent_lbl.halign = Align.START;
            accent_box.append(accent_lbl);
            var colors_box = new FlowBox();
            colors_box.halign = Align.CENTER;
            colors_box.margin_top = 4;
            colors_box.column_spacing = 8;
            colors_box.row_spacing = 8;
            colors_box.max_children_per_line = 5;
            colors_box.min_children_per_line = 1;
            colors_box.selection_mode = SelectionMode.NONE;
            string[] colors = {"blue", "teal", "green", "yellow", "orange", "red", "pink", "purple", "slate", "wallpaper"};
            string[] hex_values = {"#3584e4", "#2190a4", "#3a944a", "#e5a50a", "#e66100", "#e01b24", "#d56199", "#9141ac", "#787878", "#000000"};
            for (int i = 0; i < colors.length; i++) {
                var color = colors[i];
                var hex = hex_values[i];
                var btn = new Button();
                btn.add_css_class("circular-button");
                if (color == "wallpaper") {
                    btn.tooltip_text = _("Wallpaper Color");
                }
                var da = new DrawingArea();
                da.set_size_request(24, 24);
                da.set_draw_func((area, ctx, w, h) => {
                    Gdk.RGBA c = Gdk.RGBA();
                    if (color == "wallpaper") {
                        string uri = settings.get_string("background-picture-uri");
                        string dyn_hex = "#3584e4";
                        if (uri != "") {
                            dyn_hex = cached_wallpaper_accent;
                        }
                        c.parse(dyn_hex);
                    } else {
                        c.parse(hex);
                    }
                    ctx.set_source_rgba(c.red, c.green, c.blue, 1.0);
                    ctx.arc(w/2.0, h/2.0, w/2.0 - 2, 0, 2 * Math.PI);
                    ctx.fill();
                    if (settings.get_string("accent-color") == color) {
                        ctx.set_source_rgba(1, 1, 1, 0.8);
                        ctx.arc(w/2.0, h/2.0, 4, 0, 2 * Math.PI);
                        ctx.fill();
                    }
                });
                if (color == "wallpaper") {
                    var overlay = new Overlay();
                    overlay.set_child(da);
                    var icon = new Image.from_icon_name("preferences-desktop-wallpaper-symbolic");
                    icon.pixel_size = 12;
                    icon.halign = Align.CENTER;
                    icon.valign = Align.CENTER;
                    icon.opacity = 0.8;
                    overlay.add_overlay(icon);
                    btn.set_child(overlay);
                } else {
                    btn.set_child(da);
                }
                btn.clicked.connect(() => {
                    settings.set_string("accent-color", color);
                    if (color != "wallpaper") {
                         try {
                            var interface_settings = new GLib.Settings("org.gnome.desktop.interface");
                            interface_settings.set_string("accent-color", color);
                         } catch (Error e) {
                         }
                    }
                    Widget? child = colors_box.get_first_child();
                    while (child != null) {
                        var fb_child = child as FlowBoxChild;
                        if (fb_child != null) {
                            var b = fb_child.get_child() as Button;
                            if (b != null) {
                                var content = b.get_child();
                                if (content is DrawingArea) {
                                    content.queue_draw();
                                } else if (content is Overlay) {
                                    var da_child = content.get_child();
                                    if (da_child != null) da_child.queue_draw();
                                }
                            }
                        }
                        child = child.get_next_sibling();
                    }
                });
                colors_box.append(btn);
            }

            // Saved custom colors render as their own swatches; a trailing
            // rainbow "+" button opens the picker to create a new one.
            accent_colors_box = colors_box;
            rebuild_custom_swatches();
            settings.changed["custom-accent-colors"].connect(() => {
                rebuild_custom_swatches();
            });
            settings.changed["accent-color"].connect(() => {
                if (custom_picker_row != null)
                    custom_picker_row.expanded = (settings.get_string("accent-color") == "custom");
                refresh_all_swatches(colors_box);
            });
            settings.changed["custom-accent-color"].connect(() => {
                refresh_all_swatches(colors_box);
            });
            settings.changed["background-picture-uri"].connect(() => {
                 Widget? child = colors_box.get_first_child();
                 while (child != null) {
                    var fb_child = child as FlowBoxChild;
                    if (fb_child != null) {
                        var b = fb_child.get_child() as Button;
                        if (b != null && b.tooltip_text == "Wallpaper Color") {
                             var btn_child = b.get_child();
                             if (btn_child != null) btn_child.queue_draw();
                        }
                    }
                    child = child.get_next_sibling();
                 }
            });
            accent_box.append(colors_box);
            accent_row.set_child(accent_box);
            app_group.add_row(accent_row);

            // Custom Color Picker (inline, expander)
            // Init HSV from stored value
            {
                string stored = settings.get_string("custom-accent-color");
                Gdk.RGBA ic = Gdk.RGBA();
                if (stored != "" && ic.parse(stored))
                    picker_rgb_to_hsv(ic.red, ic.green, ic.blue,
                                      out picker_h, out picker_s, out picker_v);
            }
            custom_picker_row = new ExpanderRow(_("Custom Accent Color"), _("Pick a precise color"));
            custom_picker_row.expanded = (settings.get_string("accent-color") == "custom");

            var picker_pad = new Box(Orientation.VERTICAL, 8);
            picker_pad.margin_top = 8;
            picker_pad.margin_bottom = 12;
            picker_pad.margin_start = 12;
            picker_pad.margin_end = 12;

            picker_sv_area = new DrawingArea();
            picker_sv_area.set_size_request(-1, 150);
            picker_sv_area.hexpand = true;
            picker_sv_area.add_css_class("picker-sv");
            picker_sv_area.set_draw_func((area, ctx, w, h) => { _draw_sv(ctx, w, h); });

            var sv_drag = new GestureDrag();
            sv_drag.drag_begin.connect((x, y) => { _on_sv_pos(x, y); });
            sv_drag.drag_update.connect((dx, dy) => {
                double sx, sy;
                sv_drag.get_start_point(out sx, out sy);
                _on_sv_pos(sx + dx, sy + dy);
            });
            picker_sv_area.add_controller(sv_drag);
            picker_pad.append(picker_sv_area);

            picker_hue_bar = new DrawingArea();
            picker_hue_bar.set_size_request(-1, 18);
            picker_hue_bar.hexpand = true;
            picker_hue_bar.set_draw_func((area, ctx, w, h) => { _draw_hue(ctx, w, h); });

            var hue_drag = new GestureDrag();
            hue_drag.drag_begin.connect((x, y) => { _on_hue_pos(x); });
            hue_drag.drag_update.connect((dx, dy) => {
                double sx, sy;
                hue_drag.get_start_point(out sx, out sy);
                _on_hue_pos(sx + dx);
            });
            picker_hue_bar.add_controller(hue_drag);
            picker_pad.append(picker_hue_bar);

            var hex_row2 = new Box(Orientation.HORIZONTAL, 8);
            hex_row2.valign = Align.CENTER;
            var hex_lbl = new Label(_("Hex"));
            hex_lbl.add_css_class("dim-label");
            hex_row2.append(hex_lbl);
            picker_hex_entry = new Entry();
            picker_hex_entry.max_length = 7;
            picker_hex_entry.hexpand = true;
            picker_hex_entry.text = _hsv_to_hex(picker_h, picker_s, picker_v);
            picker_hex_entry.changed.connect(_on_hex_changed);
            hex_row2.append(picker_hex_entry);

            // Eyedropper button - picks a color from any pixel on screen via XDG portal
            var eyedrop_btn = new Button.from_icon_name("color-select-symbolic");
            eyedrop_btn.add_css_class("flat");
            eyedrop_btn.add_css_class("circular");
            eyedrop_btn.tooltip_text = _("Pick color from screen");
            eyedrop_btn.clicked.connect(_start_eyedropper);
            hex_row2.append(eyedrop_btn);

            var save_btn = new Button.from_icon_name("list-add-symbolic");
            save_btn.add_css_class("flat");
            save_btn.add_css_class("circular");
            save_btn.tooltip_text = _("Save to palette");
            save_btn.clicked.connect(() => {
                string hex = settings.get_string("custom-accent-color");
                if (hex.has_prefix("#") && hex.length == 7) add_custom_color(hex);
            });
            hex_row2.append(save_btn);

            picker_pad.append(hex_row2);

            custom_picker_row.add_row(picker_pad);
            app_group.add_row(custom_picker_row);


            var sing_themes = new Gee.ArrayList<string>();
            sing_themes.add("Default");
            foreach (string t in Singularity.Style.StyleManager.list_singularity_themes())
                sing_themes.add(t);
            string current_sing_theme = settings.get_string("singularity-theme");
            string current_sing_label = current_sing_theme == "" ? "Default" : current_sing_theme;
            var sing_row = new SelectionRow(_("Singularity Theme"),
                sing_themes.to_array(), current_sing_label);
            sing_row.subtitle = _("Visual style for Singularity apps");
            sing_row.selected.connect((val) => {
                settings.set_string("singularity-theme", val == "Default" ? "" : val);
            });
            app_group.add_row(sing_row);

            // Theme Fine Tuning expander
            var tuning_row = new ExpanderRow(_("Theme Fine Tuning"), _("Advanced GTK and Qt theme overrides"));
            tuning_row.add_css_class("tuning-expander");

            // Enumerate available GTK3 themes - scan all XDG system data dirs so
            // /opt/local/share/themes and any future prefix are discovered automatically.
            string[] theme_dirs = {};
            foreach (unowned string d in GLib.Environment.get_system_data_dirs())
                theme_dirs += GLib.Path.build_filename(d, "themes");
            theme_dirs += GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".local", "share", "themes");
            theme_dirs += GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".themes");
            var gtk3_themes = new Gee.ArrayList<string>();
            var gtk4_themes = new Gee.ArrayList<string>();
            gtk3_themes.add("Adwaita");
            gtk4_themes.add("Adwaita");
            foreach (string tdir in theme_dirs) {
                try {
                    var dir = Dir.open(tdir);
                    string? name;
                    while ((name = dir.read_name()) != null) {
                        if (name.has_prefix(".") || name == "Singularity") continue;
                        string gtk3_css = GLib.Path.build_filename(tdir, name, "gtk-3.0", "gtk.css");
                        string gtk4_css = GLib.Path.build_filename(tdir, name, "gtk-4.0", "gtk.css");
                        if (GLib.FileUtils.test(gtk3_css, GLib.FileTest.EXISTS) && !gtk3_themes.contains(name))
                            gtk3_themes.add(name);
                        if (GLib.FileUtils.test(gtk4_css, GLib.FileTest.EXISTS) && !gtk4_themes.contains(name))
                            gtk4_themes.add(name);
                    }
                } catch (Error e) {}
            }
            gtk3_themes.sort((a, b) => strcmp(a, b));
            gtk4_themes.sort((a, b) => strcmp(a, b));

            // Current GTK theme (from gsettings)
            string current_gtk_theme = "Adwaita";
            try {
                var iface = new GLib.Settings("org.gnome.desktop.interface");
                current_gtk_theme = iface.get_string("gtk-theme");
            } catch (Error e) {}

            // GTK3 selector
            var gtk3_row = new SelectionRow(_("GTK3 Theme"), gtk3_themes.to_array(), current_gtk_theme);
            gtk3_row.selected.connect((val) => {
                try {
                    var iface = new GLib.Settings("org.gnome.desktop.interface");
                    iface.set_string("gtk-theme", val);
                } catch (Error e) {
                    warning("desktop: failed to set gtk-theme: %s", e.message);
                }
                try {
                    string gtk3_dir = GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".config", "gtk-3.0");
                    GLib.DirUtils.create_with_parents(gtk3_dir, 0755);
                    string ini_path = GLib.Path.build_filename(gtk3_dir, "settings.ini");
                    bool dark = settings.get_boolean("dark-mode");
                    string prefer = dark ? "1" : "0";
                    GLib.FileUtils.set_contents(ini_path,
                        "[Settings]\ngtk-application-prefer-dark-theme=%s\ngtk-theme-name=%s\n".printf(prefer, val));
                } catch (Error e) {
                    warning("desktop: failed to write gtk-3.0/settings.ini: %s", e.message);
                }
            });
            tuning_row.add_row(gtk3_row);

            // GTK4 selector
            string current_gtk4_theme = "Adwaita";
            try {
                string ini_path = GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".config", "gtk-4.0", "settings.ini");
                string contents;
                if (GLib.FileUtils.get_contents(ini_path, out contents)) {
                    foreach (string line in contents.split("\n")) {
                        if (line.has_prefix("gtk-theme-name=")) {
                            current_gtk4_theme = line.substring("gtk-theme-name=".length).strip();
                            break;
                        }
                    }
                }
            } catch (Error e) {}
            var gtk4_row = new SelectionRow(_("GTK4 Theme"), gtk4_themes.to_array(), current_gtk4_theme);
            gtk4_row.selected.connect((val) => {
                try {
                    string gtk4_dir = GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".config", "gtk-4.0");
                    GLib.DirUtils.create_with_parents(gtk4_dir, 0755);
                    bool dark = settings.get_boolean("dark-mode");
                    string prefer = dark ? "1" : "0";
                    GLib.FileUtils.set_contents(GLib.Path.build_filename(gtk4_dir, "settings.ini"),
                        "[Settings]\ngtk-application-prefer-dark-theme=%s\ngtk-theme-name=%s\n".printf(prefer, val));
                } catch (Error e) {
                    warning("desktop: failed to write gtk-4.0/settings.ini: %s", e.message);
                }
            });
            tuning_row.add_row(gtk4_row);

            // Icon theme selector (applies to the shell and all apps)
            string[] icon_themes = list_icon_themes();
            string current_icon = settings.get_string("icon-theme");
            if (current_icon == "") current_icon = "Singularity";
            var icon_row = new SelectionRow(_("Icon Theme"), icon_themes, current_icon);
            icon_row.selected.connect((val) => {
                settings.set_string("icon-theme", val);
            });
            tuning_row.add_row(icon_row);

            // Qt theme selector (Kvantum if installed, otherwise informational)
            bool kvantum_available = GLib.Environment.find_program_in_path("kvantummanager") != null;
            var qt_themes = new Gee.ArrayList<string>();
            qt_themes.add("Default");
            if (kvantum_available) {
                string[] kvantum_dirs = {
                    "/usr/share/Kvantum",
                    GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".config", "Kvantum")
                };
                foreach (string kdir in kvantum_dirs) {
                    try {
                        var dir = Dir.open(kdir);
                        string? name;
                        while ((name = dir.read_name()) != null) {
                            if (!name.has_prefix(".") && !qt_themes.contains(name))
                                qt_themes.add(name);
                        }
                    } catch (Error e) {}
                }
            }
            string qt_subtitle = kvantum_available ? null : "Install kvantum for Qt theme support";
            var qt_row = new SelectionRow(_("Qt Theme"), qt_themes.to_array(), _("Default"));
            if (qt_subtitle != null) {
                qt_row.subtitle = qt_subtitle;
            }
            qt_row.selected.connect((val) => {
                if (!kvantum_available) return;
                try {
                    string kv_dir = GLib.Path.build_filename(GLib.Environment.get_home_dir(), ".config", "Kvantum");
                    GLib.DirUtils.create_with_parents(kv_dir, 0755);
                    GLib.FileUtils.set_contents(GLib.Path.build_filename(kv_dir, "kvantum.kvconfig"),
                        "[General]\ntheme=%s\n".printf(val));
                } catch (Error e) {
                    warning("desktop: failed to write Kvantum config: %s", e.message);
                }
            });
            tuning_row.add_row(qt_row);

            app_group.add_row(tuning_row);
            add_group(app_group);

            var launcher_group = new PreferencesGroup(_("App Launcher"));
            string current_launcher_mode = settings.get_string("app-launcher-mode");
            var launcher_row = new SelectionRow("Launcher Style", {"Fullscreen", "Menu"}, current_launcher_mode == "menu" ? "Menu" : "Fullscreen");
            launcher_row.selected.connect((item) => {
                settings.set_string("app-launcher-mode", item == "Menu" ? "menu" : "fullscreen");
            });
            launcher_group.add_row(launcher_row);
            add_group(launcher_group);

            var desktop_group = new PreferencesGroup(_("Desktop Icons"));
            var icons_row = new SwitchRow(_("Show Desktop Icons"), _("Display files from ~/Desktop on screen"), settings.get_boolean("show-desktop-icons"));
            icons_row.switch_btn.notify["active"].connect(() => {
                settings.set_boolean("show-desktop-icons", icons_row.switch_btn.active);
            });
            desktop_group.add_row(icons_row);
            add_group(desktop_group);

            var settings_group = new PreferencesGroup(_("Settings"));
            var settings_window_row = new SwitchRow(
                "Open Settings in Window",
                "Open Settings in a dedicated window instead of the sidebar",
                settings.get_boolean("settings-in-window")
            );
            settings_window_row.switch_btn.notify["active"].connect(() => {
                settings.set_boolean("settings-in-window", settings_window_row.switch_btn.active);
            });
            settings_group.add_row(settings_window_row);
            add_group(settings_group);

            var wm_group = new PreferencesGroup(_("Window Management"));
            var rounded_row = new SwitchRow(_("Rounded Corners"), _("Round app window corners when not maximized or tiled"), settings.get_boolean("window-rounded-corners"));
            rounded_row.switch_btn.notify["active"].connect(() => {
                settings.set_boolean("window-rounded-corners", rounded_row.switch_btn.active);
            });
            wm_group.add_row(rounded_row);

            var tile_row = new SwitchRow(_("Tiling"), _("Automatically arrange windows in a grid"), settings.get_boolean("tiling-enabled"));
            tile_row.switch_btn.notify["active"].connect(() => {
                settings.set_boolean("tiling-enabled", tile_row.switch_btn.active);
            });
            wm_group.add_row(tile_row);

            var ssd_row = new SwitchRow(_("Disable Client Side Decorations"), _("Force standard window titles (requires app restart)"), settings.get_boolean("force-ssd"));
            ssd_row.switch_btn.notify["active"].connect(() => {
                settings.set_boolean("force-ssd", ssd_row.switch_btn.active);
            });
            wm_group.add_row(ssd_row);

            var legacy_row = new SwitchRow(_("Legacy Titlebar"), _("Use a classic titlebar with inline buttons instead of floating hover controls (requires app restart)"), settings.get_boolean("legacy-titlebar"));
            legacy_row.switch_btn.notify["active"].connect(() => {
                settings.set_boolean("legacy-titlebar", legacy_row.switch_btn.active);
            });
            wm_group.add_row(legacy_row);
            add_group(wm_group);

            // Host GTK window decoration layout (titlebar buttons)
            if (gsettings_schema_exists("org.gnome.desktop.wm.preferences")) {
                wm_settings = new GLib.Settings("org.gnome.desktop.wm.preferences");
                build_window_decorations_group();
            } else {
                var decor_group = new PreferencesGroup(_("Window Decorations"), _("Not available on this system"));
                decor_group.add_row(new ActionRow(_("Window decorations"), _("Missing schema org.gnome.desktop.wm.preferences")));
                add_group(decor_group);
            }

            var ws_group = new PreferencesGroup(_("Workspaces"));
            var dyn_row = new SwitchRow(_("Dynamic Workspaces"), _("Automatically remove empty workspaces"), settings.get_boolean("dynamic-workspaces"));
            dyn_row.switch_btn.notify["active"].connect(() => {
                settings.set_boolean("dynamic-workspaces", dyn_row.switch_btn.active);
            });
            ws_group.add_row(dyn_row);
            var count_row = new SpinRow("Fixed Workspace Count", null, 1, 10, 1, settings.get_int("workspace-count"));
            count_row.spin_btn.value_changed.connect(() => {
                settings.set_int("workspace-count", (int)count_row.spin_btn.value);
            });
            settings.bind("dynamic-workspaces", count_row.spin_btn, "sensitive", SettingsBindFlags.INVERT_BOOLEAN);
            ws_group.add_row(count_row);
            add_group(ws_group);
            var dock_group = new PreferencesGroup(_("Dock"));
            var vis_row = new SwitchRow("Always Visible", "Show dock on desktop", settings.get_string("dock-visibility-mode") == "always");
            vis_row.switch_btn.notify["active"].connect(() => {
                settings.set_string("dock-visibility-mode", vis_row.switch_btn.active ? "always" : "overview-only");
            });
            dock_group.add_row(vis_row);

            var autohide_row = new SwitchRow(_("Autohide"), _("Hide dock when not in use"), settings.get_boolean("dock-autohide"));
            autohide_row.switch_btn.notify["active"].connect(() => {
                settings.set_boolean("dock-autohide", autohide_row.switch_btn.active);
            });
            dock_group.add_row(autohide_row);

            var intelli_row = new SwitchRow(_("Hide if Maximized"), _("Hide dock when a window is maximized"), settings.get_boolean("dock-intellihide"));
            intelli_row.switch_btn.notify["active"].connect(() => {
                settings.set_boolean("dock-intellihide", intelli_row.switch_btn.active);
            });
            dock_group.add_row(intelli_row);

            settings.changed["dock-visibility-mode"].connect(() => {
                bool always = settings.get_string("dock-visibility-mode") == "always";
                autohide_row.sensitive = always;
                intelli_row.sensitive = always;
            });
            {
                bool always = settings.get_string("dock-visibility-mode") == "always";
                autohide_row.sensitive = always;
                intelli_row.sensitive = always;
            }

            string current_pos = settings.get_string("dock-position");
            string pos_label = "Bottom";
            if (current_pos == "left") pos_label = "Left";
            else if (current_pos == "right") pos_label = "Right";
            var pos_row = new SelectionRow(_("Position"), {_("Bottom"), _("Left"), _("Right")}, pos_label);
            pos_row.selected.connect((item) => {
                settings.set_string("dock-position", item.down());
            });
            dock_group.add_row(pos_row);
            add_group(dock_group);
            var adv_dock_group = new PreferencesGroup(_("Advanced Dock"));
            string current_style = settings.get_string("dock-style");
            var style_row = new SelectionRow("Style", {"Floating", "Panel"}, current_style == "panel" ? "Panel" : "Floating");
            style_row.selected.connect((item) => {
                settings.set_string("dock-style", item.down());
            });
            adv_dock_group.add_row(style_row);
            var extended_row = new SwitchRow(_("Extended Taskbar Mode"), _("Show window titles (panel style only)"), settings.get_boolean("dock-extended-mode"));
            extended_row.switch_btn.notify["active"].connect(() => {
                settings.set_boolean("dock-extended-mode", extended_row.switch_btn.active);
            });
            adv_dock_group.add_row(extended_row);
            string current_align = settings.get_string("dock-alignment");
            string align_label = "Center";
            if (current_align == "start") align_label = "Start";
            else if (current_align == "end") align_label = "End";
            var align_row = new SelectionRow(_("Alignment"), {_("Start"), _("Center"), _("End")}, align_label);
            align_row.selected.connect((item) => {
                settings.set_string("dock-alignment", item.down());
            });
            adv_dock_group.add_row(align_row);
            var fusion_row = new SwitchRow(_("Panel Fusion"), _("Merge top panel into dock"), settings.get_boolean("panel-fusion"));
            fusion_row.switch_btn.notify["active"].connect(() => {
                bool active = fusion_row.switch_btn.active;
                settings.set_boolean("panel-fusion", active);
                if (active) {
                    settings.set_string("dock-visibility-mode", "always");
                    vis_row.switch_btn.active = true;
                    vis_row.sensitive = false;
                    vis_row.subtitle = _("Forced visible by Panel Fusion");
                } else {
                    vis_row.sensitive = true;
                    vis_row.subtitle = _("Show dock on desktop");
                }
            });
            if (settings.get_boolean("panel-fusion")) {
                vis_row.sensitive = false;
                vis_row.subtitle = _("Forced visible by Panel Fusion");
            }
            adv_dock_group.add_row(fusion_row);
            var flat_panel_row = new SwitchRow(_("Flat Panel"), _("Solid black background instead of transparent"), settings.get_boolean("panel-flat"));
            flat_panel_row.switch_btn.notify["active"].connect(() => {
                settings.set_boolean("panel-flat", flat_panel_row.switch_btn.active);
            });
            adv_dock_group.add_row(flat_panel_row);

            var dock_multi_row = new SwitchRow(_("Dock on All Monitors"), _("Show dock on every connected screen"), settings.get_boolean("dock-multi-monitor"));
            dock_multi_row.switch_btn.notify["active"].connect(() => {
                settings.set_boolean("dock-multi-monitor", dock_multi_row.switch_btn.active);
            });
            adv_dock_group.add_row(dock_multi_row);

            var panel_multi_row = new SwitchRow(_("Panel on All Monitors"), _("Show top bar on every connected screen"), settings.get_boolean("panel-multi-monitor"));
            panel_multi_row.switch_btn.notify["active"].connect(() => {
                settings.set_boolean("panel-multi-monitor", panel_multi_row.switch_btn.active);
            });
            adv_dock_group.add_row(panel_multi_row);
            var gap_row = new PreferencesRow();
            var gap_box = new Box(Orientation.VERTICAL, 8);
            gap_box.margin_top = 12;
            gap_box.margin_bottom = 12;
            gap_box.margin_start = 12;
            gap_box.margin_end = 12;
            var gap_lbl = new Label(_("Dock Gap"));
            gap_lbl.add_css_class("title");
            gap_lbl.halign = Align.START;
            gap_box.append(gap_lbl);
            var gap_scale = new Scale.with_range(Orientation.HORIZONTAL, 0, 40, 1);
            gap_scale.draw_value = true;
            gap_scale.value_pos = PositionType.RIGHT;
            gap_scale.hexpand = true;
            gap_scale.set_value(settings.get_int("dock-gap"));
            gap_scale.value_changed.connect(() => {
                settings.set_int("dock-gap", (int)gap_scale.get_value());
            });
            gap_box.append(gap_scale);
            gap_row.set_child(gap_box);
            adv_dock_group.add_row(gap_row);
            var size_row = new PreferencesRow();
            var size_box = new Box(Orientation.VERTICAL, 12);
            size_box.margin_top = 12;
            size_box.margin_bottom = 12;
            size_box.margin_start = 12;
            size_box.margin_end = 12;
            var size_lbl = new Label(_("Icon Size"));
            size_lbl.add_css_class("title");
            size_lbl.halign = Align.START;
            size_box.append(size_lbl);
            var size_scale = new Scale.with_range(Orientation.HORIZONTAL, 16, 128, 4);
            size_scale.draw_value = true;
            size_scale.value_pos = PositionType.RIGHT;
            size_scale.hexpand = true;
            size_scale.set_value(settings.get_int("dock-icon-size"));
            size_scale.value_changed.connect(() => {
                settings.set_int("dock-icon-size", (int)size_scale.get_value());
            });
            size_box.append(size_scale);
            var presets_box = new Box(Orientation.HORIZONTAL, 12);
            presets_box.halign = Align.CENTER;
            var btn_small = new Button.with_label(_("Small"));
            btn_small.clicked.connect(() => { size_scale.set_value(32); });
            presets_box.append(btn_small);
            var btn_def = new Button.with_label(_("Default"));
            btn_def.clicked.connect(() => { size_scale.set_value(48); });
            presets_box.append(btn_def);
            var btn_big = new Button.with_label(_("Big"));
            btn_big.clicked.connect(() => { size_scale.set_value(64); });
            presets_box.append(btn_big);
            size_box.append(presets_box);
            size_row.set_child(size_box);
            adv_dock_group.add_row(size_row);
            add_group(adv_dock_group);
        }

        private static bool gsettings_schema_exists(string id) {
            var source = SettingsSchemaSource.get_default();
            if (source == null) return false;
            return source.lookup(id, true) != null;
        }

        private static void ensure_wallpaper_css() {
            if (wallpaper_css_loaded) return;
            var display = Gdk.Display.get_default();
            if (display == null) return;

            var provider = new CssProvider();
            provider.load_from_data(WALLPAPER_CSS.data);
            Gtk.StyleContext.add_provider_for_display(
                display,
                provider,
                Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            );
            wallpaper_css_loaded = true;
        }

        private const string WALLPAPER_CSS = """
.singularity .wallpaper-gallery {
    background: linear-gradient(135deg, alpha(@text_color, 0.055), alpha(@text_color, 0.025));
    border: 1px solid alpha(@text_color, 0.08);
    border-radius: 18px;
    padding: 10px;
    box-shadow: inset 0 1px 0 alpha(white, 0.04);
}

.singularity .wallpaper-card {
    margin: 0;
    border-radius: 18px;
}

.singularity .wallpaper-card-frame {
    border-radius: 16px;
    border: 1px solid alpha(@text_color, 0.08);
    background-color: alpha(@text_color, 0.06);
    box-shadow: 0 8px 22px alpha(@shadow_color, 0.28);
}

.singularity .wallpaper-card:hover .wallpaper-card-frame {
    border-color: alpha(@text_color, 0.20);
    box-shadow: 0 14px 32px alpha(@shadow_color, 0.42);
}

.singularity .wallpaper-card.selected .wallpaper-card-frame {
    border-color: @accent_color;
    box-shadow: 0 0 0 1px alpha(@accent_color, 0.8), 0 14px 34px alpha(@accent_color, 0.20), 0 10px 28px alpha(@shadow_color, 0.40);
}

.singularity .wallpaper-card-picture {
    background-color: alpha(@text_color, 0.06);
}

.singularity .wallpaper-card-title {
    color: white;
    padding: 7px 9px;
    border-radius: 999px;
    background-color: alpha(black, 0.46);
    box-shadow: 0 4px 16px alpha(black, 0.35);
    font-size: 12px;
    font-weight: 600;
}

.singularity .wallpaper-card-check {
    opacity: 0;
}

.singularity .wallpaper-card.selected .wallpaper-card-check {
    opacity: 1;
}
""";

        private void build_window_decorations_group() {
            if (wm_settings == null) return;

            var decor_group = new PreferencesGroup(_("Window Decorations"), _("Configure titlebar buttons (restart required for SSD mode)"));

            var preview_row = new PreferencesRow();
            var preview_box = new Box(Orientation.VERTICAL, 0);
            preview_box.margin_top = 12;
            preview_box.margin_bottom = 12;
            preview_box.margin_start = 12;
            preview_box.margin_end = 12;

            var preview_bar = new Box(Orientation.HORIZONTAL, 0);
            preview_bar.add_css_class("window-decorations-preview");
            preview_bar.hexpand = true;

            var center = new CenterBox();
            center.hexpand = true;
            preview_bar.append(center);

            decorations_start_box = new Box(Orientation.HORIZONTAL, 6);
            decorations_start_box.valign = Align.CENTER;
            center.set_start_widget(decorations_start_box);

            var title = new Label(_("Titlebar"));
            title.add_css_class("dim-label");
            title.halign = Align.CENTER;
            center.set_center_widget(title);

            decorations_end_box = new Box(Orientation.HORIZONTAL, 6);
            decorations_end_box.valign = Align.CENTER;
            center.set_end_widget(decorations_end_box);

            decorations_close_btn = new Button.from_icon_name("window-close-symbolic");
            decorations_close_btn.has_frame = false;
            decorations_close_btn.add_css_class("circular-button");
            decorations_close_btn.add_css_class("window-control-button");

            decorations_min_btn = new Button.from_icon_name("window-minimize-symbolic");
            decorations_min_btn.has_frame = false;
            decorations_min_btn.add_css_class("circular-button");
            decorations_min_btn.add_css_class("window-control-button");

            decorations_max_btn = new Button.from_icon_name("window-maximize-symbolic");
            decorations_max_btn.has_frame = false;
            decorations_max_btn.add_css_class("circular-button");
            decorations_max_btn.add_css_class("window-control-button");

            preview_box.append(preview_bar);
            preview_row.set_child(preview_box);
            decor_group.add_row(preview_row);

            decorations_side_row = new SelectionRow(_("Buttons Side"), {_("Left"), _("Right")}, _("Right"));
            decor_group.add_row(decorations_side_row);

            decorations_close_row = new SwitchRow(_("Close"), _("Show close button"), true);
            decorations_min_row = new SwitchRow(_("Minimize"), _("Show minimize button"), false);
            decorations_max_row = new SwitchRow(_("Maximize"), _("Show maximize button"), false);
            decor_group.add_row(decorations_close_row);
            decor_group.add_row(decorations_min_row);
            decor_group.add_row(decorations_max_row);

            decorations_side_row.selected.connect((item) => {
                if (decorations_updating_ui) return;
                apply_window_decorations_from_ui();
            });
            decorations_close_row.switch_btn.notify["active"].connect((obj, pspec) => {
                if (decorations_updating_ui) return;
                apply_window_decorations_from_ui();
            });
            decorations_min_row.switch_btn.notify["active"].connect((obj, pspec) => {
                if (decorations_updating_ui) return;
                apply_window_decorations_from_ui();
            });
            decorations_max_row.switch_btn.notify["active"].connect((obj, pspec) => {
                if (decorations_updating_ui) return;
                apply_window_decorations_from_ui();
            });

            wm_settings.changed["button-layout"].connect(() => {
                if (decorations_ignore_change) {
                    decorations_ignore_change = false;
                    return;
                }
                sync_window_decorations_from_settings();
            });

            add_group(decor_group);
            sync_window_decorations_from_settings();

            // Window Switcher group
            var switcher_group = new PreferencesGroup(_("Window Switcher"), null);
            string current_style = settings.get_string("switcher-style");
            var style_row = new SelectionRow("Layout", {"List (icon + title)", "Grid (icons)"}, current_style == "grid" ? "Grid (icons)" : "List (icon + title)");
            style_row.selected.connect((item) => {
                settings.set_string("switcher-style", item.has_prefix("Grid") ? "grid" : "list");
            });
            switcher_group.add_row(style_row);
            add_group(switcher_group);
        }

        private static void split_layout(string layout, out string left, out string right) {
            int idx = layout.index_of(":");
            if (idx >= 0) {
                left = layout.substring(0, idx);
                right = layout.substring(idx + 1);
            } else {
                left = layout;
                right = "";
            }
        }

        private static ArrayList<string> parse_tokens(string part) {
            var tokens = new ArrayList<string>();
            string s = part.strip();
            if (s == "") return tokens;
            foreach (string raw in s.split(",")) {
                string t = raw.strip();
                if (t != "") tokens.add(t);
            }
            return tokens;
        }

        private static void remove_token(ArrayList<string> list, string token) {
            for (int i = list.size - 1; i >= 0; i--) {
                if (list[i] == token) list.remove_at(i);
            }
        }

        private static bool has_any_controls(ArrayList<string> list) {
            return list.contains("close") || list.contains("minimize") || list.contains("maximize");
        }

        private static string join_tokens(ArrayList<string> list) {
            if (list.size == 0) return "";
            return string.joinv(",", list.to_array());
        }

        private string[] list_icon_themes() {
            var seen = new GenericArray<string>();
            var names = new GLib.GenericSet<string>(str_hash, str_equal);
            string[] dirs = {
                GLib.Path.build_filename(Environment.get_home_dir(), ".icons"),
                GLib.Path.build_filename(Environment.get_user_data_dir(), "icons")
            };
            foreach (unowned string d in Environment.get_system_data_dirs())
                dirs += GLib.Path.build_filename(d, "icons");
            foreach (string dir in dirs) {
                try {
                    var dd = Dir.open(dir);
                    string? n;
                    while ((n = dd.read_name()) != null) {
                        if (names.contains(n)) continue;
                        string index = GLib.Path.build_filename(dir, n, "index.theme");
                        if (!FileUtils.test(index, FileTest.EXISTS)) continue;
                        string content;
                        try { FileUtils.get_contents(index, out content); } catch (Error e) { continue; }
                        if (!content.contains("Directories=")) continue;
                        names.add(n);
                        seen.add(n);
                    }
                } catch (FileError e) { continue; }
            }
            string[] result = {};
            for (int i = 0; i < seen.length; i++) result += seen[i];
            return result;
        }

        private void clear_box(Box box) {
            Widget? child = box.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                box.remove(child);
                child = next;
            }
        }

        private void update_decorations_preview(bool controls_left, bool show_close, bool show_min, bool show_max) {
            if (decorations_start_box == null || decorations_end_box == null) return;
            if (decorations_close_btn == null || decorations_min_btn == null || decorations_max_btn == null) return;

            clear_box(decorations_start_box);
            clear_box(decorations_end_box);

            if (controls_left) {
                if (show_close) decorations_start_box.append(decorations_close_btn);
                if (show_min) decorations_start_box.append(decorations_min_btn);
                if (show_max) decorations_start_box.append(decorations_max_btn);
            } else {
                if (show_min) decorations_end_box.append(decorations_min_btn);
                if (show_max) decorations_end_box.append(decorations_max_btn);
                if (show_close) decorations_end_box.append(decorations_close_btn);
            }
        }

        private void sync_window_decorations_from_settings() {
            if (wm_settings == null || decorations_side_row == null || decorations_close_row == null || decorations_min_row == null || decorations_max_row == null) return;

            string layout = wm_settings.get_string("button-layout");
            string left_s, right_s;
            split_layout(layout, out left_s, out right_s);
            var left = parse_tokens(left_s);
            var right = parse_tokens(right_s);

            bool show_close = left.contains("close") || right.contains("close");
            bool show_min = left.contains("minimize") || right.contains("minimize");
            bool show_max = left.contains("maximize") || right.contains("maximize");

            bool controls_left = has_any_controls(left) && !has_any_controls(right);
            if (has_any_controls(left) && has_any_controls(right)) {
                // Mixed layout: treat as right (we'll normalize once user changes something).
                controls_left = false;
            }

            decorations_updating_ui = true;
            decorations_side_row.current_value = controls_left ? "Left" : "Right";
            decorations_close_row.switch_btn.active = show_close;
            decorations_min_row.switch_btn.active = show_min;
            decorations_max_row.switch_btn.active = show_max;
            decorations_updating_ui = false;

            update_decorations_preview(controls_left, show_close, show_min, show_max);
        }

        private string build_button_layout(string current_layout, bool controls_left, bool show_close, bool show_min, bool show_max) {
            string left_s, right_s;
            split_layout(current_layout, out left_s, out right_s);
            var left = parse_tokens(left_s);
            var right = parse_tokens(right_s);

            // Preserve unknown tokens; only rewrite classic controls.
            string[] controls = {"close", "minimize", "maximize"};
            foreach (string t in controls) {
                remove_token(left, t);
                remove_token(right, t);
            }

            if (controls_left) {
                if (show_close) left.add("close");
                if (show_min) left.add("minimize");
                if (show_max) left.add("maximize");
            } else {
                if (show_min) right.add("minimize");
                if (show_max) right.add("maximize");
                if (show_close) right.add("close");
            }

            return "%s:%s".printf(join_tokens(left), join_tokens(right));
        }

        private void apply_window_decorations_from_ui() {
            if (wm_settings == null || decorations_side_row == null || decorations_close_row == null || decorations_min_row == null || decorations_max_row == null) return;

            bool controls_left = decorations_side_row.current_value == "Left";
            bool show_close = decorations_close_row.switch_btn.active;
            bool show_min = decorations_min_row.switch_btn.active;
            bool show_max = decorations_max_row.switch_btn.active;

            string current = wm_settings.get_string("button-layout");
            string updated = build_button_layout(current, controls_left, show_close, show_min, show_max);

            decorations_ignore_change = true;
            wm_settings.set_string("button-layout", updated);

            update_decorations_preview(controls_left, show_close, show_min, show_max);
        }

        private void set_wallpaper(string uri) {
            settings.set_string("background-picture-uri", uri);
            add_to_recent(uri);
            update_preview();
        }

        private void add_to_recent(string uri) {
            string[] recent = settings.get_strv("recent-wallpapers");
            var list = new ArrayList<string>();
            list.add(uri);
            foreach (string r in recent) {
                if (r != uri) list.add(r);
            }
            while (list.size > 10) {
                list.remove_at(list.size - 1);
            }
            settings.set_strv("recent-wallpapers", list.to_array());
        }

        private void remove_from_recent(string uri) {
            string[] recent = settings.get_strv("recent-wallpapers");
            var list = new ArrayList<string>();
            foreach (string r in recent) {
                if (r != uri) list.add(r);
            }
            settings.set_strv("recent-wallpapers", list.to_array());
        }

        private void update_preview_async() {
            var manager = WallpaperManager.get_default();
            if (manager.medium_texture != null && preview_widget != null) {
                preview_widget.set_image(manager.medium_texture);
                return;
            }
            // Collect candidate paths on the main thread, then load in background.
            var candidates = new Gee.ArrayList<string>();
            string uri = settings.get_string("background-picture-uri");
            if (uri != "") {
                var f = File.new_for_uri(uri);
                var p = f.get_path();
                if (p != null && FileUtils.test(p, FileTest.EXISTS)) candidates.add(p);
            }
            foreach (string fallback in new string[]{
                "/usr/share/backgrounds/singularity/default.png",
                "/usr/local/share/backgrounds/singularity/default.png"
            }) {
                if (FileUtils.test(fallback, FileTest.EXISTS)) candidates.add(fallback);
            }
            try {
                string exe_path = FileUtils.read_link("/proc/self/exe");
                var dev = File.new_for_path(exe_path).get_parent().get_child("../default.png");
                if (dev.query_exists()) candidates.add(dev.get_path());
            } catch (Error e) {}
            try {
                var bg_dir = File.new_for_path("/usr/share/backgrounds");
                if (bg_dir.query_exists()) {
                    var en = bg_dir.enumerate_children("standard::name,standard::content-type",
                                                       FileQueryInfoFlags.NONE, null);
                    FileInfo fi;
                    while ((fi = en.next_file(null)) != null) {
                        if (fi.get_content_type().has_prefix("image/"))
                            candidates.add(bg_dir.get_child(fi.get_name()).get_path());
                    }
                }
            } catch (Error e) {}
            if (candidates.is_empty) return;
            new GLib.Thread<void>("wallpaper-preview", () => {
                Gdk.Pixbuf? pb = null;
                foreach (string path in candidates) {
                    try {
                        pb = new Gdk.Pixbuf.from_file_at_scale(path, 320, 180, true);
                        break;
                    } catch (Error e) {}
                }
                GLib.Idle.add(() => {
                    if (pb != null && preview_widget != null)
                        preview_widget.set_image(Gdk.Texture.for_pixbuf(pb));
                    return GLib.Source.REMOVE;
                });
            });
        }

        // Kept for compatibility with any direct callers; delegates to async version.
        private void update_preview() {
            update_preview_async();
        }

        private void refresh_wallpaper_accent_async() {
            int gen = ++wallpaper_accent_generation;
            string uri = settings.get_string("background-picture-uri");
            string? path = null;
            if (uri != "") {
                path = File.new_for_uri(uri).get_path();
            }
            if (path == null) {
                cached_wallpaper_accent = "#3584e4";
                return;
            }

            string accent_path = path;
            new GLib.Thread<void>("wallpaper-accent", () => {
                string hex = Singularity.Style.StyleManager.get_default().extract_primary_color(accent_path);
                GLib.Idle.add(() => {
                    if (gen == wallpaper_accent_generation) {
                        cached_wallpaper_accent = hex;
                        queue_draw();
                    }
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void populate_grid() {
            int gen = ++wallpaper_grid_generation;
            wallpaper_grid.remove_all();
            var uris = new ArrayList<string>();
            string[] recent = settings.get_strv("recent-wallpapers");
            foreach (string uri in recent) {
                if (!uris.contains(uri)) {
                    uris.add(uri);
                    add_wallpaper_card(uri, true);
                }
            }

            var seen = new HashSet<string>();
            foreach (string uri in recent) seen.add(uri);

            var path_list = new ArrayList<string>();
            foreach (unowned string d in GLib.Environment.get_system_data_dirs())
                path_list.add(GLib.Path.build_filename(d, "backgrounds", "singularity"));
            path_list.add(GLib.Path.build_filename(GLib.Environment.get_user_data_dir(), "backgrounds", "singularity"));
            foreach (unowned string d in GLib.Environment.get_system_data_dirs())
                path_list.add(GLib.Path.build_filename(d, "backgrounds"));
            path_list.add(GLib.Path.build_filename(GLib.Environment.get_user_data_dir(), "backgrounds"));

            string[] scan_paths = path_list.to_array();
            new GLib.Thread<void>("wallpaper-scan", () => {
                var candidates = new ArrayList<WallpaperCandidate>();
                var thread_seen = new HashSet<string>();
                foreach (string uri in seen) thread_seen.add(uri);

                foreach (string path in scan_paths) {
                    try {
                        var dir = File.new_for_path(path);
                        if (!dir.query_exists()) continue;
                        var enumerator = dir.enumerate_children("standard::name,standard::content-type", FileQueryInfoFlags.NONE, null);
                        FileInfo info;
                        while ((info = enumerator.next_file(null)) != null) {
                            string mime = info.get_content_type();
                            if (mime.has_prefix("image/")) {
                                string uri = dir.get_child(info.get_name()).get_uri();
                                if (!thread_seen.contains(uri)) {
                                    thread_seen.add(uri);
                                    candidates.add(new WallpaperCandidate(uri, false));
                                }
                            }
                        }
                    } catch (Error e) {
                    }
                }

                GLib.Idle.add(() => {
                    if (gen != wallpaper_grid_generation) return GLib.Source.REMOVE;
                    append_wallpaper_candidates(candidates, gen, 0);
                    return GLib.Source.REMOVE;
                });
            });
        }

        private void append_wallpaper_candidates(ArrayList<WallpaperCandidate> candidates, int gen, int start) {
            if (gen != wallpaper_grid_generation) return;
            int end = int.min(start + 8, candidates.size);
            for (int i = start; i < end; i++) {
                var candidate = candidates[i];
                add_wallpaper_card(candidate.uri, candidate.is_recent);
            }
            if (end < candidates.size) {
                GLib.Idle.add(() => {
                    append_wallpaper_candidates(candidates, gen, end);
                    return GLib.Source.REMOVE;
                });
            }
        }

        private void update_wallpaper_selection() {
            string current_uri = settings.get_string("background-picture-uri");
            Widget? child = wallpaper_grid.get_first_child();
            while (child != null) {
                var fb_child = child as FlowBoxChild;
                if (fb_child != null) {
                    var card = fb_child.get_child() as WallpaperCard;
                    if (card != null) card.set_selected(card.uri == current_uri);
                }
                child = child.get_next_sibling();
            }
        }

        private void add_wallpaper_card(string uri, bool is_recent) {
            var card = new WallpaperCard(uri, is_recent);
            card.set_selected(uri == settings.get_string("background-picture-uri"));
            card.clicked.connect(() => set_wallpaper(uri));
            if (is_recent) {
                card.delete_clicked.connect(() => remove_from_recent(uri));
            }
            wallpaper_grid.append(card);
        }

        // Color picker helpers

        private static void picker_rgb_to_hsv(double r, double g, double b,
                                               out double h, out double s, out double v) {
            double mx = double.max(r, double.max(g, b));
            double mn = double.min(r, double.min(g, b));
            double d  = mx - mn;
            v = mx;
            s = (mx == 0.0) ? 0.0 : d / mx;
            if (d == 0.0) { h = 0.0; return; }
            if (mx == r)      h = 60.0 * (((g - b) / d) % 6.0);
            else if (mx == g) h = 60.0 * (((b - r) / d) + 2.0);
            else              h = 60.0 * (((r - g) / d) + 4.0);
            if (h < 0.0) h += 360.0;
        }

        private static void picker_hsv_to_rgb(double h, double s, double v,
                                               out double r, out double g, out double b) {
            h = ((h % 360.0) + 360.0) % 360.0;
            double c  = v * s;
            double x  = c * (1.0 - Math.fabs((h / 60.0) % 2.0 - 1.0));
            double m  = v - c;
            double r1 = 0, g1 = 0, b1 = 0;
            if      (h < 60)  { r1 = c; g1 = x; b1 = 0; }
            else if (h < 120) { r1 = x; g1 = c; b1 = 0; }
            else if (h < 180) { r1 = 0; g1 = c; b1 = x; }
            else if (h < 240) { r1 = 0; g1 = x; b1 = c; }
            else if (h < 300) { r1 = x; g1 = 0; b1 = c; }
            else              { r1 = c; g1 = 0; b1 = x; }
            r = r1 + m; g = g1 + m; b = b1 + m;
        }

        private string _hsv_to_hex(double h, double s, double v) {
            double r, g, b;
            picker_hsv_to_rgb(h, s, v, out r, out g, out b);
            return "#%02x%02x%02x".printf((uint)(r * 255 + 0.5),
                                          (uint)(g * 255 + 0.5),
                                          (uint)(b * 255 + 0.5));
        }

        private void _draw_sv(Cairo.Context ctx, int w, int h) {
            // Base: fully-saturated hue
            double r, g, b;
            picker_hsv_to_rgb(picker_h, 1.0, 1.0, out r, out g, out b);
            ctx.set_source_rgb(r, g, b);
            ctx.rectangle(0, 0, w, h);
            ctx.fill();
            // Horizontal: white (left), transparent (right) - desaturation axis
            var gw = new Cairo.Pattern.linear(0, 0, w, 0);
            gw.add_color_stop_rgba(0, 1, 1, 1, 1);
            gw.add_color_stop_rgba(1, 1, 1, 1, 0);
            ctx.set_source(gw);
            ctx.rectangle(0, 0, w, h);
            ctx.fill();
            // Vertical: transparent (top), black (bottom) - value axis
            var gv = new Cairo.Pattern.linear(0, 0, 0, h);
            gv.add_color_stop_rgba(0, 0, 0, 0, 0);
            gv.add_color_stop_rgba(1, 0, 0, 0, 1);
            ctx.set_source(gv);
            ctx.rectangle(0, 0, w, h);
            ctx.fill();
            // Crosshair ring
            double cx = picker_s * w;
            double cy = (1.0 - picker_v) * h;
            ctx.set_source_rgba(1, 1, 1, 0.95);
            ctx.arc(cx, cy, 7, 0, 2 * Math.PI);
            ctx.set_line_width(2.0);
            ctx.stroke();
            ctx.set_source_rgba(0, 0, 0, 0.45);
            ctx.arc(cx, cy, 7, 0, 2 * Math.PI);
            ctx.set_line_width(1.0);
            ctx.stroke();
        }

        private void _draw_hue(Cairo.Context ctx, int w, int h) {
            var g = new Cairo.Pattern.linear(0, 0, w, 0);
            g.add_color_stop_rgb(0.0 / 6, 1, 0, 0);
            g.add_color_stop_rgb(1.0 / 6, 1, 1, 0);
            g.add_color_stop_rgb(2.0 / 6, 0, 1, 0);
            g.add_color_stop_rgb(3.0 / 6, 0, 1, 1);
            g.add_color_stop_rgb(4.0 / 6, 0, 0, 1);
            g.add_color_stop_rgb(5.0 / 6, 1, 0, 1);
            g.add_color_stop_rgb(1.0,     1, 0, 0);
            double rad = 4.0;
            ctx.new_sub_path();
            ctx.arc(w - rad, rad,     rad, -Math.PI / 2.0,  0.0);
            ctx.arc(w - rad, h - rad, rad,  0.0,             Math.PI / 2.0);
            ctx.arc(rad,     h - rad, rad,  Math.PI / 2.0,   Math.PI);
            ctx.arc(rad,     rad,     rad,  Math.PI,         3.0 * Math.PI / 2.0);
            ctx.close_path();
            ctx.set_source(g);
            ctx.fill();
            // Hue indicator
            double ix = (picker_h / 360.0) * w;
            ctx.set_source_rgba(1, 1, 1, 0.9);
            ctx.rectangle(ix - 2, 1, 4, h - 2);
            ctx.fill();
            ctx.set_source_rgba(0, 0, 0, 0.4);
            ctx.rectangle(ix - 2, 1, 4, h - 2);
            ctx.set_line_width(0.5);
            ctx.stroke();
        }

        private void _on_sv_pos(double x, double y) {
            if (picker_sv_area == null) return;
            int pw = picker_sv_area.get_width();
            int ph = picker_sv_area.get_height();
            if (pw <= 0 || ph <= 0) return;
            picker_s = (x / pw).clamp(0.0, 1.0);
            picker_v = 1.0 - (y / ph).clamp(0.0, 1.0);
            _picker_commit();
        }

        private void _on_hue_pos(double x) {
            if (picker_hue_bar == null) return;
            int pw = picker_hue_bar.get_width();
            if (pw <= 0) return;
            picker_h = ((x / pw).clamp(0.0, 1.0)) * 360.0;
            _picker_commit();
        }

        private void _on_hex_changed() {
            if (picker_hex_updating || picker_hex_entry == null) return;
            string txt = picker_hex_entry.text.strip();
            if (!txt.has_prefix("#")) txt = "#" + txt;
            if (txt.length != 7) return;
            Gdk.RGBA c = Gdk.RGBA();
            if (!c.parse(txt)) return;
            picker_rgb_to_hsv(c.red, c.green, c.blue, out picker_h, out picker_s, out picker_v);
            if (picker_sv_area  != null) picker_sv_area.queue_draw();
            if (picker_hue_bar  != null) picker_hue_bar.queue_draw();
            settings.set_string("custom-accent-color", txt);
            settings.set_string("accent-color", "custom");
        }

        private void _picker_commit() {
            string hex = _hsv_to_hex(picker_h, picker_s, picker_v);
            picker_hex_updating = true;
            if (picker_hex_entry != null) picker_hex_entry.set_text(hex);
            picker_hex_updating = false;
            if (picker_sv_area  != null) picker_sv_area.queue_draw();
            if (picker_hue_bar  != null) picker_hue_bar.queue_draw();
            settings.set_string("custom-accent-color", hex);
            settings.set_string("accent-color", "custom");
        }

        private void refresh_all_swatches(FlowBox fb) {
            Widget? ch = fb.get_first_child();
            while (ch != null) {
                var fbc = ch as FlowBoxChild;
                if (fbc != null) {
                    var b = fbc.get_child() as Button;
                    if (b != null) {
                        var cont = b.get_child();
                        if (cont is DrawingArea) cont.queue_draw();
                        else if (cont is Overlay) (cont as Overlay)?.get_child()?.queue_draw();
                    }
                }
                ch = ch.get_next_sibling();
            }
        }

        private void rebuild_custom_swatches() {
            if (accent_colors_box == null) return;
            // Drop previously-added custom swatches and the add button.
            Widget? ch = accent_colors_box.get_first_child();
            while (ch != null) {
                Widget? next = ch.get_next_sibling();
                var fbc = ch as FlowBoxChild;
                if (fbc != null) {
                    var b = fbc.get_child() as Button;
                    if (b != null && (b.has_css_class("custom-accent-swatch")
                                       || b.has_css_class("add-accent-swatch"))) {
                        accent_colors_box.remove(fbc);
                    }
                }
                ch = next;
            }
            foreach (string hex in settings.get_strv("custom-accent-colors")) {
                string swatch_hex = hex;
                var da = new DrawingArea();
                da.set_size_request(24, 24);
                da.set_draw_func((area, ctx, w, h) => {
                    Gdk.RGBA c = Gdk.RGBA();
                    if (!c.parse(swatch_hex)) return;
                    ctx.set_source_rgba(c.red, c.green, c.blue, 1.0);
                    ctx.arc(w / 2.0, h / 2.0, w / 2.0 - 2, 0, 2 * Math.PI);
                    ctx.fill();
                    if (settings.get_string("accent-color") == "custom"
                            && settings.get_string("custom-accent-color") == swatch_hex) {
                        ctx.set_source_rgba(1, 1, 1, 0.8);
                        ctx.arc(w / 2.0, h / 2.0, 4, 0, 2 * Math.PI);
                        ctx.fill();
                    }
                });
                var btn = new Button();
                btn.add_css_class("circular-button");
                btn.add_css_class("custom-accent-swatch");
                btn.tooltip_text = _("Custom Color (right-click to remove)");
                btn.set_child(da);
                btn.clicked.connect(() => {
                    settings.set_string("custom-accent-color", swatch_hex);
                    settings.set_string("accent-color", "custom");
                    if (accent_colors_box != null) refresh_all_swatches(accent_colors_box);
                });
                var rc = new GestureClick();
                rc.button = Gdk.BUTTON_SECONDARY;
                rc.pressed.connect((n, x, y) => {
                    remove_custom_color(swatch_hex);
                });
                btn.add_controller(rc);
                accent_colors_box.append(btn);
            }
            var add_da = new DrawingArea();
            add_da.set_size_request(24, 24);
            add_da.set_draw_func((area, ctx, w, h) => {
                var grad = new Cairo.Pattern.linear(0, 0, w, h);
                grad.add_color_stop_rgba(0.00, 0.96, 0.26, 0.21, 1);
                grad.add_color_stop_rgba(0.25, 0.91, 0.58, 0.04, 1);
                grad.add_color_stop_rgba(0.50, 0.20, 0.66, 0.33, 1);
                grad.add_color_stop_rgba(0.75, 0.13, 0.59, 0.95, 1);
                grad.add_color_stop_rgba(1.00, 0.61, 0.15, 0.69, 1);
                ctx.set_source(grad);
                ctx.arc(w / 2.0, h / 2.0, w / 2.0 - 2, 0, 2 * Math.PI);
                ctx.fill();
            });
            var add_btn = new Button();
            add_btn.add_css_class("circular-button");
            add_btn.add_css_class("add-accent-swatch");
            add_btn.tooltip_text = _("Add Custom Color");
            var add_overlay = new Overlay();
            add_overlay.set_child(add_da);
            var plus = new Image.from_icon_name("list-add-symbolic");
            plus.pixel_size = 12;
            plus.halign = Align.CENTER;
            plus.valign = Align.CENTER;
            add_overlay.add_overlay(plus);
            add_btn.set_child(add_overlay);
            add_btn.clicked.connect(() => {
                if (custom_picker_row != null) custom_picker_row.expanded = true;
            });
            accent_colors_box.append(add_btn);
        }

        private void add_custom_color(string hex) {
            string norm = hex.down();
            var list = settings.get_strv("custom-accent-colors");
            foreach (string h in list) {
                if (h.down() == norm) return;
            }
            list += hex;
            settings.set_strv("custom-accent-colors", list);
        }

        private void remove_custom_color(string hex) {
            string norm = hex.down();
            var list = settings.get_strv("custom-accent-colors");
            string[] kept = {};
            foreach (string h in list) {
                if (h.down() != norm) kept += h;
            }
            settings.set_strv("custom-accent-colors", kept);
            if (settings.get_string("accent-color") == "custom"
                    && settings.get_string("custom-accent-color").down() == norm) {
                settings.set_string("accent-color", "blue");
            }
        }

        // Eyedropper (screen color picker via XDG portal)

        private void _start_eyedropper() {
            if (_eyedrop_in_progress) return;
            _eyedrop_in_progress = true;
            _start_eyedropper_async.begin((obj, res) => {
                _start_eyedropper_async.end(res);
                _eyedrop_in_progress = false;
            });
        }

        private async void _start_eyedropper_async() {
            try {
                var bus = yield Bus.get(BusType.SESSION);

                // Predict the Request object path and subscribe to its Response
                // before calling, per the XDG portal Request pattern, so there
                // is no race with a fast reply.
                string unique = bus.get_unique_name();
                string sender = unique.has_prefix(":")
                    ? unique.substring(1).replace(".", "_")
                    : unique.replace(".", "_");
                string token = "singularity_eyedrop_%u".printf(_eyedrop_token++);
                string handle = "/org/freedesktop/portal/desktop/request/%s/%s".printf(sender, token);

                double r = 0, g = 0, b = 0;
                bool picked = false;
                SourceFunc resume = _start_eyedropper_async.callback;

                uint sub = bus.signal_subscribe(
                    "org.freedesktop.portal.Desktop",
                    "org.freedesktop.portal.Request",
                    "Response", handle, null, DBusSignalFlags.NONE,
                    (conn, snd, path, iface, sig, parameters) => {
                        uint32 response;
                        Variant results;
                        parameters.get("(u@a{sv})", out response, out results);
                        if (response == 0)
                            picked = results.lookup("color", "(ddd)", out r, out g, out b);
                        if (resume != null) {
                            SourceFunc cb = (owned) resume;
                            resume = null;
                            cb();
                        }
                    });

                var options = new VariantBuilder(new VariantType("a{sv}"));
                options.add("{sv}", "handle_token", new Variant.string(token));
                // PickColor goes through the standard portal frontend, which
                // routes to our impl and returns the color as (ddd) directly.
                yield bus.call(
                    "org.freedesktop.portal.Desktop",
                    "/org/freedesktop/portal/desktop",
                    "org.freedesktop.portal.Screenshot",
                    "PickColor",
                    new Variant("(sa{sv})", "", options),
                    new VariantType("(o)"), DBusCallFlags.NONE, -1, null);

                yield; // resumed by the Response signal above

                bus.signal_unsubscribe(sub);

                if (picked) {
                    picker_rgb_to_hsv(r, g, b, out picker_h, out picker_s, out picker_v);
                    picker_sv_area.queue_draw();
                    picker_hue_bar.queue_draw();
                    _picker_commit();
                }
            } catch (Error e) {
                warning("eyedropper failed: %s", e.message);
            }
        }
    }
    internal class WallpaperPreviewWidget : Box {
        public signal void select_clicked();
        private Picture preview_picture;

        public WallpaperPreviewWidget() {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("workspace-preview");
            overflow = Overflow.HIDDEN;
            var image_area = new Box(Orientation.VERTICAL, 0);
            image_area.set_size_request(320, 180);
            image_area.hexpand = true;
            preview_picture = new Picture();
            preview_picture.content_fit = ContentFit.COVER;
            preview_picture.can_shrink = true;
            image_area.append(preview_picture);
            append(image_area);
            var sep = new Separator(Orientation.HORIZONTAL);
            append(sep);
            var btn = new Button.with_label(_("Select Picture..."));
            btn.add_css_class("flat");
            btn.add_css_class("image-picker-button");
            btn.clicked.connect(() => select_clicked());
            btn.hexpand = true;
            btn.height_request = 48;
            append(btn);
        }

        public void set_image(Gdk.Paintable paintable) {
            preview_picture.set_paintable(paintable);
        }
    }
    internal class WallpaperCard : Box {
        public signal void clicked();
        public signal void delete_clicked();
        public string uri { get; private set; }
        private Picture picture;
        private string thumb_path;
        private static Mutex thumb_mutex = Mutex();
        private static Cond thumb_cond = Cond();
        private static int active_thumb_loads = 0;

        public WallpaperCard(string uri, bool is_recent) {
            this.uri = uri;
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            add_css_class("wallpaper-card");
            add_css_class("workspace-preview");
            halign = Align.CENTER;
            valign = Align.CENTER;
            hexpand = false;
            vexpand = false;
            overflow = Overflow.HIDDEN;
            var clipper = new ScrolledWindow();
            clipper.add_css_class("workspace-clipper");
            clipper.add_css_class("wallpaper-card-frame");
            clipper.set_size_request(172, 104);
            clipper.hscrollbar_policy = PolicyType.NEVER;
            clipper.vscrollbar_policy = PolicyType.NEVER;
            clipper.has_frame = false;
            var overlay = new Overlay();
            clipper.set_child(overlay);
            picture = new Picture();
            picture.add_css_class("wallpaper-card-picture");
            picture.content_fit = ContentFit.COVER;
            picture.can_shrink = true;
            overlay.set_child(picture);
            var file = File.new_for_uri(uri);
            thumb_path = file.get_path() ?? "";
            if (thumb_path != "") {
                load_thumbnail_async();
            }
            if (is_recent) {
                var del_btn = new Button.from_icon_name("user-trash-symbolic");
                del_btn.add_css_class("flat");
                del_btn.add_css_class("osd");
                del_btn.valign = Align.START;
                del_btn.halign = Align.END;
                del_btn.margin_top = 4;
                del_btn.margin_end = 4;
                del_btn.clicked.connect(() => delete_clicked());
                overlay.add_overlay(del_btn);
            }
            var title_box = new Box(Orientation.HORIZONTAL, 6);
            title_box.add_css_class("wallpaper-card-title");
            title_box.valign = Align.END;
            title_box.halign = Align.FILL;
            title_box.hexpand = true;
            title_box.margin_start = 8;
            title_box.margin_end = 8;
            title_box.margin_bottom = 8;
            var title = new Label(file.get_basename() ?? _("Wallpaper"));
            title.ellipsize = Pango.EllipsizeMode.END;
            title.xalign = 0;
            title.hexpand = true;
            title_box.append(title);
            var check = new Image.from_icon_name("object-select-symbolic");
            check.add_css_class("wallpaper-card-check");
            check.pixel_size = 14;
            title_box.append(check);
            overlay.add_overlay(title_box);
            append(clipper);
            var click_ctrl = new GestureClick();
            click_ctrl.pressed.connect(() => clicked());
            add_controller(click_ctrl);
        }

        public void set_selected(bool selected) {
            if (selected) add_css_class("selected");
            else remove_css_class("selected");
        }

        private void load_thumbnail_async() {
            new GLib.Thread<void>("wallpaper-thumb", () => {
                Gdk.Pixbuf? pb = null;
                thumb_mutex.lock();
                while (active_thumb_loads >= 3) {
                    thumb_cond.wait(thumb_mutex);
                }
                active_thumb_loads++;
                thumb_mutex.unlock();

                try {
                    pb = new Gdk.Pixbuf.from_file_at_scale(thumb_path, 344, 208, true);
                } catch (Error e) {}

                thumb_mutex.lock();
                active_thumb_loads--;
                thumb_cond.signal();
                thumb_mutex.unlock();

                GLib.Idle.add(() => {
                    if (pb != null)
                        picture.set_paintable(Gdk.Texture.for_pixbuf(pb));
                    return GLib.Source.REMOVE;
                });
            });
        }
    }
}
