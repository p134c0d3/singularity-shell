using Gtk;
using GLib;
using Singularity.Widgets;

namespace Singularity {

    public class KeyboardPage : SettingsPage {
        private PreferencesGroup shortcuts_group;
        private PreferencesGroup input_group;
        private ShortcutManager manager;

        public KeyboardPage(SettingsView view) {
            base(_("Keyboard"));
            back_clicked.connect(() => {
                view.go_home();
            });
            var sys = SystemMonitor.get_default();
            manager = sys.shortcuts;
            shortcuts_group = new PreferencesGroup(_("Shortcuts"));
            add_group(shortcuts_group);
            refresh_shortcuts();
            manager.shortcut_changed.connect((action, accel) => {
                refresh_shortcuts();
            });
            input_group = new PreferencesGroup(_("Input Sources"));
            add_group(input_group);
            refresh_input_sources(view);

            var ds = new GLib.Settings("dev.sinty.desktop");
            var pointer_group = new PreferencesGroup(_("Mouse & Touchpad"));
            var accel_row = new SwitchRow(_("Mouse Acceleration"),
                _("Turn off for a flat 1:1 pointer profile"),
                ds.get_boolean("mouse-acceleration"));
            ds.bind("mouse-acceleration", accel_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            pointer_group.add_row(accel_row);
            var natural_row = new SwitchRow(_("Natural Scrolling"),
                _("Reverse the touchpad scroll direction"),
                ds.get_boolean("natural-scrolling"));
            ds.bind("natural-scrolling", natural_row.switch_btn, "active", SettingsBindFlags.DEFAULT);
            pointer_group.add_row(natural_row);
            add_group(pointer_group);
        }

        private void refresh_input_sources(SettingsView view) {
            input_group.clear();
            var source = SettingsSchemaSource.get_default();
            if (source.lookup("org.gnome.desktop.input-sources", true) != null) {
                var settings = new GLib.Settings("org.gnome.desktop.input-sources");
                var sources = settings.get_value("sources");
                if (sources.is_of_type(new VariantType("a(ss)"))) {
                    int source_count = 0;
                    var iter_count = sources.iterator();
                    string t_c, i_c;
                    while (iter_count.next("(ss)", out t_c, out i_c)) {
                        source_count++;
                    }
                    var iter = sources.iterator();
                    string type;
                    string id;
                    while (iter.next("(ss)", out type, out id)) {
                        string label_text = id;
                        if (type == "xkb") label_text = id.up();
                        var row = new ActionRow(label_text, null, "input-keyboard-symbolic");
                        string t = type;
                        string i = id;
                        if (source_count <= 1) {
                            var del_btn = new Button.from_icon_name("user-trash-symbolic");
                            del_btn.add_css_class("flat");
                            del_btn.add_css_class("destructive-action");
                            del_btn.sensitive = false;
                            del_btn.tooltip_text = _("Cannot remove the last input source");
                            row.add_suffix(del_btn);
                        } else {
                            var del_btn = new Button.from_icon_name("user-trash-symbolic");
                            del_btn.add_css_class("flat");
                            del_btn.add_css_class("destructive-action");
                            del_btn.tooltip_text = _("Remove Input Source");
                            del_btn.clicked.connect(() => {
                                remove_input_source(t, i);
                                refresh_input_sources(view);
                            });
                            row.add_suffix(del_btn);
                        }
                        input_group.add_row(row);
                    }
                }
            }
            var add_row = new ActionRow(_("Add Input Source"), null, "list-add-symbolic");
            add_row.activated.connect(() => {
                var page = new Singularity.SidebarPages.AddInputSourcePage(view);
                page.source_selected.connect((id, name) => {
                    add_input_source("xkb", id);
                    refresh_input_sources(view);
                    view.navigate_to("keyboard");
                });
                view.open_subpage(page, "add-input-source");
            });
            input_group.add_row(add_row);
        }

        private void add_input_source(string type, string id) {
            try {
                var settings = new GLib.Settings("org.gnome.desktop.input-sources");
                var current = settings.get_value("sources");
                var builder = new VariantBuilder(new VariantType("a(ss)"));

                // The first xkb source is what startup code and labwc config use.
                builder.add("(ss)", type, id);
                var iter = current.iterator();
                string t, i;
                while (iter.next("(ss)", out t, out i)) {
                    if (t == type && i == id) continue;
                    builder.add("(ss)", t, i);
                }
                var sources = builder.end();
                settings.set_value("sources", sources);
                sync_to_singularity_schema(sources);
            } catch (Error e) {
                warning("Failed to add input source: %s", e.message);
            }
        }

        private void remove_input_source(string type, string id) {
            try {
                var settings = new GLib.Settings("org.gnome.desktop.input-sources");
                var current = settings.get_value("sources");
                var builder = new VariantBuilder(new VariantType("a(ss)"));
                var iter = current.iterator();
                string t, i;
                while (iter.next("(ss)", out t, out i)) {
                    if (t == type && i == id) continue;
                    builder.add("(ss)", t, i);
                }
                var sources = builder.end();
                settings.set_value("sources", sources);
                sync_to_singularity_schema(sources);
            } catch (Error e) {
                warning("Failed to remove input source: %s", e.message);
            }
        }

        private void sync_to_singularity_schema(Variant sources) {
            try {
                var desktop_settings = new GLib.Settings("dev.sinty.desktop");
                var iter = sources.iterator();
                string t, i;
                while (iter.next("(ss)", out t, out i)) {
                    if (t == "xkb") {
                        string layout = i;
                        string variant = "";
                        if (i.contains("+")) {
                            layout = i.substring(0, i.index_of("+"));
                            variant = i.substring(i.index_of("+") + 1);
                        }
                        desktop_settings.set_string("xkb-layout", layout);
                        desktop_settings.set_string("xkb-variant", variant);
                        return;
                    }
                }
            } catch (Error e) {
                warning("Failed to sync keyboard layout to singularity schema: %s", e.message);
            }
        }

        private void refresh_shortcuts() {
            shortcuts_group.clear();
            if (manager.shortcuts == null) {
                return;
            }
            foreach (var shortcut in manager.shortcuts) {
                var row = new ShortcutRow(manager, shortcut);
                shortcuts_group.add_row(row);
            }
        }
    }
    public class ShortcutRow : ActionRow {
        private ShortcutManager manager;
        private Shortcut shortcut;
        private Button acc_btn;

