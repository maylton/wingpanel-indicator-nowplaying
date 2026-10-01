/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * User preferences, stored with GSettings when the schema is installed.
 * If the schema is missing (e.g. a manual copy of the .so), defaults are
 * used and nothing is saved — but the panel never crashes.
 */

public class NowPlaying.Preferences : Object {
    public const string SCHEMA_ID = "io.github.maylton.nowplaying";

    public const string MODE_COVER = "cover";
    public const string MODE_VINYL = "vinyl";
    public const string MODE_LYRICS = "lyrics";

    private static Preferences? instance = null;

    public static unowned Preferences get_default () {
        if (instance == null) {
            instance = new Preferences ();
        }
        return instance;
    }

    /* Width of the title in the panel, in pixels */
    public int panel_width { get; set; default = 200; }
    public bool show_artist { get; set; default = true; }
    public bool scroll_text { get; set; default = true; }
    public bool show_when_paused { get; set; default = true; }
    /* Show the current lyric line in the panel instead of the track */
    public bool panel_lyrics { get; set; default = false; }
    /* Online lyrics sources */
    public bool lyrics_lrclib { get; set; default = true; }
    public bool lyrics_netease { get; set; default = false; }

    private GLib.Settings? settings = null;
    private HashTable<string, string> memory_modes;

    construct {
        memory_modes = new HashTable<string, string> (str_hash, str_equal);

        var source = SettingsSchemaSource.get_default ();
        var schema = source != null ? source.lookup (SCHEMA_ID, true) : null;
        if (schema == null) {
            warning ("GSettings schema %s not installed; preferences will not be saved", SCHEMA_ID);
            return;
        }

        settings = new GLib.Settings.full (schema, null, null);
        settings.bind ("panel-width", this, "panel-width", SettingsBindFlags.DEFAULT);
        settings.bind ("show-artist", this, "show-artist", SettingsBindFlags.DEFAULT);
        settings.bind ("scroll-text", this, "scroll-text", SettingsBindFlags.DEFAULT);
        settings.bind ("show-when-paused", this, "show-when-paused", SettingsBindFlags.DEFAULT);
        settings.bind ("panel-lyrics", this, "panel-lyrics", SettingsBindFlags.DEFAULT);
        settings.bind ("lyrics-lrclib", this, "lyrics-lrclib", SettingsBindFlags.DEFAULT);
        settings.bind ("lyrics-netease", this, "lyrics-netease", SettingsBindFlags.DEFAULT);
    }

    /* Display mode remembered for each app (cover, vinyl or lyrics) */
    public string get_mode (string app) {
        if (settings == null) {
            return memory_modes.lookup (app) ?? MODE_COVER;
        }

        var modes = settings.get_value ("art-modes");
        var value = modes.lookup_value (app, VariantType.STRING);
        return value != null ? value.get_string () : MODE_COVER;
    }

    public void set_mode (string app, string mode) {
        if (settings == null) {
            memory_modes.insert (app, mode);
            return;
        }

        var builder = new VariantBuilder (new VariantType ("a{ss}"));
        var iter = settings.get_value ("art-modes").iterator ();
        string key, val;
        while (iter.next ("{ss}", out key, out val)) {
            if (key != app) {
                builder.add ("{ss}", key, val);
            }
        }
        if (mode != MODE_COVER) {
            builder.add ("{ss}", app, mode);
        }
        settings.set_value ("art-modes", builder.end ());
    }
}
