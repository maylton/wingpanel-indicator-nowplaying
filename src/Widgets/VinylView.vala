/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * A spinning vinyl record with the album art as its centre label and a
 * tonearm. The record spins up / slows down like a real turntable
 * (33⅓ rpm), the arm lowers onto the record when playback starts, lifts
 * when it pauses, and slowly travels inwards as the song progresses.
 *
 * Everything is drawn in a 256×256 design space and scaled to fit.
 */

public class NowPlaying.VinylView : Gtk.DrawingArea {
    private const double DESIGN = 256.0;

    /* geometry (design units) */
    private const double CX = 118.0;           /* record centre */
    private const double CY = 130.0;
    private const double RECORD_R = 112.0;
    private const double LABEL_R = 38.0;
    private const double GROOVE_OUT = 100.0;   /* where the needle drops */
    private const double GROOVE_IN = 50.0;     /* end of the last track */
    private const double PIVOT_X = 232.0;      /* tonearm pivot */
    private const double PIVOT_Y = 28.0;
    private const double ARM_LEN = 150.0;
    private const double ARM_REST = 84.0;      /* degrees; arm parked beside the record */

    private const double RPM = 100.0 / 3.0;    /* 33⅓ */

    public int size { get; construct; }

    private bool _playing = false;
    public bool playing {
        get { return _playing; }
        set {
            _playing = value;
            ensure_ticking ();
        }
    }

    private double _progress = 0;
    /* 0 → 1 across the song, moves the arm inwards */
    public double progress {
        get { return _progress; }
        set {
            _progress = value.clamp (0, 1);
            ensure_ticking ();
        }
    }

    private Gdk.Pixbuf? source = null;
    private Gdk.Pixbuf? label_scaled = null;
    private int label_px = 0;

    private double angle = 0;       /* radians */
    private double speed = 0;       /* radians per second */
    private double arm = 0;         /* 0 = parked, 1 = on the record */
    private double arm_progress = 0;
    private uint tick_id = 0;
    private int64 last_frame = 0;

    public VinylView (int size) {
        Object (size: size);
    }

    construct {
        set_size_request (size, size);
        halign = Gtk.Align.CENTER;
        valign = Gtk.Align.CENTER;
    }

    public void set_pixbuf (Gdk.Pixbuf? pixbuf) {
        source = pixbuf;
        label_scaled = null;
        queue_draw ();
    }

    public override void map () {
        base.map ();
        /* Jump straight to the right state when shown */
        arm = _playing ? 1 : 0;
        arm_progress = _progress;
        speed = _playing ? target_speed () : 0;
        ensure_ticking ();
    }

    public override void unmap () {
        if (tick_id != 0) {
            remove_tick_callback (tick_id);
            tick_id = 0;
        }
        base.unmap ();
    }

    private double target_speed () {
        return _playing ? RPM / 60.0 * 2 * Math.PI : 0;
    }

    private void ensure_ticking () {
        if (tick_id != 0 || !get_mapped ()) {
            queue_draw ();
            return;
        }

        if (!Gtk.Settings.get_default ().gtk_enable_animations) {
            arm = _playing ? 1 : 0;
            arm_progress = _progress;
            queue_draw ();
            return;
        }

        last_frame = 0;
        tick_id = add_tick_callback ((widget, clock) => {
            int64 now = clock.get_frame_time ();
            double dt = last_frame == 0 ? 0 : (now - last_frame) / 1000000.0;
            last_frame = now;
            dt = double.min (dt, 0.1);

            /* motor: ~1s to spin up, ~1.5s to coast down */
            double target = target_speed ();
            double rate = target > speed ? 3.0 : 2.0;
            speed += (target - speed) * double.min (1, dt * rate);
            if (!_playing && speed < 0.02) {
                speed = 0;
            }
            angle = Math.fmod (angle + speed * dt, 2 * Math.PI);

            /* tonearm: lift/lower and follow the song */
            double arm_target = _playing ? 1 : 0;
            arm += (arm_target - arm) * double.min (1, dt * 3.5);
            arm_progress += (_progress - arm_progress) * double.min (1, dt * 2);

            queue_draw ();

            bool settled = speed == 0 && (arm - arm_target).abs () < 0.002 &&
                (arm_progress - _progress).abs () < 0.001;
            if (settled && !_playing) {
                arm = arm_target;
                tick_id = 0;
                return Source.REMOVE;
            }
            return Source.CONTINUE;
        });
    }

    /* ---------- drawing ---------- */

