/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Single-line label for the panel. When the text is wider than
 * max_width it rests with a soft fade on the right edge and scrolls
 * once (ticker style) when the text changes or when hovered.
 * Text is drawn with gtk_render_layout, so it picks up the panel's
 * colour and text-shadow just like a regular Gtk.Label.
 */

public class NowPlaying.MarqueeLabel : Gtk.DrawingArea {
    private const int GAP = 40;              /* px between the end and the repeated start */
    private const double SPEED = 40.0;       /* px per second */
    private const int FADE = 16;             /* px of the edge fade */
    private const uint START_DELAY = 1200;   /* ms before scrolling after a change */

    public int max_width { get; set; default = 200; }

    private string _text = "";
    public string text {
        get { return _text; }
        set {
            if (value == _text) {
                return;
            }
            _text = value;
            layout = null;
            stop_scroll ();
            queue_resize ();
            schedule_scroll ();
        }
    }

    private Pango.Layout? layout = null;
    private double offset = 0;
    private int64 scroll_started = 0;
    private uint tick_id = 0;
    private uint delay_id = 0;

    construct {
        get_style_context ().add_class ("nowplaying-marquee");
        add_events (Gdk.EventMask.ENTER_NOTIFY_MASK);

        enter_notify_event.connect (() => {
            start_scroll ();
            return Gdk.EVENT_PROPAGATE;
        });

        notify["max-width"].connect (() => queue_resize ());
    }

    private void ensure_layout () {
        if (layout == null) {
            layout = create_pango_layout (_text);
            layout.set_single_paragraph_mode (true);
        }
    }

    public override void style_updated () {
        base.style_updated ();
        layout = null;
        queue_resize ();
    }

    private int text_width () {
        ensure_layout ();
        int w, h;
        layout.get_pixel_size (out w, out h);
        return w;
    }

    private bool overflows () {
        return text_width () > get_allocated_width () && get_allocated_width () > 0;
    }

    private bool animations_enabled () {
        return Gtk.Settings.get_default ().gtk_enable_animations;
    }

    public override void get_preferred_width (out int minimum, out int natural) {
        natural = int.min (text_width (), max_width);
        minimum = natural;
    }

    public override void get_preferred_height (out int minimum, out int natural) {
        ensure_layout ();
        int w, h;
        layout.get_pixel_size (out w, out h);
        /* a little room so the text-shadow isn't clipped */
        minimum = natural = h + 4;
    }

    private void schedule_scroll () {
        if (delay_id != 0) {
            Source.remove (delay_id);
        }
        delay_id = Timeout.add (START_DELAY, () => {
            delay_id = 0;
            start_scroll ();
            return Source.REMOVE;
        });
    }

    public void start_scroll () {
        if (tick_id != 0 || !get_mapped () || !overflows () || !animations_enabled ()) {
            return;
        }

        scroll_started = 0;
        tick_id = add_tick_callback ((widget, clock) => {
            int64 now = clock.get_frame_time ();
            if (scroll_started == 0) {
                scroll_started = now;
            }

            double distance = text_width () + GAP;
            offset = (now - scroll_started) / 1000000.0 * SPEED;

            if (offset >= distance) {
                offset = 0;
                tick_id = 0;
                queue_draw ();
                return Source.REMOVE;
            }

            queue_draw ();
            return Source.CONTINUE;
        });
    }

    private void stop_scroll () {
        if (tick_id != 0) {
            remove_tick_callback (tick_id);
            tick_id = 0;
        }
        offset = 0;
    }

    public override void unmap () {
        stop_scroll ();
        base.unmap ();
    }

    public override bool draw (Cairo.Context cr) {
        ensure_layout ();

        var context = get_style_context ();
        int alloc_w = get_allocated_width ();
        int alloc_h = get_allocated_height ();
        int text_w, text_h;
        layout.get_pixel_size (out text_w, out text_h);
        double y = (alloc_h - text_h) / 2.0;

        if (text_w <= alloc_w) {
            context.render_layout (cr, 0, y, layout);
            return Gdk.EVENT_PROPAGATE;
        }

        cr.push_group ();
        context.render_layout (cr, -offset, y, layout);
        if (offset > 0) {
            context.render_layout (cr, -offset + text_w + GAP, y, layout);
        }
        cr.pop_group_to_source ();

        /* Fade the edges: right edge always, left edge only while moving */
        var mask = new Cairo.Pattern.linear (0, 0, alloc_w, 0);
        double f = (double) FADE / alloc_w;
        mask.add_color_stop_rgba (0, 0, 0, 0, offset > 0 ? 0 : 1);
        mask.add_color_stop_rgba (f, 0, 0, 0, 1);
        mask.add_color_stop_rgba (1 - f, 0, 0, 0, 1);
        mask.add_color_stop_rgba (1, 0, 0, 0, 0);
        cr.mask (mask);

        return Gdk.EVENT_PROPAGATE;
    }
}
