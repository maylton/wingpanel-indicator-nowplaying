/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Popover page for one player: app header, album art, track info,
 * seek bar and transport controls.
 */

public class NowPlaying.PlayerView : Gtk.Grid {
    private const int ART_SIZE = 256;

    public Player player { get; construct; }

    /* Asks the indicator to close the popover */
    public signal void request_close ();

    private AlbumArt art;
    private Gtk.Label title_label;
    private Gtk.Label artist_label;
    private Gtk.Label album_label;
    private Gtk.Scale seek_scale;
    private Gtk.Label elapsed_label;
    private Gtk.Label total_label;
    private Gtk.Box seek_box;
    private Gtk.ToggleButton shuffle_button;
    private Gtk.Button previous_button;
    private Gtk.Button play_button;
    private Gtk.Image play_image;
    private Gtk.Button next_button;
    private Gtk.ToggleButton repeat_button;
    private Gtk.Image repeat_image;

    private bool updating = false;
    private bool active = false;
    private uint poll_id = 0;
    private uint seek_id = 0;
    private double pending_seek = -1;
    private string current_art_url = "";

    public PlayerView (Player player) {
        Object (player: player);
    }

    construct {
        orientation = Gtk.Orientation.VERTICAL;
        row_spacing = 0;
        margin_bottom = 6;
        get_style_context ().add_class ("nowplaying-view");

        /* App header: clicking it brings the player window forward */
        var app_icon = new Gtk.Image () {
            pixel_size = 16
        };
        var app_label = new Gtk.Label (null) {
            ellipsize = Pango.EllipsizeMode.END,
            xalign = 0
        };
        var header_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        header_box.add (app_icon);
        header_box.add (app_label);

        var header_button = new Gtk.Button () {
            margin_top = 3,
            margin_bottom = 3
        };
        header_button.add (header_box);
        header_button.get_style_context ().add_class (Gtk.STYLE_CLASS_MENUITEM);
        header_button.get_style_context ().add_class (Gtk.STYLE_CLASS_FLAT);
        header_button.clicked.connect (() => {
            player.raise_window ();
            request_close ();
        });

        player.bind_property ("icon", app_icon, "gicon", BindingFlags.SYNC_CREATE);
        player.bind_property ("identity", app_label, "label", BindingFlags.SYNC_CREATE);
        player.bind_property ("can-raise", header_button, "sensitive", BindingFlags.SYNC_CREATE);

        art = new AlbumArt (ART_SIZE) {
            margin_start = 12,
            margin_end = 12,
            margin_top = 6
        };

        title_label = new Gtk.Label (null) {
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 28,
            margin_top = 12,
            margin_start = 12,
            margin_end = 12,
            selectable = false
        };
        title_label.get_style_context ().add_class ("nowplaying-title");

        artist_label = new Gtk.Label (null) {
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 32,
            margin_start = 12,
            margin_end = 12
        };
        artist_label.get_style_context ().add_class ("nowplaying-artist");

        album_label = new Gtk.Label (null) {
            ellipsize = Pango.EllipsizeMode.END,
            max_width_chars = 32,
            margin_start = 12,
            margin_end = 12
        };
        album_label.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
        album_label.get_style_context ().add_class ("nowplaying-small");

        /* Seek bar */
        seek_scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 0, 1, 1) {
            draw_value = false,
            hexpand = true
        };
        seek_scale.change_value.connect (on_user_seek);

        elapsed_label = new Gtk.Label ("0:00") {
            width_chars = 5,
            xalign = 0
        };
        total_label = new Gtk.Label ("0:00") {
            width_chars = 5,
            xalign = 1
        };
        foreach (var l in new Gtk.Label[] { elapsed_label, total_label }) {
            l.get_style_context ().add_class (Gtk.STYLE_CLASS_DIM_LABEL);
            l.get_style_context ().add_class ("nowplaying-time");
        }

