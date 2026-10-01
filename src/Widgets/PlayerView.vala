/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Popover page for one player: app header, album art (or spinning vinyl,
 * or synced lyrics), track info, seek bar and transport controls.
 *
 * Art modes: buttons in the header, or — like the GNOME extension —
 * double-click the art for the vinyl, triple-click for the lyrics.
 * The chosen mode is remembered per app.
 */

public class NowPlaying.PlayerView : Gtk.Grid {
    private const int ART_SIZE = 256;

    public Player player { get; construct; }

    /* Asks the indicator to close the popover */
    public signal void request_close ();

    private AlbumArt art;
    private VinylView vinyl;
    private LyricsView lyrics_view;
    private Gtk.Stack art_stack;
    private Gtk.ToggleButton vinyl_toggle;
    private Gtk.ToggleButton lyrics_toggle;
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
    private string mode = Preferences.MODE_COVER;
    private uint fast_id = 0;
    private uint click_id = 0;
    private string lyrics_key = "";
    private uint lyrics_request = 0;

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
        header_button.hexpand = true;

        /* Mode toggles: vinyl and lyrics (both off = cover) */
        vinyl_toggle = new Gtk.ToggleButton () {
            tooltip_text = _("Vinyl"),
            image = new Gtk.Image.from_gicon (
                new ThemedIcon.from_names ({ "media-optical-symbolic", "media-optical-cd-audio-symbolic" }),
                Gtk.IconSize.BUTTON
            ),
            valign = Gtk.Align.CENTER,
            can_focus = false
        };
        lyrics_toggle = new Gtk.ToggleButton () {
            tooltip_text = _("Lyrics"),
            image = new Gtk.Image.from_gicon (
                new ThemedIcon.from_names ({ "format-justify-center-symbolic", "view-list-symbolic" }),
                Gtk.IconSize.BUTTON
            ),
            valign = Gtk.Align.CENTER,
            can_focus = false,
            margin_end = 6
        };
        foreach (var t in new Gtk.ToggleButton[] { vinyl_toggle, lyrics_toggle }) {
            t.get_style_context ().add_class (Gtk.STYLE_CLASS_FLAT);
            t.get_style_context ().add_class ("nowplaying-toggle");
        }
        vinyl_toggle.toggled.connect (() => {
            if (!updating) {
                set_mode (vinyl_toggle.active ? Preferences.MODE_VINYL : Preferences.MODE_COVER);
            }
        });
        lyrics_toggle.toggled.connect (() => {
            if (!updating) {
                set_mode (lyrics_toggle.active ? Preferences.MODE_LYRICS : Preferences.MODE_COVER);
            }
        });

        var header_row = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        header_row.add (header_button);
        header_row.add (vinyl_toggle);
        header_row.add (lyrics_toggle);

        art = new AlbumArt (ART_SIZE);
        vinyl = new VinylView (ART_SIZE);
        lyrics_view = new LyricsView (ART_SIZE);
        lyrics_view.seek_requested.connect ((time) => {
            player.seek_to (time);
            lyrics_view.update_position (time);
        });

