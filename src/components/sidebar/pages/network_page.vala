using Gtk;
using Singularity.Widgets;

namespace Singularity {

    public class NetworkPage : SettingsPage {

        public NetworkPage(SettingsView view) {
            base(_("Network"));
            back_clicked.connect(() => {
                view.go_home();
            });
            var network = SystemMonitor.get_default().network;
            var wifi_group = new PreferencesGroup(_("Wi-Fi"));
            var toggle_row = new SwitchRow(_("Wi-Fi"), null, network.wifi_enabled);
            toggle_row.switch_btn.notify["active"].connect(() => {
                network.toggle_wifi();
            });
            wifi_group.add_row(toggle_row);
            var network_rows = new List<Widget>();
            network.access_points_changed.connect(() => {
                update_networks_list(wifi_group, ref network_rows, network);
            });
            network.state_changed.connect(() => {
                if (toggle_row.switch_btn.active != network.wifi_enabled) {
                    toggle_row.switch_btn.active = network.wifi_enabled;
                }
                update_networks_list(wifi_group, ref network_rows, network);
            });
            update_networks_list(wifi_group, ref network_rows, network);
            network.request_scan();
            var scan_btn = new Button.from_icon_name("view-refresh-symbolic");
            scan_btn.add_css_class("navigation-button");
            scan_btn.clicked.connect(() => {
                network.request_scan();
            });
            header.append(scan_btn);
            add_group(wifi_group);
            var wired_group = new PreferencesGroup(_("Wired"));
            var wired_status_row = new ActionRow(_("Wired Connection"));
            var wired_status_label = new Label(network.is_wired_connected ? _("Connected") : _("Not Connected"));
            wired_status_label.add_css_class("dim-label");
            wired_status_row.add_suffix(wired_status_label);
            wired_group.add_row(wired_status_row);
            network.state_changed.connect(() => {
                wired_status_label.label = network.is_wired_connected ? _("Connected") : _("Not Connected");
            });
            add_group(wired_group);

            var hs_settings = new GLib.Settings("dev.sinty.desktop");
            string init_ssid, init_pw; bool init_wpa3;
            ensure_hotspot_credentials(hs_settings, out init_ssid, out init_pw, out init_wpa3);

            var hs_group = new PreferencesGroup(_("Hotspot & Sharing"));
            var hotspot_row = new SwitchRow(_("Wi-Fi Hotspot"),
                _("Share your connection over Wi-Fi"), network.wifi_hotspot_active);
            var ssid_row = new EntryRow(_("Hotspot Name"));
            ssid_row.text = init_ssid;
            var pw_row = new EntryRow(_("Hotspot Password"));
            pw_row.text = init_pw;
            var wpa3_row = new SwitchRow(_("WPA3"),
                _("More secure, but newer devices only"), init_wpa3);
            var eth_row = new SwitchRow(_("Share to Wired Device"),
                _("Give internet to a device connected by cable"), network.ethernet_sharing_active);

            hotspot_row.visible = network.has_wifi;
            ssid_row.visible = network.has_wifi;
            pw_row.visible = network.has_wifi;
            wpa3_row.visible = network.has_wifi;
            eth_row.visible = network.has_ethernet;

            hs_group.add_row(hotspot_row);
            hs_group.add_row(ssid_row);
            hs_group.add_row(pw_row);
            hs_group.add_row(wpa3_row);
            hs_group.add_row(eth_row);
            add_group(hs_group);

            hotspot_row.switch_btn.notify["active"].connect(() => {
                bool on = hotspot_row.switch_btn.active;
                if (on == network.wifi_hotspot_active) return;
                if (!on) { network.stop_wifi_hotspot(); return; }

                string ssid = ssid_row.text.strip();
                if (ssid == "") ssid = GLib.Environment.get_host_name();
                string pw = pw_row.text;
                if (pw.length < 8) { pw = NetworkManagerWrapper.generate_password(); pw_row.text = pw; }
                bool wpa3 = wpa3_row.switch_btn.active;
                hs_settings.set_string("hotspot-ssid", ssid);
                hs_settings.set_string("hotspot-password", pw);
                hs_settings.set_boolean("hotspot-wpa3", wpa3);

                if (network.hotspot_needs_disconnect()) {
                    var app = GLib.Application.get_default() as Gtk.Application;
                    var dlg = new ConfirmDialog(app, _("Start Wi-Fi Hotspot?"),
                        "network-wireless-hotspot-symbolic",
                        _("Your current Wi-Fi connection will be disconnected, because the adapter can only join a network or host a hotspot, not both."),
                        _("Start Hotspot"), ConfirmDialog.ActionStyle.SUGGESTED);
                    dlg.response.connect((r) => {
                        if (r == ConfirmDialog.Response.PRIMARY) network.start_wifi_hotspot(ssid, pw, wpa3);
                        else hotspot_row.switch_btn.active = false;
                    });
                    dlg.present();
                } else {
                    network.start_wifi_hotspot(ssid, pw, wpa3);
                }
            });

            eth_row.switch_btn.notify["active"].connect(() => {
                bool on = eth_row.switch_btn.active;
                if (on == network.ethernet_sharing_active) return;
                if (on) network.start_ethernet_sharing();
                else network.stop_ethernet_sharing();
            });

            network.hotspot_state_changed.connect(() => {
                if (hotspot_row.switch_btn.active != network.wifi_hotspot_active)
                    hotspot_row.switch_btn.active = network.wifi_hotspot_active;
                if (eth_row.switch_btn.active != network.ethernet_sharing_active)
                    eth_row.switch_btn.active = network.ethernet_sharing_active;
            });
            network.sharing_action_result.connect((ok, msg) => {
                if (!ok) {
                    warning("hotspot/sharing: %s", msg);
                    hotspot_row.switch_btn.active = network.wifi_hotspot_active;
                    eth_row.switch_btn.active = network.ethernet_sharing_active;
                }
            });

            // VPN section
            var vpn_group = new PreferencesGroup(_("VPN"));
            var vpn_rows = new List<Widget>();
            update_vpn_list(vpn_group, ref vpn_rows, network);
            network.vpn_state_changed.connect(() => {
                update_vpn_list(vpn_group, ref vpn_rows, network);
            });
            network.vpn_connections_changed.connect(() => {
                update_vpn_list(vpn_group, ref vpn_rows, network);
            });
            // Surface the result of import / manual-add / remove actions.
            network.vpn_action_result.connect(on_vpn_action_result);

            // Plugin-provided VPN backends (e.g. Tailscale). They register
            // through PluginContext and land in VpnProviderRegistry; render
            // them alongside the NetworkManager VPNs and refresh on changes.
            var vpn_registry = VpnProviderRegistry.get_default();
            foreach (var p in vpn_registry.list()) {
                p.changed.connect(() => update_vpn_list(vpn_group, ref vpn_rows, network));
                p.action_result.connect(on_vpn_action_result);
            }
            vpn_registry.added.connect((p) => {
                p.changed.connect(() => update_vpn_list(vpn_group, ref vpn_rows, network));
                p.action_result.connect(on_vpn_action_result);
                update_vpn_list(vpn_group, ref vpn_rows, network);
            });
            vpn_registry.removed.connect((p) => {
                update_vpn_list(vpn_group, ref vpn_rows, network);
            });

            // Add a VPN by hand - opens our native multi-level page (back arrow),
            // not a dialog and not GNOME's settings.
            var add_row = new ActionRow(_("Add VPN"), _("Enter WireGuard or OpenVPN details"), "list-add-symbolic");
            add_row.activatable = true;
            var add_gesture = new GestureClick();
            add_gesture.released.connect(() => {
                view.open_subpage(new VpnConfigPage(view, network), "vpn-config");
            });
            add_row.add_controller(add_gesture);
            vpn_group.add_row(add_row);

            var import_row = new ActionRow(_("Import VPN Configuration"), _("OpenVPN .ovpn, WireGuard .conf, or .nmconnection"), "document-open-symbolic");
            import_row.activatable = true;
            var import_gesture = new GestureClick();
            import_gesture.released.connect(() => {
                var chooser = new FileDialog();
                chooser.title = _("Import VPN Configuration");
                var filter_store = new GLib.ListStore(typeof(Gtk.FileFilter));
                var vpn_filter = new Gtk.FileFilter();
                vpn_filter.name = "VPN Config Files";
                vpn_filter.add_pattern("*.ovpn");
                vpn_filter.add_pattern("*.conf");
                vpn_filter.add_pattern("*.nmconnection");
                filter_store.append(vpn_filter);
                var all_filter = new Gtk.FileFilter();
                all_filter.name = "All Files";
                all_filter.add_pattern("*");
                filter_store.append(all_filter);
                chooser.filters = filter_store;
                chooser.open.begin(null, null, (obj, res) => {
                    try {
                        var file = chooser.open.end(res);
                        if (file != null) {
                            var path = file.get_path();
                            if (path != null) {
                                network.import_vpn.begin(path);
                            }
                        }
                    } catch (Error e) {
                        // user cancelled or error
                    }
                });
            });
            import_row.add_controller(import_gesture);
            vpn_group.add_row(import_row);
            add_group(vpn_group);
        }

