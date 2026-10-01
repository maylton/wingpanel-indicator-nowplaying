/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Time-synced lyrics: the current line is highlighted and smoothly kept
 * in the middle. Clicking a line seeks to it. Scrolling by hand pauses
 * the automatic scrolling for a few seconds.
 */

public class NowPlaying.LyricsView : Gtk.Stack {
    private const int64 LEAD = 200000;          /* show a line 0.2s early */
    private const int64 MANUAL_HOLD = 4000000;  /* 4s after a manual scroll */
    private const double SCROLL_MS = 450.0;

    public int size { get; construct; }

    public signal void seek_requested (int64 time);

    private Gtk.Spinner spinner;
    private Gtk.Label message_label;
    private Gtk.ScrolledWindow scroller;
    private Gtk.Box lines_box;
    private Gtk.Label source_label;

    private Lyrics? lyrics = null;
    private Gtk.Label[] rows = {};
    private int current = -1;

    private uint scroll_tick = 0;
    private double scroll_from = 0;
    private double scroll_to = 0;
    private int64 scroll_start = 0;
    private int64 manual_scroll_at = 0;

    public LyricsView (int size) {
        Object (size: size);
    }

    construct {
        set_size_request (size, size);
        halign = Gtk.Align.CENTER;
        transition_type = Gtk.StackTransitionType.CROSSFADE;
        get_style_context ().add_class ("nowplaying-lyrics");

        /* loading */
        spinner = new Gtk.Spinner () {
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER
        };
        add_named (spinner, "loading");

        /* message (not found, instrumental, offline) */
        message_label = new Gtk.Label (null) {
            wrap = true,
            justify = Gtk.Justification.CENTER,
            max_width_chars = 24,
            halign = Gtk.Align.CENTER,
            valign = Gtk.Align.CENTER,
            margin = 12
        };
        message_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
        add_named (message_label, "message");

        /* lyrics */
        lines_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 10) {
            margin_start = 12,
            margin_end = 12,
            /* lets the first and last lines reach the middle */
            margin_top = size / 2 - 12,
            margin_bottom = size / 2 - 12
        };

        scroller = new Gtk.ScrolledWindow (null, null) {
            hscrollbar_policy = Gtk.PolicyType.NEVER,
            vscrollbar_policy = Gtk.PolicyType.EXTERNAL
        };
        scroller.add (lines_box);
        scroller.add_events (Gdk.EventMask.SCROLL_MASK | Gdk.EventMask.SMOOTH_SCROLL_MASK);
        scroller.scroll_event.connect ((event) => {
            manual_scroll_at = get_monotonic_time ();
            stop_scroll_animation ();
            /* EXTERNAL policy ignores the wheel, so scroll by hand */
            var adj = scroller.vadjustment;
            double dx, dy;
            double delta = 0;
            if (event.get_scroll_deltas (out dx, out dy)) {
                delta = dy * 40;
            } else if (event.direction == Gdk.ScrollDirection.UP) {
                delta = -40;
            } else if (event.direction == Gdk.ScrollDirection.DOWN) {
                delta = 40;
            }
            adj.value = (adj.value + delta).clamp (adj.lower, adj.upper - adj.page_size);
            return Gdk.EVENT_STOP;
        });
        /* small caption saying where the lyrics came from */
        source_label = new Gtk.Label (null) {
            halign = Gtk.Align.END,
            valign = Gtk.Align.END,
            margin = 6
        };
        source_label.get_style_context ().add_class ("nowplaying-lyrics-source");

        var overlay = new Gtk.Overlay ();
        overlay.add (scroller);
        overlay.add_overlay (source_label);
        overlay.set_overlay_pass_through (source_label, true);
        add_named (overlay, "lyrics");

