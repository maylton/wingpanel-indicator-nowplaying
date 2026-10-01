/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Wrapper around one MPRIS player (org.mpris.MediaPlayer2.*).
 * Uses plain GDBusProxy objects so that a slow or misbehaving player
 * can never block the panel: every call is asynchronous.
 */

namespace NowPlaying {
    public const string MPRIS_PREFIX = "org.mpris.MediaPlayer2.";
    public const string MPRIS_PATH = "/org/mpris/MediaPlayer2";
    private const string ROOT_IFACE = "org.mpris.MediaPlayer2";
    private const string PLAYER_IFACE = "org.mpris.MediaPlayer2.Player";

    public enum LoopStatus {
        NONE,
        TRACK,
        PLAYLIST;

        public static LoopStatus from_string (string? s) {
            switch (s) {
                case "Track": return TRACK;
                case "Playlist": return PLAYLIST;
                default: return NONE;
            }
        }

        public string to_mpris () {
            switch (this) {
                case TRACK: return "Track";
                case PLAYLIST: return "Playlist";
                default: return "None";
            }
        }

        /* Order used by the repeat button: off -> all -> one -> off */
        public LoopStatus next () {
            switch (this) {
                case NONE: return PLAYLIST;
                case PLAYLIST: return TRACK;
                default: return NONE;
            }
        }
    }

    public class Player : Object {
        public string bus_name { get; construct; }

        public string identity { get; private set; default = ""; }
        public GLib.Icon icon { get; private set; }

        public string title { get; private set; default = ""; }
        public string artist { get; private set; default = ""; }
        public string album { get; private set; default = ""; }
        public string art_url { get; private set; default = ""; }
        /* file:// or http(s):// address of the media, when the player tells */
        public string url { get; private set; default = ""; }
        /* Lyrics sent by the player itself (xesam:asText), plain or LRC */
        public string lyrics_text { get; private set; default = ""; }
        public string track_id { get; private set; default = ""; }
        /* Track length in microseconds (0 when unknown) */
        public int64 length { get; private set; default = 0; }

        public string playback_status { get; private set; default = "Stopped"; }
        public bool is_playing { get { return playback_status == "Playing"; } }

        public bool has_shuffle { get; private set; default = false; }
        public bool shuffle { get; private set; default = false; }
        public bool has_loop_status { get; private set; default = false; }
        public LoopStatus loop_status { get; private set; default = LoopStatus.NONE; }

        public bool can_control { get; private set; default = false; }
        public bool can_go_next { get; private set; default = false; }
        public bool can_go_previous { get; private set; default = false; }
        public bool can_play { get; private set; default = false; }
        public bool can_pause { get; private set; default = false; }
        public bool can_seek { get; private set; default = false; }
        public bool can_raise { get; private set; default = false; }

        /* Monotonic time of the last moment this player started playing */
        public int64 last_active { get; private set; default = 0; }

        /* Last known position in microseconds, refreshed by query_position () */
        public int64 position { get; private set; default = 0; }
        private int64 position_time = 0;

        public signal void metadata_changed ();
        public signal void state_changed ();
        public signal void seeked (int64 position);

        private DBusProxy? root_proxy = null;
        private DBusProxy? player_proxy = null;

        public Player (string bus_name) {
            Object (bus_name: bus_name);
        }

        construct {
            icon = new ThemedIcon.from_names ({ "multimedia-audio-player", "audio-x-generic", "audio-x-generic-symbolic" });
        }

        public async bool init () {
            var flags = DBusProxyFlags.DO_NOT_AUTO_START | DBusProxyFlags.GET_INVALIDATED_PROPERTIES;
            try {
                root_proxy = yield new DBusProxy.for_bus (
                    BusType.SESSION, flags, null, bus_name, MPRIS_PATH, ROOT_IFACE, null
                );
                player_proxy = yield new DBusProxy.for_bus (
                    BusType.SESSION, flags, null, bus_name, MPRIS_PATH, PLAYER_IFACE, null
                );
            } catch (Error e) {
                warning ("Could not connect to %s: %s", bus_name, e.message);
                return false;
            }

            read_root ();
            read_metadata ();
            read_state ();

            if (is_playing) {
                last_active = get_monotonic_time ();
            }

            root_proxy.g_properties_changed.connect (() => {
                read_root ();
                state_changed ();
            });

            player_proxy.g_properties_changed.connect ((changed, invalidated) => {
                bool metadata = changed.lookup_value ("Metadata", null) != null;
                foreach (unowned string name in invalidated) {
                    if (name == "Metadata") {
                        metadata = true;
                    }
                }

                int64 estimated = estimate_position ();
                if (metadata) {
                    read_metadata ();
                    estimated = 0;
                    update_position (0);
                    metadata_changed ();
                }

                bool was_playing = is_playing;
                read_state ();
                if (is_playing != was_playing) {
                    /* freeze (or restart) the clock used for interpolation */
                    update_position (estimated);
                }
                if (is_playing && !was_playing) {
                    last_active = get_monotonic_time ();
                }
                state_changed ();
            });

            player_proxy.g_signal.connect ((sender, signal_name, parameters) => {
                if (signal_name == "Seeked" && parameters.is_of_type (new VariantType ("(x)"))) {
                    int64 pos;
                    parameters.get ("(x)", out pos);
                    update_position (pos);
                    seeked (pos);
                }
            });

            return true;
        }

