using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class BluetoothPage : SettingsPage {
        private BluetoothManager manager;
        private SwitchRow power_row;
        private PreferencesGroup devices_group;
        private Box devices_box;
        private bool _syncing = false;

        public BluetoothPage(SettingsView view) {
            base(_("Bluetooth"));
            back_clicked.connect(() => {
                view.go_home();
            });
            manager = SystemMonitor.get_default().bluetooth;
            build_ui();
            manager.state_changed.connect(update_state);
            manager.device_added.connect((d) => update_devices());
            manager.device_removed.connect((p) => update_devices());
            manager.device_changed.connect((p) => update_devices());
            update_state();
            update_devices();
        }

        private void build_ui() {
            var group = new PreferencesGroup(_("General"));
            power_row = new SwitchRow(_("Bluetooth"), _("Turn Bluetooth on or off"), false);
            power_row.switch_btn.notify["active"].connect(() => {
                if (_syncing) return;
                manager.set_power.begin(power_row.active);
            });
            group.add_row(power_row);
            add_group(group);
            devices_group = new PreferencesGroup(_("Devices"));
            devices_box = new Box(Orientation.VERTICAL, 0);
            var row = new PreferencesRow();
            row.set_child(devices_box);
            devices_group.add_row(row);
            add_group(devices_group);
        }

        private void update_state() {
            if (power_row.active != manager.is_powered) {
                _syncing = true;
                power_row.active = manager.is_powered;
                _syncing = false;
            }
            devices_group.visible = manager.is_powered;
            if (manager.is_powered && !manager.is_discovering) {
                manager.start_discovery.begin();
            } else if (!manager.is_powered && manager.is_discovering) {
                manager.stop_discovery.begin();
            }
        }

        private void update_devices() {
            Widget? child = devices_box.get_first_child();
            while (child != null) {
                var next = child.get_next_sibling();
                devices_box.remove(child);
                child = next;
            }
            if (manager.devices.length() == 0) {
                var lbl = new Label(_("No devices found"));
                lbl.add_css_class("dim-label");
                lbl.margin_top = 12;
                lbl.margin_bottom = 12;
                devices_box.append(lbl);
                return;
            }
            foreach (var device in manager.devices) {
                string dev_path = device.path;
                var row = new Box(Orientation.HORIZONTAL, 12);
                row.margin_top = 8;
                row.margin_bottom = 8;
                row.margin_start = 12;
                row.margin_end = 12;
                var icon = new Image.from_icon_name(BluetoothManager.bt_icon_for(device.icon));
                icon.pixel_size = 24;
                row.append(icon);
                var lbl = new Label(device.name);
                lbl.hexpand = true;
                lbl.halign = Align.START;
                lbl.ellipsize = Pango.EllipsizeMode.END;
                row.append(lbl);
                if (device.connected) {
                    var status = new Label(_("Connected"));
                    status.add_css_class("dim-label");
                    row.append(status);
                } else if (device.paired) {
                    var status = new Label(_("Paired"));
                    status.add_css_class("dim-label");
                    row.append(status);
                }
                if (manager.connecting_path == dev_path) {
                    var spinner = new Spinner();
                    spinner.spinning = true;
                    spinner.tooltip_text = _("Connecting…");
                    row.append(spinner);
                } else {
                    var btn = new Button();
                    btn.add_css_class("flat");
                    if (device.connected) {
                        btn.icon_name = "network-offline-symbolic";
                        btn.tooltip_text = _("Disconnect");
                        btn.clicked.connect(() => {
                            manager.disconnect_device.begin(dev_path);
                        });
                    } else {
                        btn.icon_name = "network-transmit-receive-symbolic";
                        btn.tooltip_text = _("Connect");
                        btn.clicked.connect(() => {
                            manager.connect_device.begin(dev_path);
                        });
                    }
                    row.append(btn);
                }
                if (device.paired) {
                    var forget_btn = new Button.from_icon_name("user-trash-symbolic");
                    forget_btn.add_css_class("flat");
                    forget_btn.tooltip_text = _("Forget Device");
                    forget_btn.clicked.connect(() => {
                        manager.remove_device.begin(dev_path);
                    });
                    row.append(forget_btn);
                }
                devices_box.append(row);
            }
        }

        public override void dispose() {
            if (manager.is_discovering) {
                manager.stop_discovery.begin();
            }
            base.dispose();
        }
    }
}
