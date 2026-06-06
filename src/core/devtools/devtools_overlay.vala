using Gtk;

namespace Singularity {

    public class DevtoolsOverlay : Gtk.Window {

        private static bool _log_tap_installed = false;

        private unowned Gtk.Application _app;
        private Fixed _canvas;
        private Box _sidebar;
        private GLib.HashTable<string, DevPanel> _panels;
        private GLib.HashTable<string, Button> _buttons;
        private bool _recompute_pending = false;
        private int _spawn_seq = 0;

        private ListBox? _events_list = null;
        private string _events_filter = "";
        private ulong _events_sig = 0;
        private int _events_count = 0;

        public DevtoolsOverlay (Gtk.Application app) {
            Object (application: app);
            _app = app;
            _panels = new GLib.HashTable<string, DevPanel> (str_hash, str_equal);
            _buttons = new GLib.HashTable<string, Button> (str_hash, str_equal);

            GtkLayerShell.init_for_window (this);
            GtkLayerShell.set_layer (this, GtkLayerShell.Layer.OVERLAY);
            GtkLayerShell.set_namespace (this, "singularity-devtools");
            GtkLayerShell.set_anchor (this, GtkLayerShell.Edge.TOP,    true);
            GtkLayerShell.set_anchor (this, GtkLayerShell.Edge.BOTTOM, true);
            GtkLayerShell.set_anchor (this, GtkLayerShell.Edge.LEFT,   true);
            GtkLayerShell.set_anchor (this, GtkLayerShell.Edge.RIGHT,  true);
            GtkLayerShell.set_keyboard_mode (this, GtkLayerShell.KeyboardMode.ON_DEMAND);

            add_css_class ("devtools-overlay");

            _canvas = new Fixed ();
            _canvas.hexpand = true;
            _canvas.vexpand = true;
            set_child (_canvas);

            build_sidebar ();

            install_log_tap ();

            map.connect_after (() => schedule_input_recompute ());
        }

        private void build_sidebar () {
            _sidebar = new Box (Orientation.VERTICAL, 4);
            _sidebar.add_css_class ("devtools-sidebar");
            _sidebar.width_request = 168;
            _sidebar.vexpand = true;

            var title = new Label ("SINGULARITY DEV");
            title.add_css_class ("devtools-sidebar-title");
            title.halign = Align.START;
            _sidebar.append (title);

            add_section ("INSPECT");
            add_button ("dockvars", "Dock State");
            add_button ("tree",   "Widget Tree");
            add_button ("events", "Events");

            _canvas.put (_sidebar, 0, 0);
        }

        private void add_section (string text) {
            var lbl = new Label (text);
            lbl.add_css_class ("devtools-sidebar-section");
            lbl.halign = Align.START;
            lbl.margin_top = 8;
            _sidebar.append (lbl);
        }

        private void add_button (string id, string label) {
            var btn = new Button.with_label (label);
            btn.add_css_class ("devtools-sidebar-btn");
            btn.has_frame = false;
            btn.halign = Align.FILL;
            var btn_lbl = btn.get_child () as Label;
            if (btn_lbl != null) { btn_lbl.halign = Align.START; btn_lbl.xalign = 0; }
            btn.clicked.connect (() => toggle_panel (id, label));
            _sidebar.append (btn);
            _buttons.set (id, btn);
        }

        private void toggle_panel (string id, string label) {
            var existing = _panels.get (id);
            if (existing != null) {
                close_panel (id);
                return;
            }
            var panel = new DevPanel (id, label, _canvas);
            panel.width_request = (id == "tree" || id == "events") ? 340 : 300;
            populate_panel (id, panel);
            int x = 176 + (_spawn_seq % 4) * 28;
            int y = 16 + (_spawn_seq % 4) * 28;
            _spawn_seq++;
            panel.place_at (x, y);
            panel.closed.connect (() => close_panel (id));
            panel.moved.connect (() => schedule_input_recompute ());
            _panels.set (id, panel);
            var btn = _buttons.get (id);
            if (btn != null) btn.add_css_class ("devtools-active");
            schedule_input_recompute ();
        }