        public static void ensure_hotspot_credentials(GLib.Settings s,
                out string ssid, out string password, out bool wpa3) {
            ssid = s.get_string("hotspot-ssid");
            if (ssid == "") { ssid = GLib.Environment.get_host_name(); s.set_string("hotspot-ssid", ssid); }
            password = s.get_string("hotspot-password");
            if (password.length < 8) { password = NetworkManagerWrapper.generate_password(); s.set_string("hotspot-password", password); }
            wpa3 = s.get_boolean("hotspot-wpa3");
        }

        private void update_networks_list(PreferencesGroup group, ref List<Widget> rows, NetworkManagerWrapper network) {
            foreach (var row in rows) {
                group.remove_row(row);
            }
            rows = new List<Widget>();
            if (!network.wifi_enabled) {
                var lbl_row = new PreferencesRow();
                var lbl = new Label(_("Wi-Fi is disabled"));
                lbl.add_css_class("dim-label");
                lbl.margin_top = 12;
                lbl.margin_bottom = 12;
                lbl_row.set_child(lbl);
                group.add_row(lbl_row);
                rows.append(lbl_row);
                return;
            }
            var aps = network.get_access_points();
            if (aps.length == 0) {
                var lbl_row = new PreferencesRow();
                var lbl = new Label(_("No networks found"));
                lbl.add_css_class("dim-label");
                lbl.margin_top = 12;
                lbl.margin_bottom = 12;
                lbl_row.set_child(lbl);
                group.add_row(lbl_row);
                rows.append(lbl_row);
                return;
            }
            var seen_ssids = new GenericSet<string>(str_hash, str_equal);
            foreach (var ap in aps) {
                var ssid_bytes = ap.ssid;
                if (ssid_bytes == null) continue;
                string ssid = NM.Utils.ssid_to_utf8(ssid_bytes.get_data());
                if (ssid == "") continue;
                if (seen_ssids.contains(ssid)) continue;
                seen_ssids.add(ssid);
                string icon_name = "network-wireless-signal-good-symbolic";
                if (ap.strength < 30) icon_name = "network-wireless-signal-weak-symbolic";
                else if (ap.strength < 60) icon_name = "network-wireless-signal-ok-symbolic";
                else if (ap.strength < 80) icon_name = "network-wireless-signal-good-symbolic";
                else icon_name = "network-wireless-signal-excellent-symbolic";
                var row = new ActionRow(ssid, null, icon_name);
                row.activatable = true;
                bool is_connected = (network.wifi_ssid == ssid);
                if (is_connected) {
                    row.subtitle = _("Connected");
                    row.add_suffix(new Image.from_icon_name("object-select-symbolic"));
                    row.add_css_class("selected");
                }
                if (ap.rsn_flags != NM.80211ApSecurityFlags.NONE || ap.wpa_flags != NM.80211ApSecurityFlags.NONE) {
                    var lock_icon = new Image.from_icon_name("changes-prevent-symbolic");
                    lock_icon.add_css_class("dim-label");
                    lock_icon.pixel_size = 12;
                    row.add_suffix(lock_icon);
                }
                var gesture = new GestureClick();
                gesture.released.connect(() => {
                    if (is_connected) return;
                    bool secured = (ap.rsn_flags != NM.80211ApSecurityFlags.NONE || ap.wpa_flags != NM.80211ApSecurityFlags.NONE);
                    if (secured) {
                        var dialog = new WifiPasswordDialog(ssid);
                        dialog.response.connect((accepted) => {
                            if (accepted) {
                                network.connect_to_ap(ap, dialog.password);
                            }
                        });
                        dialog.open_dialog();
                    } else {
                        network.connect_to_ap(ap, null);
                    }
                });
                row.add_controller(gesture);
                group.add_row(row);
                rows.append(row);
            }
        }

