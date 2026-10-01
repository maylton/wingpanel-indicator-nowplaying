/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Preferences page shown inside the popover.
 */

public class NowPlaying.SettingsView : Gtk.Grid {
    public signal void back ();

    construct {
        orientation = Gtk.Orientation.VERTICAL;
        margin_bottom = 6;

        var prefs = Preferences.get_default ();

        /* Back row, like other elementary popover sub-pages */
        var back_label = new Gtk.Label (_("Preferences")) {
            xalign = 0
        };
        back_label.get_style_context ().add_class ("nowplaying-settings-title");
        var back_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        back_box.add (new Gtk.Image.from_icon_name ("go-previous-symbolic", Gtk.IconSize.BUTTON));
        back_box.add (back_label);

        var back_button = new Gtk.Button () {
            margin_top = 3,
            margin_bottom = 3
        };
        back_button.add (back_box);
        back_button.get_style_context ().add_class (Gtk.STYLE_CLASS_MENUITEM);
        back_button.get_style_context ().add_class (Gtk.STYLE_CLASS_FLAT);
        back_button.clicked.connect (() => back ());

        /* Panel text width */
        var width_label = new Gtk.Label (_("Panel text width")) {
            xalign = 0,
            margin_start = 12,
            margin_end = 12,
            margin_top = 6
        };
        var width_scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 80, 400, 10) {
            draw_value = true,
            value_pos = Gtk.PositionType.RIGHT,
            digits = 0,
            margin_start = 12,
            margin_end = 12,
            hexpand = true
        };
        width_scale.format_value.connect ((v) => "%d px".printf ((int) v));
        width_scale.add_mark (200, Gtk.PositionType.BOTTOM, null);
        prefs.bind_property (
            "panel-width", width_scale.adjustment, "value",
            BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE
        );

        add (back_button);
        add (new Gtk.Separator (Gtk.Orientation.HORIZONTAL) { margin_bottom = 3 });
        add (width_label);
        add (width_scale);
        add (switch_row (_("Show lyrics in the panel"), prefs, "panel-lyrics"));

        var lyrics_hint = new Gtk.Label (_("Shows the line being sung when synced lyrics are found; otherwise, the song name.")) {
            wrap = true,
            max_width_chars = 30,
            xalign = 0,
            margin_start = 12,
            margin_end = 12,
            margin_top = 3
        };
        lyrics_hint.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
        lyrics_hint.get_style_context ().add_class ("nowplaying-small");
        add (lyrics_hint);

        add (switch_row (_("Show artist in the panel"), prefs, "show-artist"));
        add (switch_row (_("Keep long titles scrolling"), prefs, "scroll-text"));
        add (switch_row (_("Show when nothing is playing"), prefs, "show-when-paused"));

        /* ---- lyrics sources ---- */
        var sources_title = new Gtk.Label (_("Lyrics sources")) {
            xalign = 0,
            margin_start = 12,
            margin_end = 12,
            margin_top = 15
        };
        sources_title.get_style_context ().add_class ("nowplaying-section");
        add (new Gtk.Separator (Gtk.Orientation.HORIZONTAL) { margin_top = 12 });
        add (sources_title);

        add (switch_row ("LRCLIB", prefs, "lyrics-lrclib"));
        add (small_hint (_("Free and open lyrics database.")));
        add (switch_row ("NetEase Cloud Music", prefs, "lyrics-netease"));
        add (small_hint (_("Great for Asian music. Unofficial access: it may stop working at any time.")));
        add (small_hint (_("Lyrics sent by the player and .lrc files (next to the song or in ~/.lyrics) are always used first.")));

        var hint = new Gtk.Label (_("Tip: double-click the cover for the vinyl, triple-click for the lyrics.")) {
            wrap = true,
            max_width_chars = 30,
            xalign = 0,
            margin_start = 12,
            margin_end = 12,
            margin_top = 12
        };
        hint.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
        hint.get_style_context ().add_class ("nowplaying-small");
        add (hint);
    }

    private static Gtk.Widget small_hint (string text) {
        var label = new Gtk.Label (text) {
            wrap = true,
            max_width_chars = 30,
            xalign = 0,
            margin_start = 12,
            margin_end = 12,
            margin_top = 3
        };
        label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
        label.get_style_context ().add_class ("nowplaying-small");
        return label;
    }

    private static Gtk.Widget switch_row (string text, Object target, string property) {
        var label = new Gtk.Label (text) {
            xalign = 0,
            hexpand = true,
            wrap = true,
            max_width_chars = 24
        };
        var toggle = new Gtk.Switch () {
            valign = Gtk.Align.CENTER
        };
        target.bind_property (property, toggle, "active", BindingFlags.BIDIRECTIONAL | BindingFlags.SYNC_CREATE);

        var row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12) {
            margin_start = 12,
            margin_end = 12,
            margin_top = 9
        };
        row.add (label);
        row.add (toggle);
        return row;
    }
}
