/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Single-line label for the panel. When the text is wider than
 * max_width it scrolls like a ticker:
 *   - with `loop` on (music playing) it keeps scrolling, pausing briefly
 *     at the start of every lap;
 *   - with `loop` off (paused) it rests with a soft fade on the right
 *     edge and only scrolls one lap when hovered or when the text changes.
 * Text is drawn with gtk_render_layout, so it picks up the panel's
 * colour and text-shadow just like a regular Gtk.Label.
 * Lyrics mode (show_line): fixed width, short lines are centred and long
 * lines pan once from start to end over the time the line is sung.
 * Respects the system "reduce motion" setting (gtk-enable-animations).
 */

public class NowPlaying.MarqueeLabel : Gtk.DrawingArea {
    private const int GAP = 48;              /* px between the end and the repeated start */
    private const double SPEED = 30.0;       /* px per second */
    private const int FADE = 16;             /* px of the edge fade */
    private const uint START_DELAY = 1500;   /* ms before scrolling after a text change */
    private const uint LAP_PAUSE = 2500;     /* ms resting at the start between laps */
    private const uint PAN_DELAY = 500;      /* ms before a long lyric line starts panning */

    public int max_width { get; set; default = 200; }

    private string _text = "";
    public string text {
        get { return _text; }
        set {
            if (value == _text && !pan_mode) {
                return;
            }
            _text = value;
            pan_mode = false;
            layout = null;
            stop_scroll ();
            queue_resize ();
            schedule_scroll (START_DELAY);
        }
    }

    private bool _loop = false;
    public bool loop {
        get { return _loop; }
        set {
            if (value == _loop) {
                return;
            }
            _loop = value;
            /* Turning loop on starts right away; turning it off lets the current lap finish */
            if (_loop && tick_id == 0 && !pan_mode) {
                schedule_scroll (START_DELAY);
            }
        }
    }

    /* true while showing lyric lines */
    public bool pan_mode { get; private set; default = false; }
    private uint pan_duration = 0;

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