        seek_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            margin_start = 12,
            margin_end = 12,
            margin_top = 6
        };
        seek_box.add (elapsed_label);
        seek_box.add (seek_scale);
        seek_box.add (total_label);
        seek_box.show_all ();

        /* Transport controls */
        shuffle_button = new Gtk.ToggleButton () {
            tooltip_text = _("Shuffle"),
            image = new Gtk.Image.from_icon_name ("media-playlist-shuffle-symbolic", Gtk.IconSize.BUTTON)
        };
        shuffle_button.toggled.connect (() => {
            if (!updating) {
                player.request_shuffle (shuffle_button.active);
            }
        });

        previous_button = new Gtk.Button.from_icon_name ("media-skip-backward-symbolic", Gtk.IconSize.LARGE_TOOLBAR) {
            tooltip_text = _("Previous")
        };
        previous_button.clicked.connect (() => player.previous ());

        play_image = new Gtk.Image () {
            pixel_size = 32
        };
        play_button = new Gtk.Button () {
            image = play_image
        };
        play_button.get_style_context ().add_class ("nowplaying-play");
        play_button.clicked.connect (() => player.play_pause ());

        next_button = new Gtk.Button.from_icon_name ("media-skip-forward-symbolic", Gtk.IconSize.LARGE_TOOLBAR) {
            tooltip_text = _("Next")
        };
        next_button.clicked.connect (() => player.next ());

        repeat_image = new Gtk.Image () {
            icon_size = Gtk.IconSize.BUTTON
        };
        repeat_button = new Gtk.ToggleButton () {
            image = repeat_image
        };
        repeat_button.toggled.connect (() => {
            if (!updating) {
                player.request_loop_status (player.loop_status.next ());
                /* Keep showing the real state until the player confirms */
                update_state ();
            }
        });

        var controls = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6) {
            halign = Gtk.Align.CENTER,
            margin_top = 6,
            margin_start = 12,
            margin_end = 12
        };
        foreach (var b in new Gtk.Button[] { shuffle_button, previous_button, play_button, next_button, repeat_button }) {
            b.get_style_context ().add_class (Gtk.STYLE_CLASS_FLAT);
            b.valign = Gtk.Align.CENTER;
            b.can_focus = false;
            controls.add (b);
        }
        shuffle_button.get_style_context ().add_class ("nowplaying-toggle");
        repeat_button.get_style_context ().add_class ("nowplaying-toggle");
        shuffle_button.margin_end = 6;
        repeat_button.margin_start = 6;

        /* Widgets whose visibility depends on what the player supports */
        foreach (var w in new Gtk.Widget[] { artist_label, album_label, seek_box, shuffle_button, repeat_button }) {
            w.no_show_all = true;
        }
        shuffle_button.image.show ();
        repeat_image.show ();

        add (header_button);
        add (art);
        add (title_label);
        add (artist_label);
        add (album_label);
        add (seek_box);
        add (controls);

        player.metadata_changed.connect (update_metadata);
        player.state_changed.connect (update_state);
        player.seeked.connect (on_seeked);

        update_metadata ();
        update_state ();
    }

    /* Drop every link to the player so neither object keeps the other alive */
    public void teardown () {
        player.metadata_changed.disconnect (update_metadata);
        player.state_changed.disconnect (update_state);
        player.seeked.disconnect (on_seeked);
        active = false;
        update_polling ();
        if (seek_id != 0) {
            Source.remove (seek_id);
            seek_id = 0;
        }
    }

    private void on_seeked (int64 pos) {
        if (pending_seek < 0) {
            set_position_ui (pos);
        }
    }

    /* Called by the indicator when this page becomes visible / hidden */
    public void set_active (bool value) {
        active = value;
        update_polling ();
        if (active) {
            refresh_position ();
        }
    }

    private void update_polling () {
        bool should_poll = active && player.is_playing && player.length > 0;

        if (should_poll && poll_id == 0) {
            poll_id = Timeout.add (500, () => {
                refresh_position ();
                return Source.CONTINUE;
            });
        } else if (!should_poll && poll_id != 0) {
            Source.remove (poll_id);
            poll_id = 0;
        }
    }

    private void refresh_position () {
        if (player.length <= 0 || pending_seek >= 0) {
            return;
        }
        player.query_position.begin ((obj, res) => {
            var pos = player.query_position.end (res);
            if (pending_seek < 0) {
                set_position_ui (pos);
            }
        });
    }

    private void set_position_ui (int64 pos) {
        updating = true;
        seek_scale.set_value (pos / 1000000.0);
        updating = false;
        elapsed_label.label = format_time (pos);
    }

    private bool on_user_seek (Gtk.ScrollType scroll, double value) {
        if (updating) {
            return false;
        }

        double max = player.length / 1000000.0;
        pending_seek = value.clamp (0, max);
        elapsed_label.label = format_time ((int64) (pending_seek * 1000000));

        /* Debounce while the slider is being dragged */
        if (seek_id != 0) {
            Source.remove (seek_id);
        }
        seek_id = Timeout.add (180, () => {
            seek_id = 0;
            player.seek_to ((int64) (pending_seek * 1000000));
            pending_seek = -1;
            return Source.REMOVE;
        });

        return false;
    }

    private static string format_time (int64 usec) {
        int64 total = int64.max (usec / 1000000, 0);
        int64 hours = total / 3600;
        int64 minutes = (total % 3600) / 60;
        int64 seconds = total % 60;
        if (hours > 0) {
            return "%lld:%02lld:%02lld".printf (hours, minutes, seconds);
        }
        return "%lld:%02lld".printf (minutes, seconds);
    }

    private void update_metadata () {
        title_label.label = player.title != "" ? player.title : player.identity;
        artist_label.label = player.artist;
        artist_label.visible = player.artist != "";
        album_label.label = player.album;
        album_label.visible = player.album != "";
        title_label.tooltip_text = player.title != "" ? player.title : null;

        if (player.length > 0) {
            updating = true;
            seek_scale.set_range (0, player.length / 1000000.0);
            updating = false;
            total_label.label = format_time (player.length);
            set_position_ui (player.position);
        }

        if (player.art_url != current_art_url) {
            current_art_url = player.art_url;
            if (current_art_url == "") {
                art.set_pixbuf (null);
            } else {
                var requested = current_art_url;
                ArtLoader.get_default ().load.begin (requested, (obj, res) => {
                    var pixbuf = ArtLoader.get_default ().load.end (res);
                    /* Ignore late answers for a previous track */
                    if (requested == current_art_url) {
                        art.set_pixbuf (pixbuf);
                    }
                });
            }
        }

        update_state ();
    }

    private void update_state () {
        updating = true;

        play_image.icon_name = player.is_playing ? "media-playback-pause-symbolic" : "media-playback-start-symbolic";
        play_button.tooltip_text = player.is_playing ? _("Pause") : _("Play");
        play_button.sensitive = player.is_playing ? player.can_pause : player.can_play;
        previous_button.sensitive = player.can_go_previous;
        next_button.sensitive = player.can_go_next;

        shuffle_button.visible = player.has_shuffle;
        shuffle_button.active = player.shuffle;

        repeat_button.visible = player.has_loop_status;
        repeat_button.active = player.loop_status != LoopStatus.NONE;
        switch (player.loop_status) {
            case LoopStatus.TRACK:
                repeat_image.gicon = new ThemedIcon.from_names ({
                    "media-playlist-repeat-song-symbolic", "media-playlist-repeat-symbolic"
                });
                repeat_button.tooltip_text = _("Repeat: current track");
                break;
            case LoopStatus.PLAYLIST:
                repeat_image.gicon = new ThemedIcon ("media-playlist-repeat-symbolic");
                repeat_button.tooltip_text = _("Repeat: all");
                break;
            default:
                repeat_image.gicon = new ThemedIcon ("media-playlist-repeat-symbolic");
                repeat_button.tooltip_text = _("Repeat: off");
                break;
        }

        bool show_seek = player.length > 0;
        seek_box.visible = show_seek;
        seek_scale.sensitive = player.can_seek;

        updating = false;

        update_polling ();
    }
}
