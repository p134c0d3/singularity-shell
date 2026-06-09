using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AutostartPage : SettingsPage {
        private string autostart_dir;
        private PreferencesGroup entries_group;
        private SearchableExpanderRow app_row;

        public AutostartPage(SettingsView view) {
            base(_("Autostart"));
            back_clicked.connect(() => view.go_home());

            autostart_dir = Path.build_filename(Environment.get_user_config_dir(), "autostart");

            var add_grp = new PreferencesGroup(_("Autostart Apps"),
                _("Programs added here start automatically when you log in."));

            app_row = new SearchableExpanderRow(_("Add Application"),
                _("Choose an installed app to start at login"), "list-add-symbolic");
            app_row.search_entry.placeholder_text = _("Search applications");
            app_row.search_entry.search_changed.connect((entry) => {
                populate_app_list(entry.text);
            });
            app_row.notify["expanded"].connect(() => {
                if (app_row.expanded) populate_app_list(app_row.search_entry.text);
            });
            add_grp.add_row(app_row);

            var cmd_row = new EntryRow(_("Add Command"));
            var run_btn = new Button.from_icon_name("list-add-symbolic");
            run_btn.has_frame = false;
            run_btn.valign = Align.CENTER;
            run_btn.tooltip_text = _("Add");
            run_btn.clicked.connect(() => {
                string cmd = cmd_row.text.strip();
                if (cmd == "") return;
                add_command_entry(cmd);
                cmd_row.text = "";
                refresh_entries();
            });
            cmd_row.entry_activated.connect(() => run_btn.clicked());
            cmd_row.add_suffix(run_btn);
            add_grp.add_row(cmd_row);
            add_group(add_grp);

            entries_group = new PreferencesGroup(_("Startup Applications"));
            add_group(entries_group);

            refresh_entries();
        }

        private void refresh_entries() {
            entries_group.clear();
            var entries = read_entries();
            if (entries.size == 0) {
                var empty = new ActionRow(_("No startup applications"),
                    _("Add an app or command above"), null);
                empty.activatable = false;
                empty.sensitive = false;
                entries_group.add_row(empty);
                return;
            }
            foreach (var path in entries) {
                var info = new DesktopAppInfo.from_filename(path);
                string name = info != null ? info.get_display_name() : Path.get_basename(path);
                string subtitle = info != null ? (info.get_string("Comment") ?? "") : "";
                var row = new ActionRow(name, subtitle != "" ? subtitle : null, null);
                row.activatable = false;

                if (info != null && info.get_icon() != null) {
                    var img = new Image.from_gicon(info.get_icon());
                    img.pixel_size = 24;
                    img.margin_end = 12;
                    row.add_prefix(img);
                }

                var remove_btn = new Button.from_icon_name("user-trash-symbolic");
                remove_btn.has_frame = false;
                remove_btn.valign = Align.CENTER;
                remove_btn.add_css_class("destructive-action");
                remove_btn.tooltip_text = _("Remove");
                string entry_path = path;
                remove_btn.clicked.connect(() => {
                    remove_entry(entry_path);
                    refresh_entries();
                });
                row.add_suffix(remove_btn);
                entries_group.add_row(row);
            }
        }

        private Gee.List<string> read_entries() {
            var list = new Gee.ArrayList<string>();
            var dir = File.new_for_path(autostart_dir);
            if (!dir.query_exists()) return list;
            try {
                var en = dir.enumerate_children("standard::name", FileQueryInfoFlags.NONE);
                FileInfo? fi;
                while ((fi = en.next_file()) != null) {
                    string n = fi.get_name();
                    if (n.has_suffix(".desktop"))
                        list.add(Path.build_filename(autostart_dir, n));
                }
            } catch (Error e) {
                warning("Autostart: failed to read %s: %s", autostart_dir, e.message);
            }
            list.sort((a, b) => GLib.strcmp(Path.get_basename(a), Path.get_basename(b)));
            return list;
        }

        private void ensure_dir() {
            var dir = File.new_for_path(autostart_dir);
            if (!dir.query_exists()) {
                try { dir.make_directory_with_parents(); }
                catch (Error e) { warning("Autostart: cannot create %s: %s", autostart_dir, e.message); }
            }
        }

        private bool already_present(string desktop_id) {
            return File.new_for_path(Path.build_filename(autostart_dir, desktop_id)).query_exists();
        }

        private void add_app_entry(DesktopAppInfo info) {
            ensure_dir();
            string id = info.get_id() ?? (info.get_display_name() + ".desktop");
            string target = Path.build_filename(autostart_dir, id);
            var kf = new KeyFile();
            string? src = info.get_filename();
            try {
                if (src != null && kf.load_from_file(src, KeyFileFlags.KEEP_COMMENTS | KeyFileFlags.KEEP_TRANSLATIONS)) {
                    // loaded the original entry
                } else {
                    build_minimal_keyfile(kf, info.get_display_name(),
                        info.get_commandline() ?? "", info.get_icon());
                }
                kf.set_boolean("Desktop Entry", "X-GNOME-Autostart-enabled", true);
                FileUtils.set_contents(target, kf.to_data());
            } catch (Error e) {
                warning("Autostart: failed to write %s: %s", target, e.message);
            }
        }

        private void add_command_entry(string command) {
            ensure_dir();
            string sanitized = command.split(" ")[0];
            sanitized = Path.get_basename(sanitized).replace("/", "_");
            if (sanitized == "") sanitized = "command";
            string target = Path.build_filename(autostart_dir, "custom-" + sanitized + ".desktop");
            var kf = new KeyFile();
            build_minimal_keyfile(kf, sanitized, command, null);
            try {
                kf.set_boolean("Desktop Entry", "X-GNOME-Autostart-enabled", true);
                FileUtils.set_contents(target, kf.to_data());
            } catch (Error e) {
                warning("Autostart: failed to write %s: %s", target, e.message);
            }
        }

        private void build_minimal_keyfile(KeyFile kf, string name, string exec, GLib.Icon? icon) {
            kf.set_string("Desktop Entry", "Type", "Application");
            kf.set_string("Desktop Entry", "Name", name);
            kf.set_string("Desktop Entry", "Exec", exec);
            kf.set_boolean("Desktop Entry", "Terminal", false);
            if (icon != null) kf.set_string("Desktop Entry", "Icon", icon.to_string());
        }

        private void remove_entry(string path) {
            // Only ever delete files inside the user autostart directory.
            if (!path.has_prefix(autostart_dir)) return;
            try { File.new_for_path(path).delete(); }
            catch (Error e) { warning("Autostart: failed to remove %s: %s", path, e.message); }
        }

        private void populate_app_list(string query) {
            var list = app_row.list_box;
            Widget? child = list.get_first_child();
            while (child != null) {
                list.remove(child);
                child = list.get_first_child();
            }

            var apps = new Gee.ArrayList<DesktopAppInfo>();
            foreach (var ai in AppInfo.get_all()) {
                var dai = ai as DesktopAppInfo;
                if (dai == null || !dai.should_show()) continue;
                string id = dai.get_id() ?? "";
                if (id != "" && already_present(id)) continue;
                apps.add(dai);
            }
            apps.sort((a, b) => GLib.strcmp(a.get_display_name().down(), b.get_display_name().down()));

            string q = query.strip().down();
            foreach (var dai in apps) {
                if (q != "" && !dai.get_display_name().down().contains(q)) continue;
                var item = new ActionRow(dai.get_display_name());
                item.activatable = true;
                if (dai.get_icon() != null) {
                    var img = new Image.from_gicon(dai.get_icon());
                    img.pixel_size = 24;
                    img.margin_end = 12;
                    item.add_prefix(img);
                }
                var picked = dai;
                item.activated.connect(() => {
                    add_app_entry(picked);
                    app_row.expanded = false;
                    app_row.search_entry.text = "";
                    refresh_entries();
                });
                list.append(item);
            }
        }
    }
}