        /* ---------- reading properties ---------- */

        private static bool get_bool (DBusProxy proxy, string name, bool fallback = false) {
            var v = proxy.get_cached_property (name);
            if (v != null && v.is_of_type (VariantType.BOOLEAN)) {
                return v.get_boolean ();
            }
            return fallback;
        }

        private static string? get_string (DBusProxy proxy, string name) {
            var v = proxy.get_cached_property (name);
            if (v != null && v.is_of_type (VariantType.STRING)) {
                return v.get_string ();
            }
            return null;
        }

        private static int64 variant_to_int64 (Variant v) {
            if (v.is_of_type (VariantType.INT64)) return v.get_int64 ();
            if (v.is_of_type (VariantType.UINT64)) return (int64) v.get_uint64 ();
            if (v.is_of_type (VariantType.INT32)) return v.get_int32 ();
            if (v.is_of_type (VariantType.UINT32)) return v.get_uint32 ();
            if (v.is_of_type (VariantType.DOUBLE)) return (int64) v.get_double ();
            return 0;
        }

        private void read_root () {
            if (root_proxy == null) {
                return;
            }

            identity = get_string (root_proxy, "Identity") ?? "";
            can_raise = get_bool (root_proxy, "CanRaise");

            DesktopAppInfo? info = null;
            var entry = get_string (root_proxy, "DesktopEntry");
            if (entry != null && entry != "") {
                info = new DesktopAppInfo (entry + ".desktop");
                if (info == null) {
                    info = new DesktopAppInfo (entry.down () + ".desktop");
                }
            }

            if (info == null) {
                /* Guess from the bus name, e.g. org.mpris.MediaPlayer2.vlc -> vlc.desktop */
                var guess = bus_name.substring (MPRIS_PREFIX.length).split (".")[0];
                if (guess != null && guess != "") {
                    info = new DesktopAppInfo (guess + ".desktop");
                }
            }

            if (info != null) {
                if (info.get_icon () != null) {
                    icon = info.get_icon ();
                }
                if (identity == "") {
                    identity = info.get_display_name ();
                }
            }

            if (identity == "") {
                identity = bus_name.substring (MPRIS_PREFIX.length).split (".")[0];
            }
        }

        private void read_metadata () {
            title = "";
            artist = "";
            album = "";
            art_url = "";
            url = "";
            lyrics_text = "";
            track_id = "";
            length = 0;

            var md = player_proxy.get_cached_property ("Metadata");
            if (md == null || !md.is_of_type (new VariantType ("a{sv}"))) {
                return;
            }

            var v = md.lookup_value ("xesam:title", null);
            if (v != null && v.is_of_type (VariantType.STRING)) {
                title = v.get_string ().strip ();
            }

            v = md.lookup_value ("xesam:artist", null);
            if (v != null) {
                if (v.is_of_type (VariantType.STRING_ARRAY)) {
                    artist = string.joinv (", ", v.get_strv ()).strip ();
                } else if (v.is_of_type (VariantType.STRING)) {
                    artist = v.get_string ().strip ();
                }
            }

            v = md.lookup_value ("xesam:album", null);
            if (v != null && v.is_of_type (VariantType.STRING)) {
                album = v.get_string ().strip ();
            }

            v = md.lookup_value ("mpris:artUrl", null);
            if (v != null && v.is_of_type (VariantType.STRING)) {
                art_url = v.get_string ();
            }

            v = md.lookup_value ("xesam:url", null);
            if (v != null && v.is_of_type (VariantType.STRING)) {
                url = v.get_string ();
            }

            v = md.lookup_value ("xesam:asText", null);
            if (v != null && v.is_of_type (VariantType.STRING)) {
                lyrics_text = v.get_string ();
            }

            v = md.lookup_value ("mpris:trackid", null);
            if (v != null && (v.is_of_type (VariantType.OBJECT_PATH) || v.is_of_type (VariantType.STRING))) {
                track_id = v.get_string ();
            }

            v = md.lookup_value ("mpris:length", null);
            if (v != null) {
                length = variant_to_int64 (v);
            }
        }

