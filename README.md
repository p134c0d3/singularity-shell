# Singularity Shell

The desktop shell for the Singularity Desktop Environment: the panel, dock,
overview, sidebar, notifications, run dialog, app switcher, lock screen, and
the compositor integration that drives `labwc`.

This builds the main `singularity-desktop` executable along with the
`singularity-region-picker`, `singularity-keyboard-reset`, and
`singularity-screenshot` helpers.

## Requirements

- [Meson](https://mesonbuild.com/) >= 0.59
- [Vala](https://vala.dev/) compiler
- GTK4, gtk4-layer-shell, wayland-client, wayland-scanner
- VTE (`vte-2.91-gtk4`), GtkSourceView 5, poppler-glib
- NetworkManager (`libnm`), UPower, PulseAudio, GNOME Online Accounts
- polkit, gnome-desktop-4, libsoup-3.0, json-glib, libpeas-2
- dbusmenu-glib, atspi-2, tracker-sparql-3.0, gudev-1.0
- PAM (`libpam`, lock screen authentication)
- [libsingularity](https://github.com/singularityos-lab/libsingularity)

## Build & Install

```sh
meson setup build
meson compile -C build
meson install -C build
```

## License

GPL-3.0-only - see [LICENSE](LICENSE).