        public ShortcutRow(ShortcutManager manager, Shortcut shortcut) {
            base(shortcut.description ?? "Unknown Action", null);
            this.manager = manager;
            this.shortcut = shortcut;

            if (shortcut.accelerator != shortcut.default_accelerator) {
                var reset_btn = new Button.from_icon_name("edit-undo-symbolic");
                reset_btn.add_css_class("flat");
                reset_btn.tooltip_text = _("Reset to Default");
                reset_btn.clicked.connect(() => {
                    manager.reset_shortcut(shortcut.action_name);
                });
                add_suffix(reset_btn);
            }

            string accel_label = shortcut.accelerator;
            if (accel_label == null) accel_label = "Disabled";
            acc_btn = new Button.with_label(accel_label);
            acc_btn.add_css_class("accelerator-label");
            acc_btn.tooltip_text = _("Click to rebind");
            acc_btn.clicked.connect(show_edit_dialog);
            add_suffix(acc_btn);

            var run_btn = new Button.from_icon_name("media-playback-start-symbolic");
            run_btn.add_css_class("circular-button");
            run_btn.tooltip_text = _("Execute Action");
            run_btn.clicked.connect(() => {
                manager.execute_action(shortcut.action_name);
            });
            add_suffix(run_btn);
        }

        private void show_edit_dialog() {
            var app = (Gtk.Application) GLib.Application.get_default();
            var dialog = new Singularity.Shell.ShellDialog(app);
            var box = new Box(Orientation.VERTICAL, 24);
            box.margin_top = 32;
            box.margin_bottom = 32;
            box.margin_start = 32;
            box.margin_end = 32;
            box.halign = Align.CENTER;
            box.valign = Align.CENTER;
            var lbl = new Label(_("Press any key..."));
            lbl.add_css_class("title-1");
            box.append(lbl);
            var sub = new Label(_("Press Esc to cancel"));
            sub.add_css_class("dim-label");
            box.append(sub);
            dialog.content_box.append(box);
            var controller = new EventControllerKey();
            controller.key_pressed.connect((keyval, keycode, state) => {
                if (keyval == Gdk.Key.Escape) {
                    dialog.close_dialog();
                    return true;
                }
                // Wait for a real key, ignore lone modifier presses.
                switch (keyval) {
                    case Gdk.Key.Control_L: case Gdk.Key.Control_R:
                    case Gdk.Key.Shift_L:   case Gdk.Key.Shift_R:
                    case Gdk.Key.Alt_L:     case Gdk.Key.Alt_R:
                    case Gdk.Key.Super_L:   case Gdk.Key.Super_R:
                    case Gdk.Key.Meta_L:    case Gdk.Key.Meta_R:
                        return true;
                }
                var modifiers = state & Gtk.accelerator_get_default_mod_mask();
                string accel = Gtk.accelerator_name(keyval, modifiers);
                if (accel != "") {
                    manager.update_shortcut(shortcut.action_name, accel);
                    dialog.close_dialog();
                }
                return true;
            });
            ((Widget)dialog).add_controller(controller);
            dialog.present();
            dialog.grab_focus();
        }
    }
}