        // Shows the result of import / manual-add / remove / provider actions.
        private void on_vpn_action_result(bool success, string message) {
            if (success) return;
            var app = (Gtk.Application) GLib.Application.get_default();
            var dlg = new Singularity.Widgets.ConfirmDialog(
                app, "VPN", "dialog-error-symbolic", message, "OK");
            dlg.response.connect((r) => dlg.close_dialog());
            dlg.open_dialog();
        }

        private void update_vpn_list(PreferencesGroup group, ref List<Widget> rows, NetworkManagerWrapper network) {
            foreach (var row in rows) {
                group.remove_row(row);
            }
            rows = new List<Widget>();

            int total = 0;

            // NetworkManager-managed VPNs (built-in: vpn / wireguard).
            foreach (var vpn_conn in network.get_vpn_connections()) {
                var row = build_nm_vpn_row(vpn_conn, network);
                group.add_row(row);
                rows.append(row);
                total++;
            }

            // Plugin-provided VPN backends (Tailscale, ...).
            foreach (var provider in VpnProviderRegistry.get_default().list()) {
                foreach (var conn in provider.get_connections()) {
                    var row = build_provider_vpn_row(conn);
                    group.add_row(row);
                    rows.append(row);
                    total++;
                }
            }

            if (total == 0) {
                var lbl_row = new PreferencesRow();
                var lbl = new Label(_("No VPN connections configured"));
                lbl.add_css_class("dim-label");
                lbl.margin_top = 12;
                lbl.margin_bottom = 12;
                lbl_row.set_child(lbl);
                group.add_row(lbl_row);
                rows.append(lbl_row);
            }
        }

