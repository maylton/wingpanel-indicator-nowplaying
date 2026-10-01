/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Now Playing — a media indicator for elementary OS's Wingpanel.
 * Shows the current track in the panel and full controls in a popover.
 */

public class NowPlaying.Indicator : Wingpanel.Indicator {
    private const string CSS = """
        .nowplaying-title {
            font-weight: bold;
            font-size: 1.15em;
        }
        .nowplaying-small {
            font-size: 0.9em;
        }
        .nowplaying-time {
            font-size: 0.85em;
            font-feature-settings: "tnum";
        }
        .nowplaying-play {
            min-width: 44px;
            min-height: 44px;
            padding: 0;
            border-radius: 50%;
        }
        .nowplaying-toggle:checked {
            color: @theme_selected_bg_color;
        }
        .nowplaying-lyrics {
            background-color: alpha(@theme_fg_color, 0.06);
            border-radius: 8px;
        }
        .nowplaying-lyric {
            opacity: 0.45;
            transition: opacity 250ms ease-out;
        }
        .nowplaying-lyric-active {
            opacity: 1;
            font-weight: bold;
        }
        .nowplaying-lyric-plain {
            opacity: 0.85;
        }
        .nowplaying-lyrics-source {
            font-size: 0.75em;
            padding: 1px 6px;
            border-radius: 9px;
            background-color: alpha(@theme_bg_color, 0.85);
            color: alpha(@theme_fg_color, 0.6);
        }
        .nowplaying-section {
            font-weight: bold;
            font-size: 0.9em;
            opacity: 0.7;
        }
        .nowplaying-settings-title {
            font-weight: bold;
        }
    """;

    private Gtk.Box display_widget;
    private Gtk.Image panel_icon;
    private MarqueeLabel marquee;

    private Gtk.Stack main_widget;
    private Gtk.Stack stack;
    private Gtk.StackSwitcher switcher;

    private MprisManager manager;
    private HashTable<string, PlayerView> views;
    private Player? active_player = null;
    private bool popover_open = false;

    /* lyrics shown in the panel */
    private const int64 LYRIC_LEAD = 200000;
    private Lyrics? panel_lyrics = null;
    private string panel_lyrics_key = "";
    private uint panel_lyrics_request = 0;
    private int panel_line = -2;
    private uint lyric_timer = 0;
    private uint lyric_poll = 0;
    private Preferences prefs;

    public Indicator () {
        /*
         * Wingpanel sorts third-party indicators alphabetically by code_name.
         * The "aa-" prefix keeps us to the left of other unknown indicators,
         * such as the AppIconTray tray ("appicontray-indicator").
         */
        Object (code_name: "aa-nowplaying");
    }

    construct {
        Intl.bindtextdomain (Config.GETTEXT_PACKAGE, Config.LOCALEDIR);
        Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");

        load_css ();

        views = new HashTable<string, PlayerView> (str_hash, str_equal);
        prefs = Preferences.get_default ();

        /* ---- panel ---- */
        /* 16px glyphs line up visually with the system indicators' icons */
        panel_icon = new Gtk.Image () {
            pixel_size = 16,
            icon_name = "audio-x-generic-symbolic"
        };

        marquee = new MarqueeLabel () {
            max_width = prefs.panel_width,
            valign = Gtk.Align.CENTER,
            margin_start = 6
        };

        display_widget = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        display_widget.add (panel_icon);
        display_widget.add (marquee);
        display_widget.show_all ();

        /* Middle click toggles play/pause, like the Sound indicator */
        display_widget.button_press_event.connect ((event) => {
            if (event.button == Gdk.BUTTON_MIDDLE && active_player != null) {
                active_player.play_pause ();
                return Gdk.EVENT_STOP;
            }
            return Gdk.EVENT_PROPAGATE;
        });

        /* ---- popover ---- */
        stack = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT,
            vhomogeneous = false,
            interpolate_size = true
        };
        stack.notify["visible-child"].connect (sync_active_page);

        switcher = new Gtk.StackSwitcher () {
            stack = stack,
            halign = Gtk.Align.CENTER,
            margin_top = 6,
            margin_bottom = 3,
            no_show_all = true
        };

        /* A plain button: a Gtk.ModelButton would close the popover on click */
        var settings_button = new Gtk.Button () {
            child = new Gtk.Label (_("Indicator Preferences…")) { xalign = 0 }
        };
        settings_button.get_style_context ().add_class (Gtk.STYLE_CLASS_MENUITEM);
        settings_button.get_style_context ().add_class (Gtk.STYLE_CLASS_FLAT);