        Gtk.Settings.get_default ().notify["gtk-enable-animations"].connect (() => {
            stop_scroll ();
            queue_draw ();
            if (_loop) {
                schedule_scroll (START_DELAY);
            }
        });
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
        return get_allocated_width () > 0 && text_width () > get_allocated_width ();
    }

    private static bool animations_enabled () {
        return Gtk.Settings.get_default ().gtk_enable_animations;
    }

    /* Show one lyric line; long lines pan across `duration_ms` */
    public void show_line (string line, uint duration_ms) {
        bool entering = !pan_mode;
        pan_duration = duration_ms;
        if (line == _text && !entering) {
            return;
        }

        pan_mode = true;
        _text = line;
        layout = null;
        stop_scroll ();
        if (entering) {
            queue_resize ();
        }
        queue_draw ();

        cancel_delay ();
        delay_id = Timeout.add (PAN_DELAY, () => {
            delay_id = 0;
            start_pan ();
            return Source.REMOVE;
        });
    }

    private void start_pan () {
        if (tick_id != 0 || !get_mapped () || !overflows () || !animations_enabled ()) {
            return;
        }

        double travel_ms = double.max (pan_duration - PAN_DELAY - 400.0, 800.0);
        scroll_started = 0;
        tick_id = add_tick_callback ((widget, clock) => {
            int64 now = clock.get_frame_time ();
            if (scroll_started == 0) {
                scroll_started = now;
            }
            double max_offset = text_width () - get_allocated_width ();
            double t = ((now - scroll_started) / 1000.0 / travel_ms).clamp (0, 1);
            /* gentle ease in/out */
            offset = max_offset * (t * t * (3 - 2 * t));
            queue_draw ();
            if (t >= 1) {
                tick_id = 0;
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
    }

    public override void get_preferred_width (out int minimum, out int natural) {
        if (pan_mode) {
            /* fixed width so the panel doesn't jump with every line */
            minimum = natural = max_width;
            return;
        }
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

    private void cancel_delay () {
        if (delay_id != 0) {
            Source.remove (delay_id);
            delay_id = 0;
        }
    }

    private void schedule_scroll (uint delay) {
        cancel_delay ();
        delay_id = Timeout.add (delay, () => {
            delay_id = 0;
            start_scroll ();
            return Source.REMOVE;
        });
    }

    public void start_scroll () {
        if (pan_mode || tick_id != 0 || !get_mapped () || !overflows () || !animations_enabled ()) {
            return;
        }

        cancel_delay ();
        scroll_started = 0;
        tick_id = add_tick_callback ((widget, clock) => {
            int64 now = clock.get_frame_time ();
            if (scroll_started == 0) {
                scroll_started = now;
            }

            double distance = text_width () + GAP;
            offset = (now - scroll_started) / 1000000.0 * SPEED;

            if (offset >= distance) {
                /* Lap finished: the repeated copy is now exactly at the start */
                offset = 0;
                tick_id = 0;
                queue_draw ();
                if (_loop) {
                    schedule_scroll (LAP_PAUSE);
                }
                return Source.REMOVE;
            }

            queue_draw ();
            return Source.CONTINUE;
        });
    }

    private void stop_scroll () {
        cancel_delay ();
        if (tick_id != 0) {
            remove_tick_callback (tick_id);
            tick_id = 0;
        }
        offset = 0;
    }

    public override void map () {
        base.map ();
        if (_loop && !pan_mode) {
            schedule_scroll (START_DELAY);
        }
    }

    public override void unmap () {
        stop_scroll ();
        base.unmap ();
    }

    public override void size_allocate (Gtk.Allocation allocation) {
        base.size_allocate (allocation);
        /* The text may have started (or stopped) overflowing */
        if (_loop && !pan_mode && tick_id == 0 && delay_id == 0 && overflows ()) {
            schedule_scroll (START_DELAY);
        }
    }

    public override bool draw (Cairo.Context cr) {
        ensure_layout ();

        var context = get_style_context ();
        int alloc_w = get_allocated_width ();
        int alloc_h = get_allocated_height ();
        int text_w, text_h;
        layout.get_pixel_size (out text_w, out text_h);
        double y = (alloc_h - text_h) / 2.0;

        if (pan_mode) {
            draw_pan (cr, context, alloc_w, text_w, y);
            return Gdk.EVENT_PROPAGATE;
        }

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

        /* Fade the edges: right edge always, left edge only while moving
         * (eased in and out so it never pops at the start or end of a lap) */
        double distance = text_w + GAP;
        double left = double.min (double.min (offset, distance - offset), FADE) / FADE;
        var mask = new Cairo.Pattern.linear (0, 0, alloc_w, 0);
        double f = (double) FADE / alloc_w;
        mask.add_color_stop_rgba (0, 0, 0, 0, 1 - left.clamp (0, 1));
        mask.add_color_stop_rgba (f, 0, 0, 0, 1);
        mask.add_color_stop_rgba (1 - f, 0, 0, 0, 1);
        mask.add_color_stop_rgba (1, 0, 0, 0, 0);
        cr.mask (mask);

        return Gdk.EVENT_PROPAGATE;
    }

    private void draw_pan (Cairo.Context cr, Gtk.StyleContext context, int alloc_w, int text_w, double y) {
        if (text_w <= alloc_w) {
            context.render_layout (cr, (alloc_w - text_w) / 2.0, y, layout);
            return;
        }

        cr.push_group ();
        context.render_layout (cr, -offset, y, layout);
        cr.pop_group_to_source ();

        double remaining = (text_w - alloc_w) - offset;
        double left = double.min (offset, FADE) / FADE;
        double right = double.min (remaining, FADE) / FADE;
        var mask = new Cairo.Pattern.linear (0, 0, alloc_w, 0);
        double f = (double) FADE / alloc_w;
        mask.add_color_stop_rgba (0, 0, 0, 0, 1 - left.clamp (0, 1));
        mask.add_color_stop_rgba (f, 0, 0, 0, 1);
        mask.add_color_stop_rgba (1 - f, 0, 0, 0, 1);
        mask.add_color_stop_rgba (1, 0, 0, 0, 1 - right.clamp (0, 1));
        cr.mask (mask);
    }
}