        private Widget build_nm_vpn_row(NM.RemoteConnection vpn_conn, NetworkManagerWrapper network) {
            string name = vpn_conn.get_id();
            var link_state = network.vpn_link_state(vpn_conn);

            string state_str;
            switch (link_state) {
                case NetworkManagerWrapper.VpnLinkState.CONNECTED:  state_str = "Connected"; break;
                case NetworkManagerWrapper.VpnLinkState.CONNECTING: state_str = "Connecting…"; break;
                default:                                            state_str = "Disconnected"; break;
            }

            bool is_wireguard = (vpn_conn.get_connection_type() == "wireguard");
            var row = new ActionRow(name, state_str,
                is_wireguard ? "network-wireless-symbolic" : "network-vpn-symbolic");

            var captured_conn = vpn_conn;

            var connect_btn = new Button();
            connect_btn.has_frame = false;
            connect_btn.valign = Align.CENTER;
            if (link_state == NetworkManagerWrapper.VpnLinkState.CONNECTED) {
                connect_btn.icon_name = "media-playback-stop-symbolic";
                connect_btn.tooltip_text = _("Disconnect");
                connect_btn.add_css_class("destructive-action-flat");
                connect_btn.clicked.connect(() => {
                    network.deactivate_connection(captured_conn);
                });
            } else {
                connect_btn.icon_name = "network-vpn-symbolic";
                connect_btn.tooltip_text = _("Connect");
                connect_btn.add_css_class("suggested-action-flat");
                connect_btn.clicked.connect(() => {
                    network.activate_vpn(captured_conn);
                });
            }
            row.add_suffix(connect_btn);

            // Right-click to remove ("forget") the connection.
            var remove_gesture = new GestureClick();
            remove_gesture.button = Gdk.BUTTON_SECONDARY;
            remove_gesture.released.connect((n, x, y) => {
                var menu = new Singularity.Widgets.ContextMenu(row);
                Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
                menu.set_pointing_to(rect);
                menu.add_item("Remove VPN", "user-trash-symbolic", () => {
                    network.delete_vpn(captured_conn);
                });
                menu.popup();
            });
            row.add_controller(remove_gesture);

            return row;
        }

        private Widget build_provider_vpn_row(VpnConnection conn) {
            string state_str;
            switch (conn.state) {
                case VpnState.CONNECTED:  state_str = "Connected"; break;
                case VpnState.CONNECTING: state_str = "Connecting…"; break;
                default:                  state_str = "Disconnected"; break;
            }

            var row = new ActionRow(conn.display_name, state_str, conn.icon_name);

            var connect_btn = new Button();
            connect_btn.has_frame = false;
            connect_btn.valign = Align.CENTER;
            if (conn.state == VpnState.CONNECTED) {
                connect_btn.icon_name = "media-playback-stop-symbolic";
                connect_btn.tooltip_text = _("Disconnect");
                connect_btn.add_css_class("destructive-action-flat");
                connect_btn.clicked.connect(() => {
                    conn.deactivate.begin();
                });
            } else {
                connect_btn.icon_name = "network-vpn-symbolic";
                connect_btn.tooltip_text = _("Connect");
                connect_btn.add_css_class("suggested-action-flat");
                connect_btn.clicked.connect(() => {
                    conn.activate.begin();
                });
            }
            row.add_suffix(connect_btn);

            if (conn.can_remove) {
                var remove_gesture = new GestureClick();
                remove_gesture.button = Gdk.BUTTON_SECONDARY;
                remove_gesture.released.connect((n, x, y) => {
                    var menu = new Singularity.Widgets.ContextMenu(row);
                    Gdk.Rectangle rect = { (int) x, (int) y, 1, 1 };
                    menu.set_pointing_to(rect);
                    menu.add_item("Remove VPN", "user-trash-symbolic", () => {
                        conn.remove.begin();
                    });
                    menu.popup();
                });
                row.add_controller(remove_gesture);
            }

            return row;
        }
    }
}
