using Singularity;
using GLib;

namespace Singularity {

    public class TilingManager : Object {
        private AppSystem app_system;
        private GLib.Settings settings;
        private bool enabled = true;

        public TilingManager(AppSystem app_system) {
            this.app_system = app_system;
            settings = new GLib.Settings("dev.sinty.desktop");
            enabled = settings.get_boolean("tiling-enabled");
            settings.changed["tiling-enabled"].connect(() => {
                enabled = settings.get_boolean("tiling-enabled");
                if (enabled) schedule_apply_layout();
            });
            app_system.app_opened.connect(on_app_opened);
            app_system.app_closed.connect(on_app_closed);
            app_system.workspaces_changed.connect(on_workspaces_changed);
            app_system.app_focused.connect(on_app_focused);
        }
        private uint _apply_timeout_id = 0;

        private void schedule_apply_layout() {
            if (_apply_timeout_id != 0) GLib.Source.remove(_apply_timeout_id);
            _apply_timeout_id = GLib.Timeout.add(100, () => {
                _apply_timeout_id = 0;
                apply_layout();
                return Source.REMOVE;
            }, GLib.Priority.DEFAULT_IDLE);
        }

        private void on_app_opened(void* handle, string app_id) {
            if (!enabled) return;
            schedule_apply_layout();
        }

        private void on_app_closed(void* handle) {
            if (!enabled) return;
            schedule_apply_layout();
        }

        private void on_workspaces_changed() {
            if (!enabled) return;
            schedule_apply_layout();
        }

        private void on_app_focused(string? app_id) {
            if (!enabled) return;
            schedule_apply_layout();
        }

        private void snap(AppSystem.Window win, uint s) {
            Singularity.wayland_snap_view(win.handle, s);
            win.snap_type = s;
        }

        public void apply_layout() {
            var windows = app_system.get_active_workspace_windows();
            var tileable = new List<AppSystem.Window>();
            foreach (var w in windows) {
                if (w.app_id == null || w.app_id == "unknown-wayland-surface")
                    continue;
                if (w.app_id.has_prefix("chrome-") || w.app_id.contains(".flextop.chrome-"))
                    continue;
                tileable.append(w);
            }
            int count = (int)tileable.length();
            if (count == 0) return;
            int i = 0;
            foreach (var win in tileable) {
                snap(win, TilingLayout.snap_for(count, i));
                i++;
            }
        }
    }
}
