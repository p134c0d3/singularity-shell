using Gtk;
using GtkLayerShell;

namespace Singularity {

    public class Background : Gtk.Window {
        private Picture picture_a;
        private Picture picture_b;
        private Stack wp_stack;
        private bool _wp_showing_a = true;
        private uint _wp_clear_id = 0;

        public signal void first_painted();
        private bool _first_painted_done = false;

        public Background(Gtk.Application app, Gdk.Monitor? monitor = null) {
            Object(application: app);
            init_for_window(this);
            if (monitor != null) {
                GtkLayerShell.set_monitor(this, monitor);
            }
            set_layer(this, GtkLayerShell.Layer.BACKGROUND);
            set_anchor(this, GtkLayerShell.Edge.TOP, true);
            set_anchor(this, GtkLayerShell.Edge.BOTTOM, true);
            set_anchor(this, GtkLayerShell.Edge.LEFT, true);
            set_anchor(this, GtkLayerShell.Edge.RIGHT, true);
            set_exclusive_zone(this, -1);
            add_css_class("singularity");
            add_css_class("singularity-shell");
            add_css_class("background-window");

            picture_a = new Picture();
            picture_a.content_fit = ContentFit.COVER;
            picture_b = new Picture();
            picture_b.content_fit = ContentFit.COVER;

            wp_stack = new Stack();
            wp_stack.transition_type = StackTransitionType.CROSSFADE;
            wp_stack.transition_duration = 600;
            wp_stack.add_named(picture_a, "a");
            wp_stack.add_named(picture_b, "b");
            set_child(wp_stack);

            var manager = WallpaperManager.get_default();
            // First load: set both pictures to avoid flash, no animation needed
            if (manager.display_texture != null) {
                picture_a.set_paintable(manager.display_texture);
                picture_b.set_paintable(manager.display_texture);
                schedule_hidden_wallpaper_clear();
            }
            manager.wallpaper_changed.connect(() => {
                update_wallpaper(manager);
            });
            map.connect_after(() => {
                if (_first_painted_done) return;
                var clock = get_frame_clock();
                if (clock == null) {
                    GLib.Timeout.add(50, () => { emit_first_painted(); return GLib.Source.REMOVE; });
                    return;
                }
                ulong handler = 0;
                handler = clock.after_paint.connect(() => {
                    clock.disconnect(handler);
                    emit_first_painted();
                });
                queue_draw();
            });

            present();
            var click_controller = new GestureClick();
            click_controller.button = 3;
            click_controller.pressed.connect((n_press, x, y) => {
                show_context_menu(x, y);
            });
            ((Gtk.Widget)this).add_controller(click_controller);

            // Left-click on desktop, switch global menu to OS menu
            var left_click = new GestureClick();
            left_click.button = 1;
            left_click.pressed.connect((n_press, x, y) => {
                AppSystem.get_default().notify_desktop_focused();
            });
            ((Gtk.Widget)this).add_controller(left_click);
        }

        private void emit_first_painted() {
            if (_first_painted_done) return;
            _first_painted_done = true;
            first_painted();
        }

        public void play_intro() {
            wp_stack.add_css_class("wallpaper-intro");
            GLib.Timeout.add(950, () => {
                wp_stack.remove_css_class("wallpaper-intro");
                return GLib.Source.REMOVE;
            });
        }

        private void update_wallpaper(WallpaperManager manager) {
            if (manager.display_texture == null) return;
            // Write to the off-screen picture, then crossfade to it
            if (_wp_showing_a) {
                picture_b.set_paintable(manager.display_texture);
                wp_stack.visible_child_name = "b";
            } else {
                picture_a.set_paintable(manager.display_texture);
                wp_stack.visible_child_name = "a";
            }
            _wp_showing_a = !_wp_showing_a;
            schedule_hidden_wallpaper_clear();
        }

        private void schedule_hidden_wallpaper_clear() {
            if (_wp_clear_id != 0) {
                GLib.Source.remove(_wp_clear_id);
                _wp_clear_id = 0;
            }
            bool showing_a = _wp_showing_a;
            _wp_clear_id = GLib.Timeout.add(650, () => {
                _wp_clear_id = 0;
                if (showing_a == _wp_showing_a) {
                    if (_wp_showing_a) picture_b.set_paintable(null);
                    else picture_a.set_paintable(null);
                }
                return GLib.Source.REMOVE;
            });
        }

        private void show_context_menu(double x, double y) {
            var menu = new Singularity.Widgets.ContextMenu(this);
            Gdk.Rectangle rect = { (int)x, (int)y, 1, 1 };
            menu.set_pointing_to(rect);
            menu.add_item("Set Background", "preferences-desktop-wallpaper-symbolic", () => {
                var app = (SingularityApp)application;
                app.open_settings_page("background");
            });
            menu.add_item("Settings", "emblem-system-symbolic", () => {
                var app = (SingularityApp)application;
                app.open_settings_page("home");
            });
            menu.popup();
        }
    }
}
