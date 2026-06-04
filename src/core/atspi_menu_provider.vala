using Atspi;

namespace Singularity {

    public delegate void MenuReadyCallback(GLib.Menu? menu);

    public class AtSpiMenuProvider : GLib.Object {

        public static void build_menu_async(string app_id, SimpleActionGroup group,
                                             owned MenuReadyCallback on_result) {
            string self_exe;
            try {
                self_exe = FileUtils.read_link("/proc/self/exe");
            } catch (Error e) {
                on_result(null);
                return;
            }
            string captured_id = app_id.dup();
            MenuReadyCallback cb = (owned) on_result;

            GLib.Subprocess sp;
            try {
                sp = new GLib.Subprocess(
                    GLib.SubprocessFlags.STDOUT_PIPE | GLib.SubprocessFlags.STDERR_SILENCE,
                    self_exe, "--atspi-menu", captured_id);
            } catch (Error e) {
                cb(null);
                return;
            }

            var cancel = new Cancellable();
            uint tid = Timeout.add(2500, () => {
                cancel.cancel();
                sp.force_exit();
                return Source.REMOVE;
            });

            sp.communicate_utf8_async.begin(null, cancel, (obj, res) => {
                Source.remove(tid);
                string? outbuf = null;
                try {
                    sp.communicate_utf8_async.end(res, out outbuf, null);
                } catch (Error e) {
                    cb(null);
                    return;
                }
                if (!sp.get_if_exited() || sp.get_exit_status() != 0) {
                    cb(null);
                    return;
                }
                if (outbuf == null || outbuf.length == 0) {
                    cb(null);
                    return;
                }
                cb(parse_serialized(outbuf, group, captured_id, self_exe));
            });
        }

        // ---- parent side: rebuild the GLib.Menu from the helper's output ----

        private static GLib.Menu? parse_serialized(string data, SimpleActionGroup group,
                                                    string app_id, string self_exe) {
            string[] lines = data.split("\n");
            if (lines.length < 1) return null;
            int top = int.parse(lines[0]);
            if (top <= 0) return null;
            int pos = 1;
            int counter = 0;
            var menu = parse_level(lines, ref pos, top, group, ref counter, app_id, self_exe);
            return menu.get_n_items() > 0 ? menu : null;
        }

        private static GLib.Menu parse_level(string[] lines, ref int pos, int count,
                                             SimpleActionGroup group, ref int counter,
                                             string app_id, string self_exe) {
            var menu = new GLib.Menu();
            var section = new GLib.Menu();
            for (int k = 0; k < count && pos < lines.length; k++) {
                string line = lines[pos];
                pos++;
                if (line == "s") {
                    if (section.get_n_items() > 0) {
                        menu.append_section(null, section);
                        section = new GLib.Menu();
                    }
                    continue;
                }
                string[] parts = line.split("|");
                if (parts.length >= 3 && parts[0] == "m") {
                    string label = decode_b64(parts[1]);
                    int cc = int.parse(parts[2]);
                    var sub = parse_level(lines, ref pos, cc, group, ref counter, app_id, self_exe);
                    if (sub.get_n_items() > 0) section.append_submenu(label, sub);
                } else if (parts.length >= 3 && parts[0] == "i") {
                    string label = decode_b64(parts[1]);
                    string idxpath = parts[2];
                    counter++;
                    string act_id = "atspi-%d".printf(counter);
                    string cap_path = idxpath;
                    string cap_app = app_id;
                    string cap_exe = self_exe;
                    var act = new SimpleAction(act_id, null);
                    act.activate.connect(() => {
                        try {
                            var p = new GLib.Subprocess(
                                GLib.SubprocessFlags.STDOUT_SILENCE | GLib.SubprocessFlags.STDERR_SILENCE,
                                cap_exe, "--atspi-activate", cap_app, cap_path);
                            p.wait_async.begin(null);
                        } catch (Error e) {
                            warning("AT-SPI activate spawn failed: %s", e.message);
                        }
                    });
                    group.add_action(act);
                    section.append(label, "dbusmenu." + act_id);
                }
            }
            if (section.get_n_items() > 0) menu.append_section(null, section);
            return menu;
        }

        private static string decode_b64(string s) {
            uint8[] raw = Base64.decode(s);
            uint8[] buf = new uint8[raw.length + 1];
            for (int k = 0; k < raw.length; k++) buf[k] = raw[k];
            buf[raw.length] = 0;
            return (string) buf;
        }

        // ---- subprocess side: scan the AT-SPI tree, isolated from the shell ----

        public static int run_scan(string app_id) {
            Atspi.init();
            var desktop = Atspi.get_desktop(0);
            if (desktop == null) return 0;
            var app = find_app(desktop, app_id);
            if (app == null) return 0;

            int nw = 0;
            try { nw = app.get_child_count(); } catch { return 0; }
            for (int j = 0; j < nw; j++) {
                Atspi.Accessible? win = null;
                try { win = app.get_child_at_index(j); } catch { continue; }
                if (win == null) continue;

                Atspi.Role wr = Atspi.Role.INVALID;
                try { wr = win.get_role(); } catch { continue; }
                if (wr != Atspi.Role.FRAME && wr != Atspi.Role.DIALOG && wr != Atspi.Role.WINDOW) continue;

                var path = new Gee.ArrayList<int>();
                var bar = find_menu_bar(win, 0, path);
                if (bar == null) continue;

                int[] base_path = new int[path.size + 1];
                base_path[0] = j;
                for (int k = 0; k < path.size; k++) base_path[k + 1] = path[k];

                var sb = new StringBuilder();
                int top = serialize_children(bar, base_path, sb);
                if (top > 0) {
                    print("%d\n%s", top, sb.str);
                    return 0;
                }
            }
            return 0;
        }

