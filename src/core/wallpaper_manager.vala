using Gtk;
using Gdk;
using GLib;

namespace Singularity {

    public class WallpaperManager : Object {
        private static WallpaperManager? _instance = null;
        private GLib.Settings settings;
        public string? wallpaper_path { get; private set; }
        public Texture? display_texture { get; private set; }
        private Pixbuf? _display_pixbuf;
        public Texture? preview_texture { get; private set; }
        public Texture? medium_texture { get; private set; }
        private string? _cached_path = null;
        private int _load_serial = 0;
        private Mutex _mutex = Mutex ();

        public signal void wallpaper_changed();

        public static WallpaperManager get_default() {
            if (_instance == null) {
                _instance = new WallpaperManager();
            }
            return _instance;
        }

        private WallpaperManager() {
            settings = new GLib.Settings("dev.sinty.desktop");
            settings.changed["background-picture-uri"].connect(() => {
                reload();
            });
            reload();
        }

        public void reload() {
            string custom_uri = settings.get_string("background-picture-uri");
            string? path = resolve_path(custom_uri);
            if (path == null) {
                string[] fallbacks = {};
                foreach (unowned string d in GLib.Environment.get_system_data_dirs()) {
                    fallbacks += GLib.Path.build_filename(d, "backgrounds", "singularity", "singularity-cosmos.svg");
                    fallbacks += GLib.Path.build_filename(d, "backgrounds", "singularity", "default.png");
                }
                fallbacks += "../default.png";
                foreach (unowned string d in GLib.Environment.get_system_data_dirs())
                    fallbacks += GLib.Path.build_filename(d, "backgrounds", "default.png");
                fallbacks += "/usr/share/backgrounds/gnome/adwaita-l.jpg";
                foreach (var p in fallbacks) {
                    if (FileUtils.test(p, FileTest.EXISTS)) {
                        path = p;
                        break;
                    } else {
                        if (!p.has_prefix("/")) {
                            try {
                                string exe_path = FileUtils.read_link("/proc/self/exe");
                                var exe_dir = File.new_for_path(exe_path).get_parent();
                                var f = exe_dir.get_child(p);
                                if (f.query_exists()) {
                                    path = f.get_path();
                                    break;
                                }
                            } catch (Error e) {}
                        }
                    }
                }
            }
            if (path != null) {
                if (path == _cached_path) return;
                _cached_path = path;
                wallpaper_path = path;

                int serial;
                _mutex.lock();
                _load_serial++;
                serial = _load_serial;
                _mutex.unlock();

                string load_path = path;
                int target_w = 0;
                int target_h = 0;
                get_display_target_size(out target_w, out target_h);

                new Thread<void>("wallpaper-load", () => {
                    _mutex.lock();
                    if (serial != _load_serial) {
                        _mutex.unlock();
                        return;
                    }
                    _mutex.unlock();

                    Pixbuf? pb_display = null;
                    try {
                        pb_display = load_display_pixbuf(load_path, target_w, target_h);
                    } catch (Error e) {
                        warning("Failed to load wallpaper: %s", e.message);
                    }

                    Pixbuf? pb_medium = null;
                    Pixbuf? pb_small = null;
                    try {
                        pb_medium = new Pixbuf.from_file_at_scale(load_path, 320, 180, true);
                    } catch (Error e) {}
                    try {
                        pb_small = new Pixbuf.from_file_at_scale(load_path, 120, 67, false);
                    } catch (Error e) {}

                    _mutex.lock();
                    bool stale = (serial != _load_serial);
                    _mutex.unlock();
                    if (stale) return;

                    Idle.add(() => {
                        _mutex.lock();
                        bool still_valid = (serial == _load_serial);
                        _mutex.unlock();
                        if (!still_valid) return false;

                        if (pb_display != null) { display_texture = Texture.for_pixbuf(pb_display); _display_pixbuf = pb_display; }
                        if (pb_medium != null) medium_texture = Texture.for_pixbuf(pb_medium);
                        if (pb_small != null) preview_texture = Texture.for_pixbuf(pb_small);
                        message("Wallpaper loaded: %s", load_path);
                        wallpaper_changed();
                        return false;
                    });
                });
            }
        }

