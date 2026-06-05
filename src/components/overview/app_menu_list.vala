using Gtk;
using GLib;

namespace Singularity {

    public class AppMenuList : Box {
        public delegate void LaunchedCallback();
        public LaunchedCallback? on_app_launched;

        private AppSystem app_system;
        private Overlay overlay;
        private ScrolledWindow scrolled;
        private ListBox list;
        private Label sticky_letter;
        private int icon_size;
        private GenericArray<ListBoxRow> headers = new GenericArray<ListBoxRow>();

        public AppMenuList(int icon_size = 32) {
            Object(orientation: Orientation.VERTICAL, spacing: 0);
            this.icon_size = icon_size;
            app_system = AppSystem.get_default();

            overlay = new Overlay();
            overlay.hexpand = true;
            overlay.vexpand = true;

            scrolled = new ScrolledWindow();
            scrolled.hscrollbar_policy = PolicyType.NEVER;
            scrolled.hexpand = true;
            scrolled.vexpand = true;

            list = new ListBox();
            list.selection_mode = SelectionMode.NONE;
            list.add_css_class("app-menu-list");
            scrolled.set_child(list);
            overlay.set_child(scrolled);

            sticky_letter = new Label("");
            sticky_letter.add_css_class("app-menu-sticky-letter");
            sticky_letter.halign = Align.FILL;
            sticky_letter.valign = Align.START;
            sticky_letter.xalign = 0.0f;
            sticky_letter.can_target = false;
            overlay.add_overlay(sticky_letter);

            append(overlay);

            list.row_activated.connect(on_row_activated);
            scrolled.get_vadjustment().value_changed.connect(update_sticky);

            ulong sid = app_system.apps_changed.connect(() => { populate(); });
            this.destroy.connect(() => app_system.disconnect(sid));
        }

        public void set_max_height(int max_h) {
            scrolled.propagate_natural_height = true;
            scrolled.max_content_height = max_h;
        }

        public void populate() {
            Widget? c = list.get_first_child();
            while (c != null) { list.remove(c); c = list.get_first_child(); }
            headers = new GenericArray<ListBoxRow>();

            var apps = new GenericArray<AppInfo>();
            foreach (var a in app_system.get_all_apps()) {
                if (!a.should_show()) continue;
                string? n = a.get_name();
                if (n == null || n.strip() == "") continue;
                apps.add(a);
            }
            apps.sort((a, b) => a.get_name().down().collate(b.get_name().down()));

            string current = "";
            for (int i = 0; i < apps.length; i++) {
                var app = apps[i];
                string letter = section_letter(app.get_name());
                if (letter != current) {
                    current = letter;
                    var h = make_header(letter);
                    headers.add(h);
                    list.append(h);
                }
                list.append(make_row(app));
            }
            update_sticky();
        }

        private string section_letter(string name) {
            unichar ch = name.strip().get_char(0);
            if (ch.isalpha()) return ch.toupper().to_string();
            return "#";
        }

        private ListBoxRow make_header(string letter) {
            var row = new ListBoxRow();
            row.activatable = false;
            row.selectable = false;
            row.can_focus = false;
            row.add_css_class("app-menu-section");
            row.set_data<string>("letter", letter);
            var l = new Label(letter);
            l.halign = Align.START;
            l.xalign = 0.0f;
            l.add_css_class("app-menu-section-label");
            row.set_child(l);
            return row;
        }

        private ListBoxRow make_row(AppInfo app) {
            var row = new ListBoxRow();
            row.activatable = true;
            row.add_css_class("app-menu-row");
            row.set_data<AppInfo>("app", app);

            var hb = new Box(Orientation.HORIZONTAL, 12);
            var img = new Image();
            img.pixel_size = icon_size;
            resolve_icon(img, app);
            hb.append(img);

            var label = new Label(app.get_name());
            label.halign = Align.START;
            label.xalign = 0.0f;
            label.ellipsize = Pango.EllipsizeMode.END;
            label.hexpand = true;
            hb.append(label);

            row.set_child(hb);

            var rc = new GestureClick();
            rc.button = Gdk.BUTTON_SECONDARY;
            unowned ListBoxRow row_weak = row;
            unowned GestureClick rc_weak = rc;
            rc.pressed.connect((n, x, y) => {
                rc_weak.set_state(EventSequenceState.CLAIMED);
                show_context_menu(row_weak, app, x, y);
            });
            row.add_controller(rc);

            return row;
        }

        private void resolve_icon(Image img, AppInfo app) {
            var icon = app.get_icon();
            if (icon is ThemedIcon) {
                var theme = IconTheme.get_for_display(Gdk.Display.get_default());
                foreach (var name in ((ThemedIcon) icon).get_names()) {
                    if (theme.has_icon(name)) { img.icon_name = name; return; }
                }
                img.icon_name = "application-x-executable";
            } else if (icon != null) {
                img.set_from_gicon(icon);
            } else {
                img.icon_name = "application-x-executable";
            }
        }

        private void on_row_activated(ListBoxRow row) {
            var app = row.get_data<AppInfo>("app");
            if (app == null) return;
            AppSystem.launch_app(app);
            if (on_app_launched != null) on_app_launched();
        }

        private void show_context_menu(Widget parent, AppInfo app, double x, double y) {
            string? app_id = app.get_id();
            var menu = new Singularity.Widgets.ContextMenu(parent);
            Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
            menu.set_pointing_to(rect);

            menu.add_item("Open", "system-run-symbolic", () => {
                AppSystem.launch_app(app);
                if (on_app_launched != null) on_app_launched();
            });
            menu.add_item("Add to Desktop", "user-desktop-symbolic", () => {
                AppSystem.add_app_to_desktop(app);
            });
            menu.add_separator();

            if (app_id != null) {
                string captured_id = app_id.dup();
                if (app_system.is_pinned(captured_id)) {
                    menu.add_item("Unpin from Dock", "list-remove-symbolic", () => {
                        app_system.unpin_app(captured_id);
                    });
                } else {
                    menu.add_item("Pin to Dock", "starred-symbolic", () => {
                        app_system.pin_app(captured_id);
                    });
                }
            }
            menu.popup();
        }

        private void update_sticky() {
            double scroll = scrolled.get_vadjustment().value;
            string letter = "";
            for (int i = 0; i < headers.length; i++) {
                var h = headers[i];
                Graphene.Rect r;
                if (!h.compute_bounds(list, out r)) continue;
                if (r.origin.y <= scroll + 1) letter = h.get_data<string>("letter");
                else break;
            }
            sticky_letter.label = letter;
            sticky_letter.visible = letter != "";
        }
    }
}