        var players_page = new Gtk.Grid () {
            orientation = Gtk.Orientation.VERTICAL
        };
        players_page.add (switcher);
        players_page.add (stack);
        players_page.add (new Gtk.Separator (Gtk.Orientation.HORIZONTAL) { margin_top = 3, margin_bottom = 3 });
        players_page.add (settings_button);

        var settings_page = new SettingsView ();

        main_widget = new Gtk.Stack () {
            transition_type = Gtk.StackTransitionType.SLIDE_LEFT_RIGHT,
            vhomogeneous = false,
            interpolate_size = true,
            width_request = 280
        };
        main_widget.add_named (players_page, "players");
        main_widget.add_named (settings_page, "settings");
        main_widget.show_all ();

        settings_button.clicked.connect (() => main_widget.visible_child_name = "settings");
        settings_page.back.connect (() => main_widget.visible_child_name = "players");

        /* ---- preferences ---- */
        prefs.notify["panel-width"].connect (() => marquee.max_width = prefs.panel_width);
        prefs.notify["show-artist"].connect (update_panel);
        prefs.notify["scroll-text"].connect (update_panel);
        prefs.notify["show-when-paused"].connect (update_panel);
        prefs.notify["panel-lyrics"].connect (update_panel);
        prefs.notify["lyrics-lrclib"].connect (refetch_panel_lyrics);
        prefs.notify["lyrics-netease"].connect (refetch_panel_lyrics);

        /* ---- players ---- */
        manager = new MprisManager ();
        manager.player_added.connect (on_player_added);
        manager.player_removed.connect (on_player_removed);
        manager.start.begin ();