        private string? resolve_path(string uri) {
            if (uri == "") return null;
            try {
                var file = File.new_for_uri(uri);
                var path = file.get_path();
                if (path != null && FileUtils.test(path, FileTest.EXISTS)) {
                    return path;
                }
            } catch (Error e) {
            }
            return null;
        }

        public bool top_band_rect(double frac, out int x, out int y, out int w, out int h) {
            x = 0; y = 0; w = 0; h = 0;
            var pb = _display_pixbuf;
            if (pb == null) return false;
            if (frac <= 0.0) frac = 0.05;
            if (frac > 1.0) frac = 1.0;
            int dw = pb.get_width();
            int dh = pb.get_height();
            int tw = 0, th = 0;
            get_display_target_size(out tw, out th);
            if (tw <= 0 || tw > dw) tw = dw;
            if (th <= 0 || th > dh) th = dh;
            x = (dw - tw) / 2;
            y = (dh - th) / 2;
            w = tw;
            h = int.min(int.max(1, (int) Math.ceil(frac * th)), dh - y);
            return true;
        }

        public double top_band_luminance(double frac) {
            int x, y, w, h;
            if (!top_band_rect(frac, out x, out y, out w, out h)) return -1.0;
            var pb = _display_pixbuf;
            if (pb.get_bits_per_sample() != 8) return -1.0;
            int channels = pb.get_n_channels();
            if (channels < 3) return -1.0;
            int rowstride = pb.get_rowstride();
            uint8[] data = pb.get_pixels_with_length();
            int n = data.length;
            double total = 0.0;
            int count = 0;
            for (int yy = y; yy < y + h; yy++) {
                for (int xx = x; xx < x + w; xx++) {
                    int idx = yy * rowstride + xx * channels;
                    if (idx + 2 >= n) continue;
                    double r = data[idx]     / 255.0;
                    double g = data[idx + 1] / 255.0;
                    double b = data[idx + 2] / 255.0;
                    total += 0.2126 * r + 0.7152 * g + 0.0722 * b;
                    count++;
                }
            }
            return count > 0 ? total / count : -1.0;
        }

        public Pixbuf? top_band_pixbuf(double frac) {
            int x, y, w, h;
            if (!top_band_rect(frac, out x, out y, out w, out h)) return null;
            return new Pixbuf.subpixbuf(_display_pixbuf, x, y, w, h);
        }

        public bool get_display_dimensions(out int w, out int h) {
            w = 0; h = 0;
            if (_display_pixbuf == null) return false;
            w = _display_pixbuf.get_width();
            h = _display_pixbuf.get_height();
            return true;
        }

        private void get_display_target_size(out int target_w, out int target_h) {
            target_w = 0;
            target_h = 0;
            var display = Gdk.Display.get_default();
            if (display == null) return;
            var monitors = display.get_monitors();
            for (uint i = 0; i < monitors.get_n_items(); i++) {
                var monitor = monitors.get_item(i) as Gdk.Monitor;
                if (monitor == null) continue;
                var geom = monitor.geometry;
                int scale = monitor.scale_factor;
                target_w = int.max(target_w, geom.width * scale);
                target_h = int.max(target_h, geom.height * scale);
            }
        }

        private Pixbuf load_display_pixbuf(string path, int target_w, int target_h) throws Error {
            if (target_w <= 0 || target_h <= 0) {
                target_w = 1920;
                target_h = 1080;
            }

            int src_w = 0;
            int src_h = 0;
            Gdk.Pixbuf.get_file_info(path, out src_w, out src_h);
            if (src_w <= 0 || src_h <= 0) {
                return new Pixbuf.from_file_at_scale(path, target_w, target_h, true);
            }

            double scale = double.max((double)target_w / (double)src_w,
                                      (double)target_h / (double)src_h);
            int decode_w = int.max(1, (int)Math.ceil(src_w * scale));
            int decode_h = int.max(1, (int)Math.ceil(src_h * scale));
            return new Pixbuf.from_file_at_scale(path, decode_w, decode_h, true);
        }
    }
}
