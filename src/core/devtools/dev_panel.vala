using Gtk;

namespace Singularity {

    public class DevPanel : Box {

        public signal void closed ();
        public signal void moved ();

        public string panel_id { get; construct; }

        private Fixed _canvas;
        private Box _header;
        private Box _body;
        private ScrolledWindow _scroller;
        private double _drag_origin_x = 0;
        private double _drag_origin_y = 0;
        private int _x = 0;
        private int _y = 0;
        private int _rw = 0;
        private int _rh = 0;

        public DevPanel (string panel_id, string title, Fixed canvas) {
            Object (panel_id: panel_id, orientation: Orientation.VERTICAL, spacing: 0);
            _canvas = canvas;
            add_css_class ("devtools-panel");

            _header = new Box (Orientation.HORIZONTAL, 6);
            _header.add_css_class ("devtools-panel-header");

            var title_lbl = new Label (title);
            title_lbl.add_css_class ("devtools-panel-title");
            title_lbl.halign = Align.START;
            title_lbl.hexpand = true;
            title_lbl.ellipsize = Pango.EllipsizeMode.END;
            _header.append (title_lbl);

            var close_btn = new Button.with_label ("x");
            close_btn.add_css_class ("devtools-panel-close");
            close_btn.has_frame = false;
            close_btn.clicked.connect (() => closed ());
            _header.append (close_btn);

            append (_header);

            _scroller = new ScrolledWindow ();
            _scroller.hscrollbar_policy = PolicyType.NEVER;
            _scroller.vscrollbar_policy = PolicyType.AUTOMATIC;
            _scroller.propagate_natural_height = true;
            _scroller.min_content_height = 120;
            _scroller.max_content_height = 560;
            _scroller.vexpand = true;

            _body = new Box (Orientation.VERTICAL, 4);
            _body.add_css_class ("devtools-panel-body");
            _scroller.set_child (_body);
            append (_scroller);

            var resize = new Box (Orientation.HORIZONTAL, 0);
            resize.add_css_class ("devtools-resize");
            resize.halign = Align.END;
            resize.width_request = 18;
            resize.height_request = 12;
            var rdrag = new GestureDrag ();
            rdrag.drag_begin.connect ((sx, sy) => {
                _rw = get_width ();
                _rh = _scroller.get_height ();
            });
            rdrag.drag_update.connect ((dx, dy) => {
                int nw = (int) (_rw + dx);
                int nh = (int) (_rh + dy);
                if (nw < 200) nw = 200;
                if (nh < 60) nh = 60;
                width_request = nw;
                _scroller.min_content_height = nh;
                _scroller.max_content_height = nh;
                moved ();
            });
            resize.add_controller (rdrag);
            append (resize);

            var drag = new GestureDrag ();
            drag.drag_begin.connect ((sx, sy) => {
                _drag_origin_x = _x;
                _drag_origin_y = _y;
            });
            drag.drag_update.connect ((ox, oy) => {
                _x = (int) (_drag_origin_x + ox);
                _y = (int) (_drag_origin_y + oy);
                if (_x < 0) _x = 0;
                if (_y < 0) _y = 0;
                _canvas.move (this, _x, _y);
                moved ();
            });
            drag.drag_end.connect ((ox, oy) => moved ());
            _header.add_controller (drag);
        }

        public Box content {
            get { return _body; }
        }

        public void place_at (int x, int y) {
            _x = x;
            _y = y;
            _canvas.put (this, x, y);
        }

        public void clear () {
            Widget? c = _body.get_first_child ();
            while (c != null) {
                Widget? n = c.get_next_sibling ();
                _body.remove (c);
                c = n;
            }
        }
    }
}