        art_stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.CROSSFADE,
            transition_duration = 250,
            margin_start = 12,
            margin_end = 12,
            margin_top = 6
        };
        art_stack.add_named (art, Preferences.MODE_COVER);
        art_stack.add_named (vinyl, Preferences.MODE_VINYL);
        art_stack.add_named (lyrics_view, Preferences.MODE_LYRICS);

        /* double-click: vinyl, triple-click: lyrics */
        var art_events = new Gtk.EventBox ();
        art_events.add (art_stack);
        art_events.button_press_event.connect (on_art_press);

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

        add (header_row);
        add (art_events);
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

        /* Stack children must be visible before one can be selected */
        art_stack.show_all ();
        apply_mode (Preferences.get_default ().get_mode (player.app_key), false);
        player.notify["identity"].connect (on_identity_changed);

        var prefs = Preferences.get_default ();
        prefs.notify["lyrics-lrclib"].connect (on_sources_changed);
        prefs.notify["lyrics-netease"].connect (on_sources_changed);
    }

    /* A lyrics source was turned on/off: look again */
    private void on_sources_changed () {
        lyrics_key = "";
        if (active && mode == Preferences.MODE_LYRICS) {
            load_lyrics ();
        }
    }

    private void on_identity_changed () {
        apply_mode (Preferences.get_default ().get_mode (player.app_key), false);
    }

    /* ---------- art modes ---------- */

    private bool on_art_press (Gdk.EventButton event) {
        if (event.button != Gdk.BUTTON_PRIMARY) {
            return Gdk.EVENT_PROPAGATE;
        }

        if (event.type == Gdk.EventType.DOUBLE_BUTTON_PRESS) {
            /* wait a moment: this may become a triple click */
            cancel_click ();
            click_id = Timeout.add (Gtk.Settings.get_default ().gtk_double_click_time, () => {
                click_id = 0;
                set_mode (mode == Preferences.MODE_VINYL ? Preferences.MODE_COVER : Preferences.MODE_VINYL);
                return Source.REMOVE;
            });
            return Gdk.EVENT_STOP;
        }

        if (event.type == Gdk.EventType.TRIPLE_BUTTON_PRESS) {
            cancel_click ();
            set_mode (mode == Preferences.MODE_LYRICS ? Preferences.MODE_COVER : Preferences.MODE_LYRICS);
            return Gdk.EVENT_STOP;
        }

        return Gdk.EVENT_PROPAGATE;
    }

    private void cancel_click () {
        if (click_id != 0) {
            Source.remove (click_id);
            click_id = 0;
        }
    }

    private void set_mode (string new_mode) {
        apply_mode (new_mode, true);
        Preferences.get_default ().set_mode (player.app_key, new_mode);
    }

    private void apply_mode (string new_mode, bool animate) {
        if (new_mode != Preferences.MODE_VINYL && new_mode != Preferences.MODE_LYRICS) {
            new_mode = Preferences.MODE_COVER;
        }
        mode = new_mode;

        updating = true;
        vinyl_toggle.active = mode == Preferences.MODE_VINYL;
        lyrics_toggle.active = mode == Preferences.MODE_LYRICS;
        updating = false;

        art_stack.set_visible_child_full (
            mode, animate ? Gtk.StackTransitionType.CROSSFADE : Gtk.StackTransitionType.NONE
        );

        if (mode == Preferences.MODE_LYRICS) {
            load_lyrics ();
        }
        update_fast_timer ();
        tick_fast ();
    }

    /* ---------- lyrics ---------- */

    private void load_lyrics () {
        var key = "%s\n%s\n%s\n%lld\n%s\n%u".printf (
            player.title, player.artist, player.album, player.length, player.url, player.lyrics_text.hash ()
        );
        if (key == lyrics_key) {
            return;
        }
        lyrics_key = key;

        if (player.title == "") {
            lyrics_view.show_message (_("Nothing is playing"));
            return;
        }

        lyrics_view.show_loading ();
        var request = ++lyrics_request;
        LyricsService.get_default ().fetch.begin (
            new TrackQuery.from_player (player), (obj, res) => {
                var result = LyricsService.get_default ().fetch.end (res);
                if (request != lyrics_request) {
                    return;  /* the song changed meanwhile */
                }
                lyrics_view.set_lyrics (result);
                tick_fast ();
            }
        );
    }

    /* ---------- smooth updates for lyrics and the vinyl arm ---------- */

    private void update_fast_timer () {
        bool needed = active && mode != Preferences.MODE_COVER && player.is_playing;
        if (needed && fast_id == 0) {
            fast_id = Timeout.add (100, () => {
                tick_fast ();
                return Source.CONTINUE;
            });
        } else if (!needed && fast_id != 0) {
            Source.remove (fast_id);
            fast_id = 0;
        }
    }

    private void tick_fast () {
        int64 pos = player.estimate_position ();
        if (mode == Preferences.MODE_LYRICS) {
            lyrics_view.update_position (pos);
        } else if (mode == Preferences.MODE_VINYL) {
            vinyl.progress = player.length > 0 ? (double) pos / player.length : 0;
        }
    }

    /* Drop every link to the player so neither object keeps the other alive */
    public void teardown () {
        player.metadata_changed.disconnect (update_metadata);
        player.state_changed.disconnect (update_state);
        player.seeked.disconnect (on_seeked);
        player.notify["identity"].disconnect (on_identity_changed);
        Preferences.get_default ().notify["lyrics-lrclib"].disconnect (on_sources_changed);
        Preferences.get_default ().notify["lyrics-netease"].disconnect (on_sources_changed);
        active = false;
        update_polling ();
        update_fast_timer ();
        cancel_click ();
        lyrics_request++;
        if (seek_id != 0) {
            Source.remove (seek_id);
            seek_id = 0;
        }
    }

    private void on_seeked (int64 pos) {
        if (pending_seek < 0) {
            set_position_ui (pos);
        }
        tick_fast ();
    }

    /* Called by the indicator when this page becomes visible / hidden */
    public void set_active (bool value) {
        active = value;
        update_polling ();
        update_fast_timer ();
        if (active) {
            refresh_position ();
            if (mode == Preferences.MODE_LYRICS) {
                load_lyrics ();
            }
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
                vinyl.set_pixbuf (null);
            } else {
                var requested = current_art_url;
                ArtLoader.get_default ().load.begin (requested, (obj, res) => {
                    var pixbuf = ArtLoader.get_default ().load.end (res);
                    /* Ignore late answers for a previous track */
                    if (requested == current_art_url) {
                        art.set_pixbuf (pixbuf);
                        vinyl.set_pixbuf (pixbuf);
                    }
                });
            }
        }

        if (mode == Preferences.MODE_LYRICS && active) {
            load_lyrics ();
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

        vinyl.playing = player.is_playing;
        update_polling ();
        update_fast_timer ();
        tick_fast ();
    }
}