        private void close_panel (string id) {
            var panel = _panels.get (id);
            if (panel == null) return;
            if (id == "events") {
                if (_events_sig != 0) {
                    DebugManager.get_default ().disconnect (_events_sig);
                    _events_sig = 0;
                }
                _events_list = null;
            }
            _canvas.remove (panel);
            _panels.remove (id);
            var btn = _buttons.get (id);
            if (btn != null) btn.remove_css_class ("devtools-active");
            schedule_input_recompute ();
        }

        private void populate_panel (string id, DevPanel panel) {
            switch (id) {
                case "tree":
                    var refresh = new Button.with_label ("refresh tree");
                    refresh.add_css_class ("devtools-sidebar-btn");
                    refresh.has_frame = false;
                    refresh.halign = Align.START;
                    var tree_holder = new Box (Orientation.VERTICAL, 2);
                    refresh.clicked.connect (() => {
                        clear_box (tree_holder);
                        DevtoolsInspector.build_widget_tree (tree_holder, _app);
                    });
                    panel.content.append (refresh);
                    panel.content.append (tree_holder);
                    DevtoolsInspector.build_widget_tree (tree_holder, _app);
                    break;
                case "dockvars":
                    build_dock_vars (panel);
                    break;
                case "events":
                    build_events (panel);
                    break;
            }
        }

        private void build_dock_vars (DevPanel panel) {
            var holder = new Box (Orientation.VERTICAL, 4);
            var rebuild = new Button.with_label ("refresh values");
            rebuild.add_css_class ("devtools-sidebar-btn");
            rebuild.has_frame = false;
            rebuild.halign = Align.START;
            rebuild.clicked.connect (() => { clear_box (holder); fill_dock_vars (holder); });
            panel.content.append (rebuild);
            panel.content.append (holder);
            fill_dock_vars (holder);
        }

        private void fill_dock_vars (Box dest) {
            var dock = DebugManager.get_default ().dock_inspect;
            if (dock == null) {
                var note = new Label ("no dock registered");
                note.add_css_class ("devtools-note");
                note.halign = Align.START;
                dest.append (note);
                return;
            }

            foreach (string entry in dock.debug_list_vars ()) {
                int colon = entry.index_of (":");
                int eq = entry.index_of ("=");
                if (colon < 0 || eq < 0) continue;
                string kind = entry.substring (0, colon);
                string name = entry.substring (colon + 1, eq - colon - 1);
                string val = entry.substring (eq + 1);

                var row = new Box (Orientation.HORIZONTAL, 8);
                row.add_css_class ("devtools-row");
                var lbl = new Label (name);
                lbl.add_css_class ("devtools-row-key");
                lbl.halign = Align.START;
                lbl.xalign = 0;
                lbl.hexpand = true;
                row.append (lbl);

                if (kind == "bool") {
                    var sw = new Switch ();
                    sw.valign = Align.CENTER;
                    sw.active = (val == "true");
                    sw.notify["active"].connect (() => {
                        dock.debug_set_var (name, sw.active ? "true" : "false");
                    });
                    row.append (sw);
                } else {
                    var entry_w = new Entry ();
                    entry_w.width_request = 90;
                    entry_w.text = val;
                    entry_w.activate.connect (() => dock.debug_set_var (name, entry_w.text));
                    row.append (entry_w);
                }
                dest.append (row);
            }

            var actions = new Box (Orientation.HORIZONTAL, 6);
            actions.margin_top = 6;
            foreach (string act in dock.debug_actions ()) {
                var btn = new Button.with_label (act);
                btn.add_css_class ("devtools-sidebar-btn");
                btn.has_frame = false;
                btn.clicked.connect (() => dock.debug_run_action (act));
                actions.append (btn);
            }
            dest.append (actions);
        }

        private void build_events (DevPanel panel) {
            var filter = new Entry ();
            filter.placeholder_text = "filter (e.g. DOCKDBG)";
            filter.changed.connect (() => {
                _events_filter = filter.text;
                rebuild_events_visibility ();
            });
            panel.content.append (filter);

            _events_list = new ListBox ();
            _events_list.add_css_class ("devtools-events");
            _events_list.selection_mode = SelectionMode.NONE;
            panel.content.append (_events_list);
            _events_count = 0;

            if (_events_sig != 0)
                DebugManager.get_default ().disconnect (_events_sig);
            _events_sig = DebugManager.get_default ().event_logged.connect ((comp, level, msg) => {
                append_event (comp, msg);
            });
        }