        private void read_state () {
            playback_status = get_string (player_proxy, "PlaybackStatus") ?? "Stopped";

            can_control = get_bool (player_proxy, "CanControl", true);
            can_go_next = can_control && get_bool (player_proxy, "CanGoNext");
            can_go_previous = can_control && get_bool (player_proxy, "CanGoPrevious");
            can_play = can_control && get_bool (player_proxy, "CanPlay");
            can_pause = can_control && get_bool (player_proxy, "CanPause");
            can_seek = can_control && get_bool (player_proxy, "CanSeek");

            var shuffle_v = player_proxy.get_cached_property ("Shuffle");
            has_shuffle = can_control && shuffle_v != null && shuffle_v.is_of_type (VariantType.BOOLEAN);
            shuffle = has_shuffle && shuffle_v.get_boolean ();

            var loop = get_string (player_proxy, "LoopStatus");
            has_loop_status = can_control && loop != null;
            loop_status = LoopStatus.from_string (loop);
        }

        /* ---------- commands ---------- */

        private void call_method (DBusProxy? proxy, string method, Variant? parameters = null) {
            if (proxy == null) {
                return;
            }

            proxy.call.begin (method, parameters, DBusCallFlags.NONE, 2000, null, (obj, res) => {
                try {
                    proxy.call.end (res);
                } catch (Error e) {
                    warning ("%s.%s failed: %s", bus_name, method, e.message);
                }
            });
        }

        private void set_property_remote (string name, Variant value) {
            call_method (
                player_proxy,
                "org.freedesktop.DBus.Properties.Set",
                new Variant ("(ssv)", PLAYER_IFACE, name, value)
            );
        }

        public void play_pause () {
            call_method (player_proxy, "PlayPause");
        }

        public void next () {
            call_method (player_proxy, "Next");
        }

        public void previous () {
            call_method (player_proxy, "Previous");
        }

        public void raise_window () {
            call_method (root_proxy, "Raise");
        }

        public void request_shuffle (bool value) {
            set_property_remote ("Shuffle", new Variant.boolean (value));
        }

        public void request_loop_status (LoopStatus value) {
            set_property_remote ("LoopStatus", new Variant.string (value.to_mpris ()));
        }

        /* Seek to an absolute position (microseconds) */
        public void seek_to (int64 target) {
            target = target.clamp (0, length > 0 ? length : int64.MAX);

            if (track_id != "" && Variant.is_object_path (track_id)) {
                call_method (player_proxy, "SetPosition", new Variant ("(ox)", track_id, target));
            } else {
                call_method (player_proxy, "Seek", new Variant ("(x)", target - position));
            }
            update_position (target);
        }

        /* Position is never announced through PropertiesChanged, so ask for it */
        public async int64 query_position () {
            if (player_proxy == null) {
                return position;
            }

            try {
                var result = yield player_proxy.call (
                    "org.freedesktop.DBus.Properties.Get",
                    new Variant ("(ss)", PLAYER_IFACE, "Position"),
                    DBusCallFlags.NONE, 1000, null
                );
                Variant inner;
                result.get ("(v)", out inner);
                update_position (variant_to_int64 (inner));
            } catch (Error e) {
                debug ("Position query failed for %s: %s", bus_name, e.message);
            }

            return position;
        }

        private void update_position (int64 value) {
            position = value;
            position_time = get_monotonic_time ();
        }

        /* Position now, interpolated from the last known one (for lyrics and the vinyl arm) */
        public int64 estimate_position () {
            if (!is_playing || position_time == 0) {
                return position;
            }
            int64 p = position + (get_monotonic_time () - position_time);
            return length > 0 ? int64.min (p, length) : p;
        }

        /* Key used to remember per-app preferences */
        public string app_key {
            owned get {
                return identity != "" ? identity : bus_name;
            }
        }

        /* Text shown in the panel */
        public string get_panel_text (bool show_artist = true) {
            if (show_artist && title != "" && artist != "") {
                return "%s — %s".printf (title, artist);
            }
            if (title != "") {
                return title;
            }
            return identity;
        }
    }
}