        public static int run_activate(string app_id, string path_csv) {
            Atspi.init();
            var desktop = Atspi.get_desktop(0);
            if (desktop == null) return 1;
            var app = find_app(desktop, app_id);
            if (app == null) return 1;

            Atspi.Accessible node = app;
            foreach (string seg in path_csv.split(",")) {
                if (seg.length == 0) continue;
                int idx = int.parse(seg);
                Atspi.Accessible? next = null;
                try { next = node.get_child_at_index(idx); } catch { return 1; }
                if (next == null) return 1;
                node = next;
            }
            try {
                var ai = node.get_action_iface();
                if (ai != null) ai.do_action(0);
            } catch (Error e) {
                return 1;
            }
            return 0;
        }

        private static Atspi.Accessible? find_app(Atspi.Accessible desktop, string app_id) {
            int n = 0;
            try { n = desktop.get_child_count(); } catch { return null; }
            for (int i = 0; i < n; i++) {
                Atspi.Accessible? app = null;
                try { app = desktop.get_child_at_index(i); } catch { continue; }
                if (app == null) continue;
                string? name = null;
                try { name = app.get_name(); } catch { continue; }
                if (name == null || name.length == 0) continue;
                if (matches_app_id(name, app_id)) return app;
            }
            return null;
        }

        private static Atspi.Accessible? find_menu_bar(Atspi.Accessible node, int depth,
                                                       Gee.ArrayList<int> path) {
            if (depth > 6) return null;
            Atspi.Role role = Atspi.Role.INVALID;
            try { role = node.get_role(); } catch { return null; }
            if (role == Atspi.Role.MENU_BAR) return node;
            int n = 0;
            try { n = node.get_child_count(); } catch { return null; }
            for (int i = 0; i < n; i++) {
                Atspi.Accessible? c = null;
                try { c = node.get_child_at_index(i); } catch { continue; }
                if (c == null) continue;
                path.add(i);
                var found = find_menu_bar(c, depth + 1, path);
                if (found != null) return found;
                path.remove_at(path.size - 1);
            }
            return null;
        }

        private static int serialize_children(Atspi.Accessible node, int[] idxpath, StringBuilder sb) {
            int count = 0;
            int n = 0;
            try { n = node.get_child_count(); } catch { return 0; }
            for (int i = 0; i < n; i++) {
                Atspi.Accessible? c = null;
                try { c = node.get_child_at_index(i); } catch { continue; }
                if (c == null) continue;
                Atspi.Role role = Atspi.Role.INVALID;
                try { role = c.get_role(); } catch { continue; }

                int[] cp = new int[idxpath.length + 1];
                for (int k = 0; k < idxpath.length; k++) cp[k] = idxpath[k];
                cp[idxpath.length] = i;

                if (role == Atspi.Role.SEPARATOR) {
                    sb.append("s\n");
                    count++;
                } else if (role == Atspi.Role.MENU) {
                    string label = "";
                    try { label = c.get_name() ?? ""; } catch { label = ""; }
                    if (label.length == 0) continue;
                    var csb = new StringBuilder();
                    int cc = serialize_children(c, cp, csb);
                    if (cc > 0) {
                        sb.append("m|%s|%d\n".printf(Base64.encode(label.data), cc));
                        sb.append(csb.str);
                        count++;
                    }
                } else if (role == Atspi.Role.MENU_ITEM || role == Atspi.Role.CHECK_MENU_ITEM ||
                           role == Atspi.Role.RADIO_MENU_ITEM || role == Atspi.Role.TEAROFF_MENU_ITEM) {
                    string label = "";
                    try { label = c.get_name() ?? ""; } catch { label = ""; }
                    if (label.length == 0) continue;
                    sb.append("i|%s|%s\n".printf(Base64.encode(label.data), join_ints(cp)));
                    count++;
                }
            }
            return count;
        }

        private static string join_ints(int[] a) {
            var sb = new StringBuilder();
            for (int k = 0; k < a.length; k++) {
                if (k > 0) sb.append(",");
                sb.append(a[k].to_string());
            }
            return sb.str;
        }

        private static bool matches_app_id(string app_name, string app_id) {
            string ln = app_name.down().strip();
            string lid = app_id.down();
            if (ln == lid) return true;
            string[] parts = lid.split(".");
            if (parts.length > 0) {
                string last = parts[parts.length - 1];
                if (ln == last) return true;
                if (ln.has_prefix(last) || last.has_prefix(ln)) return true;
            }
            if (lid.contains(ln) && ln.length >= 3) return true;
            string ln_nospace = ln.replace(" ", "");
            string lid_nospace = lid.replace(".", "");
            if (lid_nospace.contains(ln_nospace) && ln_nospace.length >= 4) return true;
            if (ln_nospace.length >= 4 && lid.contains(ln_nospace)) return true;
            return false;
        }
    }
}
