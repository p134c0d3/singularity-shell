using Gtk;
using Singularity.Widgets;

namespace Singularity.SidebarPages {

    public class AddInputSourcePage : SettingsPage {
        public signal void source_selected(string id, string name);
        private List<InputSourceInfo> all_sources;
        private Singularity.Widgets.SearchEntry search_entry;
        private PreferencesGroup list_group;
        private class InputSourceInfo {
            public string id;
            public string name;
            public string description;

            public InputSourceInfo(string id, string name, string description) {
                this.id = id;
                this.name = name;
                this.description = description;
            }
        }

        public AddInputSourcePage(SettingsView view) {
            base(_("Add Input Source"));
            back_clicked.connect(() => {
                view.navigate_to("keyboard");
            });
            all_sources = new List<InputSourceInfo>();
            search_entry = new Singularity.Widgets.SearchEntry();
            search_entry.placeholder_text = _("Search languages...");
            search_entry.search_changed.connect(filter_list);
            add_widget(search_entry);
            list_group = new PreferencesGroup(_("Available Layouts"));
            add_group(list_group);
            Idle.add(() => {
                load_sources();
                return false;
            });
        }

        private void load_sources() {
            string? path = find_layout_list();
            if (path != null) {
                string contents;
                try {
                    FileUtils.get_contents(path, out contents);
                    string section = "";
                    foreach (unowned string raw in contents.split("\n")) {
                        string line = raw.chomp();
                        if (line.has_prefix("!")) {
                            section = line.substring(1).strip();
                            continue;
                        }
                        if (line.strip() == "")
                            continue;
                        if (section == "layout")
                            add_layout(line);
                        else if (section == "variant")
                            add_variant(line);
                    }
                } catch (Error e) {
                    warning("Could not read keyboard layout list: %s", e.message);
                }
            }
            all_sources.sort((a, b) => {
                return a.name.collate(b.name);
            });
            populate_list();
        }

        private string? find_layout_list() {
            string[] paths = {
                "/usr/share/X11/xkb/rules/evdev.lst",
                "/usr/local/share/X11/xkb/rules/evdev.lst"
            };
            foreach (unowned string p in paths) {
                if (FileUtils.test(p, FileTest.EXISTS))
                    return p;
            }
            return null;
        }

        private int first_blank(string s) {
            for (int i = 0; i < s.length; i++) {
                if (s[i] == ' ' || s[i] == '\t')
                    return i;
            }
            return -1;
        }

        private void add_layout(string line) {
            string trimmed = line.strip();
            int sep = first_blank(trimmed);
            if (sep <= 0)
                return;
            string id = trimmed.substring(0, sep);
            string desc = trimmed.substring(sep).strip();
            all_sources.append(new InputSourceInfo(id, desc, id));
        }

        private void add_variant(string line) {
            string trimmed = line.strip();
            int sep = first_blank(trimmed);
            if (sep <= 0)
                return;
            string variant = trimmed.substring(0, sep);
            string rest = trimmed.substring(sep).strip();
            string layout = variant;
            string desc = rest;
            int colon = rest.index_of(":");
            if (colon > 0) {
                layout = rest.substring(0, colon).strip();
                desc = rest.substring(colon + 1).strip();
            }
            all_sources.append(new InputSourceInfo(layout + "+" + variant, desc, layout + "+" + variant));
        }

        private void populate_list() {
            filter_list(search_entry);
        }

        private void filter_list(Singularity.Widgets.SearchEntry entry) {
            list_group.clear();
            string query = entry.text.down();
            int count = 0;
            foreach (var source in all_sources) {
                if (query == "" || source.name.down().contains(query) || source.description.down().contains(query)) {
                    var row = new ActionRow(source.name, source.description);
                    var btn = new Button.from_icon_name("list-add-symbolic");
                    btn.add_css_class("circular-button");
                    btn.valign = Align.CENTER;
                    btn.clicked.connect(() => {
                        source_selected(source.id, source.name);
                    });
                    row.add_suffix(btn);
                    row.activatable = true;
                    var gesture = new GestureClick();
                    gesture.released.connect(() => {
                        source_selected(source.id, source.name);
                    });
                    row.add_controller(gesture);
                    list_group.add_row(row);
                    count++;
                    if (count > 50) break;
                }
            }
        }
    }
}
