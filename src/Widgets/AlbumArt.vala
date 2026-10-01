/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Square album art with rounded corners. Non-square images (e.g. 16:9
 * video thumbnails from YouTube) are center-cropped. Draws a placeholder
 * when there is no art. HiDPI aware.
 */

public class NowPlaying.AlbumArt : Gtk.DrawingArea {
    private const double RADIUS = 8.0;

    public int size { get; construct; }

    private Gdk.Pixbuf? source = null;
    private Gdk.Pixbuf? scaled = null;
    private int scaled_for = 0;

    public AlbumArt (int size) {
        Object (size: size);
    }

    construct {
        set_size_request (size, size);
        halign = Gtk.Align.CENTER;
        valign = Gtk.Align.CENTER;
        get_style_context ().add_class ("nowplaying-art");
    }

    public void set_pixbuf (Gdk.Pixbuf? pixbuf) {
        source = pixbuf;
        scaled = null;
        queue_draw ();
    }

    private void ensure_scaled (int px) {
        if (source == null || (scaled != null && scaled_for == px)) {
            return;
        }

        int w = source.width;
        int h = source.height;
        int side = int.min (w, h);
        var square = new Gdk.Pixbuf.subpixbuf (source, (w - side) / 2, (h - side) / 2, side, side);
        scaled = square.scale_simple (px, px, Gdk.InterpType.BILINEAR);
        scaled_for = px;
    }

    private static void rounded_rect (Cairo.Context cr, double x, double y, double w, double h, double r) {
        cr.new_sub_path ();
        cr.arc (x + w - r, y + r, r, -Math.PI / 2, 0);
        cr.arc (x + w - r, y + h - r, r, 0, Math.PI / 2);
        cr.arc (x + r, y + h - r, r, Math.PI / 2, Math.PI);
        cr.arc (x + r, y + r, r, Math.PI, 3 * Math.PI / 2);
        cr.close_path ();
    }

    public override bool draw (Cairo.Context cr) {
        int w = get_allocated_width ();
        int h = get_allocated_height ();
        int side = int.min (w, h);
        double x = (w - side) / 2.0;
        double y = (h - side) / 2.0;

        var context = get_style_context ();
        var fg = context.get_color (context.get_state ());

        cr.save ();
        rounded_rect (cr, x, y, side, side, RADIUS);
        cr.clip ();

        if (source != null) {
            int scale = get_scale_factor ();
            ensure_scaled (side * scale);
            cr.translate (x, y);
            cr.scale (1.0 / scale, 1.0 / scale);
            Gdk.cairo_set_source_pixbuf (cr, scaled, 0, 0);
            cr.paint ();
        } else {
            /* Placeholder: subtle tile with a music note */
            cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.08);
            cr.paint ();

            int icon_size = side / 3;
            try {
                var info = Gtk.IconTheme.get_default ().lookup_icon_for_scale (
                    "audio-x-generic-symbolic", icon_size, get_scale_factor (), Gtk.IconLookupFlags.FORCE_SIZE
                );
                if (info != null) {
                    bool was_symbolic;
                    var icon = info.load_symbolic_for_context (context, out was_symbolic);
                    int scale = get_scale_factor ();
                    cr.translate (x + (side - icon_size) / 2.0, y + (side - icon_size) / 2.0);
                    cr.scale (1.0 / scale, 1.0 / scale);
                    cr.push_group ();
                    Gdk.cairo_set_source_pixbuf (cr, icon, 0, 0);
                    cr.paint ();
                    cr.pop_group_to_source ();
                    cr.paint_with_alpha (0.35);
                }
            } catch (Error e) {
                debug ("Placeholder icon: %s", e.message);
            }
        }

        cr.restore ();

        /* Hairline border so light covers don't melt into the popover */
        rounded_rect (cr, x + 0.5, y + 0.5, side - 1, side - 1, RADIUS);
        cr.set_source_rgba (fg.red, fg.green, fg.blue, 0.12);
        cr.set_line_width (1);
        cr.stroke ();

        return Gdk.EVENT_PROPAGATE;
    }
}