        private void append_event (string comp, string msg) {
            if (_events_list == null) return;
            var row = new Label ("%s".printf (msg));
            row.add_css_class ("devtools-event-row");
            row.halign = Align.START;
            row.xalign = 0;
            row.wrap = false;
            row.ellipsize = Pango.EllipsizeMode.END;
            row.set_data<string> ("evt", msg);
            row.visible = event_matches (msg);
            _events_list.append (row);
            _events_count++;
            if (_events_count > 300) {
                var first = _events_list.get_row_at_index (0);
                if (first != null) { _events_list.remove (first); _events_count--; }
            }
        }

        private bool event_matches (string msg) {
            if (_events_filter.length == 0) return true;
            return msg.down ().contains (_events_filter.down ());
        }

        private void rebuild_events_visibility () {
            if (_events_list == null) return;
            var child = _events_list.get_first_child ();
            while (child != null) {
                var lbrow = child as ListBoxRow;
                if (lbrow != null) {
                    var lbl = lbrow.get_child () as Label;
                    if (lbl != null) {
                        string? m = lbl.get_data<string> ("evt");
                        lbrow.visible = (m != null) ? event_matches (m) : true;
                    }
                }
                child = child.get_next_sibling ();
            }
        }

        private void clear_box (Box b) {
            Widget? c = b.get_first_child ();
            while (c != null) {
                Widget? n = c.get_next_sibling ();
                b.remove (c);
                c = n;
            }
        }

        private void schedule_input_recompute () {
            if (_recompute_pending) return;
            _recompute_pending = true;
            Idle.add (() => {
                _recompute_pending = false;
                recompute_input_region ();
                return Source.REMOVE;
            });
        }

        private void recompute_input_region () {
            var surf = get_surface ();
            if (surf == null) return;
            var region = new Cairo.Region ();
            bool any = add_widget_rect (region, _sidebar);
            _panels.foreach ((id, panel) => {
                if (add_widget_rect (region, panel)) any = true;
            });
            if (!any) {
                Timeout.add (50, () => { recompute_input_region (); return Source.REMOVE; });
                return;
            }
            surf.set_input_region (region);
        }

        private bool add_widget_rect (Cairo.Region region, Widget w) {
            Graphene.Rect bounds;
            if (!w.compute_bounds (this, out bounds)) return false;
            if (bounds.size.width < 1 || bounds.size.height < 1) return false;
            var r = Cairo.RectangleInt () {
                x = (int) Math.floor (bounds.origin.x),
                y = (int) Math.floor (bounds.origin.y),
                width = (int) Math.ceil (bounds.size.width),
                height = (int) Math.ceil (bounds.size.height)
            };
            region.union_rectangle (r);
            return true;
        }

        private void install_log_tap () {
            if (_log_tap_installed) return;
            _log_tap_installed = true;
            GLib.Log.set_writer_func ((level, fields) => {
                string? message = null;
                string? domain = null;
                foreach (unowned GLib.LogField f in fields) {
                    if (f.key == "MESSAGE" && f.length != 0)
                        message = (string) f.value;
                    else if (f.key == "GLIB_DOMAIN" && f.length != 0)
                        domain = (string) f.value;
                }
                if (message != null) {
                    DebugManager.get_default ().emit_event (
                        domain ?? "shell", level_name (level), message);
                }
                return GLib.Log.writer_default (level, fields);
            });
        }

        private string level_name (GLib.LogLevelFlags level) {
            if ((level & GLib.LogLevelFlags.LEVEL_ERROR) != 0)    return "error";
            if ((level & GLib.LogLevelFlags.LEVEL_CRITICAL) != 0) return "critical";
            if ((level & GLib.LogLevelFlags.LEVEL_WARNING) != 0)  return "warning";
            if ((level & GLib.LogLevelFlags.LEVEL_INFO) != 0)     return "info";
            if ((level & GLib.LogLevelFlags.LEVEL_DEBUG) != 0)    return "debug";
            return "message";
        }
    }
}