    private void ensure_label (int px) {
        if (source == null || (label_scaled != null && label_px == px)) {
            return;
        }
        int w = source.width;
        int h = source.height;
        int side = int.min (w, h);
        var square = new Gdk.Pixbuf.subpixbuf (source, (w - side) / 2, (h - side) / 2, side, side);
        label_scaled = square.scale_simple (px, px, Gdk.InterpType.BILINEAR);
        label_px = px;
    }

    /* Angle (degrees) of the arm so the needle sits at radius r from the centre */
    private static double arm_angle_for_radius (double r) {
        double dx = CX - PIVOT_X;
        double dy = CY - PIVOT_Y;
        double d = Math.sqrt (dx * dx + dy * dy);
        double to_centre = Math.atan2 (dy, dx) * 180 / Math.PI;
        double cos_a = ((ARM_LEN * ARM_LEN + d * d - r * r) / (2 * ARM_LEN * d)).clamp (-1, 1);
        return to_centre - Math.acos (cos_a) * 180 / Math.PI;
    }

    private static double ease (double t) {
        return t * t * (3 - 2 * t);  /* smoothstep */
    }

    public override bool draw (Cairo.Context cr) {
        int w = get_allocated_width ();
        int h = get_allocated_height ();
        double side = int.min (w, h);
        double k = side / DESIGN;

        cr.save ();
        cr.translate ((w - side) / 2.0, (h - side) / 2.0);
        cr.scale (k, k);

        draw_record (cr);
        draw_label (cr, k);
        draw_arm (cr);

        cr.restore ();
        return Gdk.EVENT_PROPAGATE;
    }

    private void draw_record (Cairo.Context cr) {
        /* soft drop shadow */
        var shadow = new Cairo.Pattern.radial (CX, CY + 3, RECORD_R - 6, CX, CY + 3, RECORD_R + 6);
        shadow.add_color_stop_rgba (0, 0, 0, 0, 0.35);
        shadow.add_color_stop_rgba (1, 0, 0, 0, 0);
        cr.set_source (shadow);
        cr.arc (CX, CY + 3, RECORD_R + 6, 0, 2 * Math.PI);
        cr.fill ();

        /* vinyl body */
        var body = new Cairo.Pattern.radial (CX, CY, LABEL_R, CX, CY, RECORD_R);
        body.add_color_stop_rgb (0, 0.09, 0.09, 0.10);
        body.add_color_stop_rgb (1, 0.04, 0.04, 0.05);
        cr.set_source (body);
        cr.arc (CX, CY, RECORD_R, 0, 2 * Math.PI);
        cr.fill ();

        /* grooves, with a few wider gaps between "tracks" */
        cr.set_line_width (0.6);
        for (double r = GROOVE_IN - 4; r <= GROOVE_OUT + 2; r += 2.2) {
            cr.arc (CX, CY, r, 0, 2 * Math.PI);
            cr.set_source_rgba (1, 1, 1, 0.035);
            cr.stroke ();
        }
        foreach (double gap in new double[] { 63.0, 78.0, 93.0 }) {
            cr.set_line_width (1.6);
            cr.arc (CX, CY, gap, 0, 2 * Math.PI);
            cr.set_source_rgba (0, 0, 0, 0.6);
            cr.stroke ();
        }

        /* light sheen (fixed, like a lamp reflecting on the record) */
        cr.save ();
        cr.arc (CX, CY, RECORD_R, 0, 2 * Math.PI);
        cr.clip ();
        var sheen = new Cairo.Pattern.linear (CX - RECORD_R, CY - RECORD_R, CX + RECORD_R, CY + RECORD_R);
        sheen.add_color_stop_rgba (0.00, 1, 1, 1, 0);
        sheen.add_color_stop_rgba (0.30, 1, 1, 1, 0.10);
        sheen.add_color_stop_rgba (0.42, 1, 1, 1, 0);
        sheen.add_color_stop_rgba (0.58, 1, 1, 1, 0);
        sheen.add_color_stop_rgba (0.70, 1, 1, 1, 0.07);
        sheen.add_color_stop_rgba (1.00, 1, 1, 1, 0);
        cr.set_source (sheen);
        cr.paint ();
        cr.restore ();

        /* rim */
        cr.set_line_width (1);
        cr.arc (CX, CY, RECORD_R - 0.5, 0, 2 * Math.PI);
        cr.set_source_rgba (1, 1, 1, 0.08);
        cr.stroke ();
    }

