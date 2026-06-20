namespace Singularity {

    public class WaylandGammaBackend : GLib.Object, GammaBackend {
        public void set_night_light(int temperature) {
            Singularity.wayland_set_night_light(temperature);
        }

        public void reset_night_light() {
            Singularity.wayland_reset_night_light();
        }
    }
}