        /* The first centering may run before the lines are laid out:
         * re-center once their real size is known */
        scroller.vadjustment.changed.connect (() => {
            if (lyrics != null && lyrics.synced) {
                stop_scroll_animation ();
                center_current (false);
            }
        });
    }

    public void show_loading () {
        lyrics = null;
        spinner.start ();
        visible_child_name = "loading";
    }

    public void show_message (string text) {
        lyrics = null;
        spinner.stop ();
        message_label.label = text;
        visible_child_name = "message";
    }

    public void set_lyrics (Lyrics? value) {
        spinner.stop ();

        if (value == null || value.is_empty ()) {
            show_message (_("No lyrics found for this song"));
            return;
        }

        if (value.instrumental && value.lines.length == 0 && value.plain.strip () == "") {
            show_message (_("♪ Instrumental ♪"));
            return;
        }

        lyrics = value;
        current = -1;
        rows = {};
        foreach (var child in lines_box.get_children ()) {
            child.destroy ();
        }

        if (value.synced) {
            for (int i = 0; i < value.lines.length; i++) {
                var line = value.lines[i];
                var label = make_row (line.text != "" ? line.text : "♪");
                var time = line.time;

                var event_box = new Gtk.EventBox ();
                event_box.add (label);
                event_box.button_press_event.connect ((event) => {
                    if (event.button == Gdk.BUTTON_PRIMARY && event.type == Gdk.EventType.BUTTON_PRESS) {
                        manual_scroll_at = 0;
                        seek_requested (time);
                        return Gdk.EVENT_STOP;
                    }
                    return Gdk.EVENT_PROPAGATE;
                });
                lines_box.add (event_box);
                rows += label;
            }
        } else {
            /* Unsynced: plain text, readable from the top */
            var label = make_row (value.plain.strip ());
            label.get_style_context ().add_class ("nowplaying-lyric-plain");
            lines_box.add (label);
        }

        lines_box.margin_top = value.synced ? size / 2 - 12 : 12;
        lines_box.margin_bottom = value.synced ? size / 2 - 12 : 12;
        source_label.label = value.source;
        source_label.visible = value.source != "";
        source_label.no_show_all = true;
        lines_box.show_all ();
        scroller.vadjustment.value = 0;
        visible_child_name = "lyrics";
    }

    private Gtk.Label make_row (string text) {
        var label = new Gtk.Label (text) {
            wrap = true,
            wrap_mode = Pango.WrapMode.WORD_CHAR,
            justify = Gtk.Justification.CENTER,
            max_width_chars = 26,
            xalign = 0.5f
        };
        label.get_style_context ().add_class ("nowplaying-lyric");
        return label;
    }

    /* Called often (≈10×/s) with the interpolated playback position */
    public void update_position (int64 position) {
        if (lyrics == null || !lyrics.synced || rows.length == 0) {
            return;
        }

        int index = lyrics.index_at (position + LEAD);
        if (index == current) {
            return;
        }

        if (current >= 0 && current < rows.length) {
            rows[current].get_style_context ().remove_class ("nowplaying-lyric-active");
        }
        current = index;

        if (current >= 0) {
            rows[current].get_style_context ().add_class ("nowplaying-lyric-active");
        }

        /* Wait for the new style (bold) to be laid out before centering */
        Idle.add (() => {
            center_current (true);
            return Source.REMOVE;
        });
    }

    private void center_current (bool animate) {
        if (get_monotonic_time () - manual_scroll_at < MANUAL_HOLD) {
            return;
        }

        var adj = scroller.vadjustment;
        double target;
        if (current < 0 || current >= rows.length) {
            target = 0;
        } else {
            Gtk.Allocation alloc;
            rows[current].get_parent ().get_allocation (out alloc);
            int y;
            rows[current].get_parent ().translate_coordinates (lines_box, 0, 0, null, out y);
            target = lines_box.margin_top + y + alloc.height / 2.0 - adj.page_size / 2.0;
        }
        target = target.clamp (adj.lower, double.max (adj.lower, adj.upper - adj.page_size));

        if (!animate || !get_mapped () || !Gtk.Settings.get_default ().gtk_enable_animations) {
            adj.value = target;
            return;
        }

        scroll_from = adj.value;
        scroll_to = target;
        scroll_start = 0;
        if (scroll_tick == 0) {
            scroll_tick = add_tick_callback ((widget, clock) => {
                int64 now = clock.get_frame_time ();
                if (scroll_start == 0) {
                    scroll_start = now;
                }
                double t = ((now - scroll_start) / 1000.0 / SCROLL_MS).clamp (0, 1);
                double eased = 1 - Math.pow (1 - t, 3);  /* ease-out cubic */
                scroller.vadjustment.value = scroll_from + (scroll_to - scroll_from) * eased;
                if (t >= 1) {
                    scroll_tick = 0;
                    return Source.REMOVE;
                }
                return Source.CONTINUE;
            });
        }
    }

    private void stop_scroll_animation () {
        if (scroll_tick != 0) {
            remove_tick_callback (scroll_tick);
            scroll_tick = 0;
        }
    }

    public override void unmap () {
        stop_scroll_animation ();
        base.unmap ();
    }
}