    private void draw_label (Cairo.Context cr, double k) {
        cr.save ();
        cr.translate (CX, CY);
        cr.rotate (angle);

        cr.arc (0, 0, LABEL_R, 0, 2 * Math.PI);
        cr.clip ();

        if (source != null) {
            int scale = get_scale_factor ();
            int px = (int) Math.ceil (LABEL_R * 2 * k * scale);
            ensure_label (px);
            double s = (LABEL_R * 2) / px;
            cr.translate (-LABEL_R, -LABEL_R);
            cr.scale (s, s);
            Gdk.cairo_set_source_pixbuf (cr, label_scaled, 0, 0);
            cr.paint ();
        } else {
            /* classic red label with a printed ring, so rotation is visible */
            cr.set_source_rgb (0.75, 0.18, 0.16);
            cr.paint ();
            cr.set_line_width (1.2);
            cr.set_source_rgba (1, 1, 1, 0.55);
            cr.arc (0, 0, LABEL_R - 8, -0.6, 1.2);
            cr.stroke ();
            cr.arc (0, 0, LABEL_R - 14, 2.4, 3.6);
            cr.stroke ();
        }
        cr.restore ();

        /* label edge and spindle */
        cr.set_line_width (1);
        cr.arc (CX, CY, LABEL_R, 0, 2 * Math.PI);
        cr.set_source_rgba (0, 0, 0, 0.35);
        cr.stroke ();

        cr.arc (CX, CY, 3.2, 0, 2 * Math.PI);
        cr.set_source_rgb (0.82, 0.82, 0.84);
        cr.fill_preserve ();
        cr.set_source_rgba (0, 0, 0, 0.4);
        cr.set_line_width (0.8);
        cr.stroke ();
    }

    private void draw_arm (Cairo.Context cr) {
        double groove = GROOVE_OUT + (GROOVE_IN - GROOVE_OUT) * arm_progress;
        double on_record = arm_angle_for_radius (groove);
        double deg = ARM_REST + (on_record - ARM_REST) * ease (arm.clamp (0, 1));
        double rad = deg * Math.PI / 180;

        /* when lifted the arm casts a slightly offset shadow */
        double lift = 1 - ease (arm.clamp (0, 1));

        cr.save ();
        cr.translate (PIVOT_X, PIVOT_Y);
        cr.rotate (rad - Math.PI / 2);   /* local +y now points along the arm */

        /* shadow */
        cr.set_line_cap (Cairo.LineCap.ROUND);
        cr.set_line_width (4.5);
        cr.set_source_rgba (0, 0, 0, 0.25);
        cr.move_to (2 + lift * 2, 0);
        cr.line_to (2 + lift * 2, ARM_LEN - 18);
        cr.stroke ();

        /* counterweight */
        rounded_rect (cr, -6.5, -26, 13, 15, 3);
        cr.set_source_rgb (0.30, 0.30, 0.32);
        cr.fill ();

        /* tube */
        var tube = new Cairo.Pattern.linear (-2, 0, 2, 0);
        tube.add_color_stop_rgb (0, 0.62, 0.62, 0.64);
        tube.add_color_stop_rgb (0.5, 0.92, 0.92, 0.94);
        tube.add_color_stop_rgb (1, 0.58, 0.58, 0.60);
        cr.set_source (tube);
        cr.set_line_width (4);
        cr.move_to (0, 0);
        cr.line_to (0, ARM_LEN - 18);
        cr.stroke ();

        /* headshell + cartridge */
        cr.translate (0, ARM_LEN - 18);
        cr.rotate (0.35);
        rounded_rect (cr, -5, -2, 10, 20, 2);
        cr.set_source_rgb (0.20, 0.20, 0.22);
        cr.fill ();
        rounded_rect (cr, -3.5, 12, 7, 6, 1);
        cr.set_source_rgb (0.85, 0.65, 0.20);
        cr.fill ();
        cr.restore ();

        /* pivot base (drawn last, on top) */
        var base_pattern = new Cairo.Pattern.radial (PIVOT_X - 3, PIVOT_Y - 3, 1, PIVOT_X, PIVOT_Y, 13);
        base_pattern.add_color_stop_rgb (0, 0.95, 0.95, 0.96);
        base_pattern.add_color_stop_rgb (1, 0.55, 0.55, 0.58);
        cr.set_source (base_pattern);
        cr.arc (PIVOT_X, PIVOT_Y, 12, 0, 2 * Math.PI);
        cr.fill ();
        cr.arc (PIVOT_X, PIVOT_Y, 4.5, 0, 2 * Math.PI);
        cr.set_source_rgb (0.35, 0.35, 0.38);
        cr.fill ();
    }

    private static void rounded_rect (Cairo.Context cr, double x, double y, double w, double h, double r) {
        cr.new_sub_path ();
        cr.arc (x + w - r, y + r, r, -Math.PI / 2, 0);
        cr.arc (x + w - r, y + h - r, r, 0, Math.PI / 2);
        cr.arc (x + r, y + h - r, r, Math.PI / 2, Math.PI);
        cr.arc (x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
        cr.close_path ();
    }
}
