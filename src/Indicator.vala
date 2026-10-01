/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Now Playing — a media indicator for elementary OS's Wingpanel.
 * Shows the current track in the panel and full controls in a popover.
 */

public class NowPlaying.Indicator : Wingpanel.Indicator {
    private const int PANEL_TEXT_WIDTH = 200;

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
    """;

    private Gtk.Box display_widget;
    private Gtk.Image panel_icon;
    private MarqueeLabel marquee;

    private Gtk.Grid main_widget;
    private Gtk.Stack stack;
    private Gtk.StackSwitcher switcher;

    private MprisManager manager;
    private HashTable<string, PlayerView> views;
    private Player? active_player = null;
    private bool popover_open = false;

    public Indicator () {
        Object (code_name: "nowplaying");
    }

    construct {
        Intl.bindtextdomain (Config.GETTEXT_PACKAGE, Config.LOCALEDIR);
        Intl.bind_textdomain_codeset (Config.GETTEXT_PACKAGE, "UTF-8");

        load_css ();

        views = new HashTable<string, PlayerView> (str_hash, str_equal);

        /* ---- panel ---- */
        panel_icon = new Gtk.Image () {
            pixel_size = 24,
            icon_name = "audio-x-generic-symbolic"
        };

        marquee = new MarqueeLabel () {
            max_width = PANEL_TEXT_WIDTH,
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

        main_widget = new Gtk.Grid () {
            orientation = Gtk.Orientation.VERTICAL,
            width_request = 280
        };
        main_widget.add (switcher);
        main_widget.add (stack);
        main_widget.show_all ();

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
        bool should_show = active_player != null;
        if (visible != should_show) {
            visible = should_show;
        }

        if (active_player == null) {
            return;
        }

        marquee.text = active_player.get_panel_text ();
        panel_icon.icon_name = active_player.is_playing ? "audio-x-generic-symbolic" : "media-playback-pause-symbolic";
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
