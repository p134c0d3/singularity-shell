using GLib;
using Gdk;

namespace Singularity {

    public delegate void PreviewReadyCallback(Gdk.Texture? texture);

    private class PreviewWaiter : Object {
        public PreviewReadyCallback cb;
        public PreviewWaiter(owned PreviewReadyCallback cb) { this.cb = (owned) cb; }
    }

    public class PreviewCache : Object {
        private static PreviewCache? _instance = null;
        private Gee.HashMap<string, Gdk.Texture> textures = new Gee.HashMap<string, Gdk.Texture>();
        private Gee.HashMap<string, int> texture_sizes = new Gee.HashMap<string, int>();
        private Gee.HashSet<string> pending = new Gee.HashSet<string>();
        // Callbacks waiting on an in-flight capture, keyed by capture key. A
        // fast workspace switch creates a new preview for the same window while
        // the previous capture is still running; queue its callback instead of
        // dropping it, otherwise the new preview stays blank (#48).
        private Gee.HashMap<string, Gee.ArrayList<PreviewWaiter>> waiters =
            new Gee.HashMap<string, Gee.ArrayList<PreviewWaiter>>();
        private const int MAX_BYTES = 24 * 1024 * 1024;
        private int cached_bytes = 0;

        public static PreviewCache get_default() {
            if (_instance == null) _instance = new PreviewCache();
            return _instance;
        }

        public void invalidate(void* handle) {
            string prefix = "%lu:".printf((ulong)handle);
            var stale = new Gee.ArrayList<string>();
            foreach (var key in textures.keys) {
                if (key.has_prefix(prefix)) stale.add(key);
            }
            foreach (var key in stale) remove_texture(key);
        }

        public void clear() {
            textures.clear();
            texture_sizes.clear();
            cached_bytes = 0;
            pending.clear();
            waiters.clear();
            // Also free the compositor-side SHM buffer pool. The overview is
            // closing, so the recycled capture buffers (which labwc keeps
            // mapped) are no longer needed and would otherwise sit idle.
            Singularity.wayland_preview_pool_trim();
        }

        private void remove_texture(string key) {
            if (texture_sizes.has_key(key)) {
                cached_bytes -= texture_sizes[key];
                texture_sizes.unset(key);
            }
            textures.unset(key);
            if (cached_bytes < 0) cached_bytes = 0;
        }

        private void evict_until_room(int needed) {
            while (cached_bytes + needed > MAX_BYTES && textures.size > 0) {
                foreach (var old_key in textures.keys) {
                    remove_texture(old_key);
                    break;
                }
            }
        }

        public void request(void* handle, int max_w, int max_h, owned PreviewReadyCallback callback) {
            debug("[PreviewCache] request: handle=%p max=%dx%d", handle, max_w, max_h);
            if (handle == null) {
                debug("[PreviewCache] null handle, skipping");
                callback(null);
                return;
            }

            string key = "%lu:%d:%d".printf((ulong)handle, max_w, max_h);
            if (textures.has_key(key)) {
                var texture = textures[key];
                Idle.add(() => {
                    callback(texture);
                    return Source.REMOVE;
                });
                return;
            }

            // Queue this callback under the key; if a capture is already in
            // flight for it, the running capture will notify every waiter.
            if (!waiters.has_key(key)) waiters[key] = new Gee.ArrayList<PreviewWaiter>();
            waiters[key].add(new PreviewWaiter((owned) callback));
            if (pending.contains(key)) return;
            pending.add(key);

            Singularity.wayland_capture_preview(handle, (w, h, s, data) => {
                pending.remove(key);
                Gdk.Texture? result = null;
                if (data == null || w <= 0 || h <= 0 || s <= 0) {
                    warning("[PreviewCache] capture failed for key %s: w=%d h=%d s=%d data=%s", key, w, h, s, data == null ? "null" : "ok");
                } else {
                    unowned uint8[] buf = (uint8[])data;
                    buf.length = h * s;
                    try {
                        result = new Gdk.MemoryTexture(w, h, Gdk.MemoryFormat.B8G8R8A8_PREMULTIPLIED, new Bytes(buf), s);
                        int size = h * s;
                        if (size <= MAX_BYTES / 2) {
                            evict_until_room(size);
                            textures[key] = result;
                            texture_sizes[key] = size;
                            cached_bytes += size;
                        }
                    } catch (Error e) {
                        result = null;
                    }
                }
                var ws = waiters[key];
                waiters.unset(key);
                if (ws != null) {
                    foreach (var wt in ws) wt.cb(result);
                }
            });
        }
    }
}