        visible = false;
    }

    private void load_css () {
        var provider = new Gtk.CssProvider ();
        try {
            provider.load_from_data (CSS, -1);
            Gtk.StyleContext.add_provider_for_screen (
                Gdk.Screen.get_default (), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
            );
        } catch (Error e) {
            warning ("Unable to load CSS: %s", e.message);
        }
    }

    /* ---------- players ---------- */

    private void on_player_added (Player player) {
        var view = new PlayerView (player);
        view.request_close.connect (on_request_close);
        view.show_all ();

        views.insert (player.bus_name, view);
        stack.add_titled (view, player.bus_name, player.identity);

        player.metadata_changed.connect (on_players_changed);
        player.state_changed.connect (on_players_changed);

        on_players_changed ();
    }

    private void on_player_removed (Player player) {
        player.metadata_changed.disconnect (on_players_changed);
        player.state_changed.disconnect (on_players_changed);

        var view = views.lookup (player.bus_name);
        if (view != null) {
            views.remove (player.bus_name);
            view.request_close.disconnect (on_request_close);
            view.teardown ();
            view.destroy ();
        }

        if (active_player == player) {
            active_player = null;
        }

        on_players_changed ();
    }

    private void on_request_close () {
        close ();
    }

    private static string icon_name_for (Player player) {
        var theme = Gtk.IconTheme.get_default ();
        var themed = player.icon as ThemedIcon;
        if (themed != null) {
            foreach (unowned string name in themed.get_names ()) {
                if (theme.has_icon (name)) {
                    return name;
                }
            }
        }

        foreach (unowned string name in new string[] { "multimedia-audio-player", "audio-x-generic" }) {
            if (theme.has_icon (name)) {
                return name;
            }
        }
        return "audio-x-generic-symbolic";
    }

    private static bool has_content (Player player) {
        return player.title != "" || player.playback_status != "Stopped";
    }

    /* Called whenever any player changes: picks the player for the panel */
    private void on_players_changed () {
        Player? best = null;

        views.foreach ((name, view) => {
            var p = view.player;

            /* keep tab icons and titles fresh */
            stack.child_set_property (view, "icon-name", icon_name_for (p));
            stack.child_set_property (view, "title", p.identity);

            if (!has_content (p)) {
                return;
            }

            if (best == null) {
                best = p;
                return;
            }

            /* Playing beats paused; then the most recently started wins */
            if (p.is_playing != best.is_playing) {
                if (p.is_playing) {
                    best = p;
                }
            } else if (p.last_active > best.last_active) {
                best = p;
            } else if (p.last_active == best.last_active && p == active_player) {
                best = p;
            }
        });

        active_player = best;

        bool show_tabs = views.size () > 1;
        if (switcher.visible != show_tabs) {
            switcher.visible = show_tabs;
        }

        update_panel ();
    }

    private void update_panel () {
        bool should_show = active_player != null && (prefs.show_when_paused || active_player.is_playing);
        if (visible != should_show) {
            visible = should_show;
        }

        update_lyric_timers ();

        if (active_player == null) {
            marquee.loop = false;
            return;
        }

        panel_icon.icon_name = active_player.is_playing ? "audio-x-generic-symbolic" : "media-playback-pause-symbolic";

        if (prefs.panel_lyrics) {
            ensure_panel_lyrics ();
            if (show_panel_lyric ()) {
                return;
            }
        }

        /* Track info. Keep the title moving only while music is actually playing */
        panel_line = -2;
        marquee.loop = active_player.is_playing && prefs.scroll_text;
        marquee.text = active_player.get_panel_text (prefs.show_artist);
    }

    /* ---------- lyrics in the panel ---------- */

    private void refetch_panel_lyrics () {
        panel_lyrics_key = "";
        update_panel ();
    }

    private void ensure_panel_lyrics () {
        var p = active_player;
        var key = "%s\n%s\n%s\n%s\n%lld\n%s\n%u".printf (
            p.bus_name, p.title, p.artist, p.album, p.length, p.url, p.lyrics_text.hash ()
        );
        if (key == panel_lyrics_key) {
            return;
        }

        panel_lyrics_key = key;
        panel_lyrics = null;
        panel_line = -2;
        if (p.title == "") {
            return;
        }

        p.query_position.begin ();

        var request = ++panel_lyrics_request;
        LyricsService.get_default ().fetch.begin (new TrackQuery.from_player (p), (obj, res) => {
            var result = LyricsService.get_default ().fetch.end (res);
            if (request == panel_lyrics_request) {
                panel_lyrics = result;
                update_panel ();
            }
        });
    }

    /* Shows the line being sung. Returns false when there is nothing to show
     * (no synced lyrics, or before the first line) so the track is shown instead. */
    private bool show_panel_lyric () {
        if (panel_lyrics == null || !panel_lyrics.synced) {
            return false;
        }

        int index = panel_lyrics.index_at (active_player.estimate_position () + LYRIC_LEAD);
        if (index < 0) {
            return false;
        }

        if (index == panel_line && marquee.pan_mode) {
            return true;
        }
        panel_line = index;

        var line = panel_lyrics.lines[index];
        int64 next = index + 1 < panel_lyrics.lines.length
            ? panel_lyrics.lines[index + 1].time
            : line.time + 4000000;
        uint duration = (uint) ((next - line.time) / 1000).clamp (1500, 12000);

        marquee.loop = false;
        marquee.show_line (line.text.strip () != "" ? line.text.strip () : "♪", duration);
        return true;
    }

    private void update_lyric_timers () {
        bool needed = prefs.panel_lyrics && active_player != null && active_player.is_playing;

        if (needed && lyric_timer == 0) {
            lyric_timer = Timeout.add (150, () => {
                update_panel ();
                return Source.CONTINUE;
            });
            /* re-sync the interpolated position every couple of seconds */
            lyric_poll = Timeout.add_seconds (2, () => {
                if (active_player != null) {
                    active_player.query_position.begin ();
                }
                return Source.CONTINUE;
            });
        } else if (!needed && lyric_timer != 0) {
            Source.remove (lyric_timer);
            Source.remove (lyric_poll);
            lyric_timer = 0;
            lyric_poll = 0;
        }
    }

    /* Only the page on screen polls the player position */
    private void sync_active_page () {
        var current = stack.visible_child as PlayerView;
        views.foreach ((name, view) => {
            view.set_active (popover_open && view == current);
        });
    }

    /* ---------- Wingpanel.Indicator ---------- */

    public override Gtk.Widget get_display_widget () {
        return display_widget;
    }

    public override Gtk.Widget? get_widget () {
        return main_widget;
    }

    public override void opened () {
        popover_open = true;
        if (active_player != null && views.contains (active_player.bus_name)) {
            stack.set_visible_child_full (active_player.bus_name, Gtk.StackTransitionType.NONE);
        }
        sync_active_page ();
    }

    public override void closed () {
        popover_open = false;
        main_widget.set_visible_child_full ("players", Gtk.StackTransitionType.NONE);
        sync_active_page ();
    }
}

public Wingpanel.Indicator? get_indicator (Module module, Wingpanel.IndicatorManager.ServerType server_type) {
    if (server_type != Wingpanel.IndicatorManager.ServerType.SESSION) {
        return null;
    }

    debug ("Activating Now Playing indicator");
    return new NowPlaying.Indicator ();
}
