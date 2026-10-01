/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Finds lyrics for a track by trying several sources, in order:
 *
 *   1. The player itself  — lyrics sent in the MPRIS metadata (xesam:asText)
 *   2. Local .lrc files   — next to the music file, or in ~/.lyrics/
 *   3. LRCLIB             — https://lrclib.net, free and open (on by default)
 *   4. NetEase Cloud Music — unofficial public endpoint, huge catalogue of
 *                           Asian music (opt-in, may stop working any time)
 *
 * Time-synced lyrics win: if a source only has plain text, the next sources
 * are still asked for a synced version, and the plain text is kept as a
 * fallback.
 */

namespace NowPlaying {
    public class LyricLine : Object {
        public int64 time { get; construct; }  /* microseconds */
        public string text { get; construct; }

        public LyricLine (int64 time, string text) {
            Object (time: time, text: text);
        }
    }

    public class Lyrics : Object {
        public bool synced { get; set; default = false; }
        public bool instrumental { get; set; default = false; }
        /* Synced lines, sorted by time (empty when not synced) */
        public GenericArray<LyricLine> lines { get; set; }
        /* Unsynced text (used when there is no synced version) */
        public string plain { get; set; default = ""; }
        /* Where the lyrics came from, shown to the user */
        public string source { get; set; default = ""; }

        construct {
            lines = new GenericArray<LyricLine> ();
        }

        public bool is_empty () {
            return !instrumental && lines.length == 0 && plain.strip () == "";
        }

        /* Final answer: no need to ask other sources */
        public bool is_complete () {
            return synced || instrumental;
        }

        /* Index of the line being sung at `position`, or -1 before the first one */
        public int index_at (int64 position) {
            int lo = 0, hi = (int) lines.length - 1, found = -1;
            while (lo <= hi) {
                int mid = (lo + hi) / 2;
                if (lines[mid].time <= position) {
                    found = mid;
                    lo = mid + 1;
                } else {
                    hi = mid - 1;
                }
            }
            return found;
        }

        /* Builds lyrics from text that may or may not be LRC */
        public static Lyrics? from_text (string text, string source) {
            if (text.strip () == "") {
                return null;
            }
            var lyrics = new Lyrics () { source = source };
            lyrics.lines = LyricsService.parse_lrc (text);
            lyrics.synced = lyrics.lines.length > 0;
            if (!lyrics.synced) {
                lyrics.plain = text.strip ();
            }
            return lyrics.is_empty () ? null : lyrics;
        }
    }

    /* Snapshot of what we know about the track (the player may change meanwhile) */
    public class TrackQuery : Object {
        public string title { get; set; default = ""; }
        public string artist { get; set; default = ""; }
        public string album { get; set; default = ""; }
        public string url { get; set; default = ""; }
        public string embedded { get; set; default = ""; }
        public int duration { get; set; default = 0; }  /* seconds */

        public TrackQuery.from_player (Player player) {
            title = player.title;
            artist = player.artist;
            album = player.album;
            url = player.url;
            embedded = player.lyrics_text;
            duration = (int) (player.length / 1000000);
        }
    }

    public class LyricsService : Object {
        private const string LRCLIB_BASE = "https://lrclib.net";
        private const string NETEASE_BASE = "https://music.163.com";
        private const uint CACHE_SIZE = 48;

        private static LyricsService? instance = null;

        public static unowned LyricsService get_default () {
            if (instance == null) {
                instance = new LyricsService ();
            }
            return instance;
        }

        private Soup.Session session;
        private string lrclib_base;
        private string netease_base;
        /* key -> lyrics (a null value means "looked up, nothing found") */
        private HashTable<string, Lyrics?> cache;
        private Queue<string> cache_order;

        construct {
            session = new Soup.Session () {
                timeout = 12,
                /* LRCLIB asks clients to identify themselves */
                user_agent = "wingpanel-indicator-nowplaying/0.4 (https://github.com/maylton)"
            };
            /* Overridable for testing */
            lrclib_base = Environment.get_variable ("NOWPLAYING_LRCLIB_URL") ?? LRCLIB_BASE;
            netease_base = Environment.get_variable ("NOWPLAYING_NETEASE_URL") ?? NETEASE_BASE;
            cache = new HashTable<string, Lyrics?> (str_hash, str_equal);
            cache_order = new Queue<string> ();
        }

        public void clear_cache () {
            cache.remove_all ();
            cache_order.clear ();
        }

        /* ---------- cleaning metadata for better matches ---------- */

        /* YouTube Music clients sometimes send "Song • Artist" as the artist */
        private const string[] TYPE_WORDS = {
            "song", "música", "musica", "canção", "cancao", "video", "vídeo",
            "single", "ep", "album", "álbum", "episode", "episódio"
        };

        public static string clean_artist (string artist) {
            var parts = artist.split (" • ");
            if (parts.length > 1 && parts[0].strip ().down () in TYPE_WORDS) {
                return string.joinv (" • ", parts[1:parts.length]).strip ();
            }
            return artist.strip ();
        }

        /* "Song (Official Video) [HD]" -> "Song" */
        public static string clean_title (string title) {
            try {
                var brackets = new Regex ("\\s*[\\(\\[][^\\)\\]]*[\\)\\]]");
                return brackets.replace (title, -1, 0, "").strip ();
            } catch (RegexError e) {
                return title.strip ();
            }
        }

        /* lower case, letters and digits only — for loose comparisons */
        private static string normalize (string s) {
            var builder = new StringBuilder ();
            unichar c;
            int i = 0;
            var lower = s.down ();
            while (lower.get_next_char (ref i, out c)) {
                if (c.isalnum ()) {
                    builder.append_unichar (c);
                }
            }
            return builder.str;
        }

        /* ---------- LRC parsing ---------- */

        /* Credit lines some sources put at the top ("作词 : …", "Composer: …") */
        private static Regex? credits_regex = null;

        public static GenericArray<LyricLine> parse_lrc (string lrc) {
            var lines = new GenericArray<LyricLine> ();
            Regex stamp;
            try {
                stamp = new Regex ("\\[(\\d+):(\\d{1,2})(?:[\\.:](\\d{1,3}))?\\]");
                if (credits_regex == null) {
                    credits_regex = new Regex (
                        "^(作词|作詞|作曲|编曲|編曲|制作人|製作人|词|詞|曲|lyricist|lyrics|composer|composed by|arranger|producer)\\s*[:：]",
                        RegexCompileFlags.CASELESS
                    );
                }
            } catch (RegexError e) {
                return lines;
            }

            foreach (unowned string raw in lrc.split ("\n")) {
                var line = raw.strip ();
                MatchInfo match;
                if (!stamp.match (line, 0, out match)) {
                    continue;
                }

                /* A line may carry several timestamps: [00:12.00][01:30.00]Text */
                int64[] times = {};
                int text_start = 0;
                while (match.matches ()) {
                    int start, end;
                    match.fetch_pos (0, out start, out end);
                    if (start != text_start) {
                        break;  /* timestamps only at the beginning */
                    }

                    int64 minutes = int64.parse (match.fetch (1));
                    int64 seconds = int64.parse (match.fetch (2));
                    var frac = match.fetch (3) ?? "";
                    int64 micro = 0;
                    if (frac != "") {
                        /* "5" = 500ms, "50" = 500ms, "500" = 500ms */
                        while (frac.length < 3) {
                            frac += "0";
                        }
                        micro = int64.parse (frac) * 1000;
                    }
                    times += (minutes * 60 + seconds) * 1000000 + micro;
                    text_start = end;

                    try {
                        match.next ();
                    } catch (RegexError e) {
                        break;
                    }
                }

                var text = line.substring (text_start).strip ();
                if (credits_regex.match (text)) {
                    continue;
                }
                foreach (var t in times) {
                    lines.add (new LyricLine (t, text));
                }
            }

            lines.sort ((a, b) => a.time < b.time ? -1 : (a.time > b.time ? 1 : 0));
            return lines;
        }

        /* ---------- main entry point ---------- */

        public async Lyrics? fetch (TrackQuery track) {
            var title = clean_title (track.title);
            var artist = clean_artist (track.artist);
            if (title == "") {
                return null;
            }

            Lyrics? fallback = null;

            /* 1. sent by the player (never cached: it's free and may change) */
            var embedded = Lyrics.from_text (track.embedded, _("Player"));
            if (embedded != null && embedded.is_complete ()) {
                return embedded;
            }
            fallback = embedded;

            /* 2. local files (not cached either, so new .lrc files show up) */
            var local = yield from_local_file (track, title, artist);
            if (local != null && local.is_complete ()) {
                return local;
            }
            fallback = fallback ?? local;

            /* 3+. online sources */
            var prefs = Preferences.get_default ();
            /* the enabled sources are part of the key, so toggling one looks again */
            var key = "%s\n%s\n%d\n%s%s".printf (
                title.down (), artist.down (), track.duration,
                prefs.lyrics_lrclib ? "L" : "", prefs.lyrics_netease ? "N" : ""
            );
            if (cache.contains (key)) {
                return cache.lookup (key) ?? fallback;
            }

            bool any_answer = false;

            if (prefs.lyrics_lrclib) {
                bool answered;
                var found = yield from_lrclib (track, title, artist, out answered);
                any_answer |= answered;
                if (found != null && found.is_complete ()) {
                    remember (key, found);
                    return found;
                }
                fallback = fallback ?? found;
            }

            if (prefs.lyrics_netease) {
                bool answered;
                var found = yield from_netease (title, artist, track.duration, out answered);
                any_answer |= answered;
                if (found != null && found.is_complete ()) {
                    remember (key, found);
                    return found;
                }
                fallback = fallback ?? found;
            }

            /* Don't cache when every source failed (offline): a retry may work */
            if (any_answer) {
                remember (key, fallback);
            }
            return fallback;
        }

        private void remember (string key, Lyrics? lyrics) {
            if (!cache.contains (key)) {
                cache_order.push_tail (key);
            }
            cache.insert (key, lyrics);
            while (cache_order.length > CACHE_SIZE) {
                cache.remove (cache_order.pop_head ());
            }
        }

        /* ---------- local .lrc files ---------- */

        private static string safe_name (string s) {
            return s.replace ("/", "-").replace ("\\", "-").strip ();
        }

        private async Lyrics? from_local_file (TrackQuery track, string title, string artist) {
            var candidates = new GenericArray<File> ();

            /* next to the music file: song.mp3 -> song.lrc */
            if (track.url.has_prefix ("file://")) {
                var path = File.new_for_uri (track.url).get_path ();
                if (path != null) {
                    var dot = path.last_index_of_char ('.');
                    var slash = path.last_index_of_char ('/');
                    var base_path = dot > slash ? path.substring (0, dot) : path;
                    candidates.add (File.new_for_path (base_path + ".lrc"));
                }
            }

            /* ~/.lyrics/Artist - Title.lrc, or ~/.lyrics/Title.lrc */
            var folder = File.new_for_path (Path.build_filename (Environment.get_home_dir (), ".lyrics"));
            if (artist != "") {
                candidates.add (folder.get_child ("%s - %s.lrc".printf (safe_name (artist), safe_name (title))));
            }
            candidates.add (folder.get_child ("%s.lrc".printf (safe_name (title))));

            foreach (var file in candidates.data) {
                try {
                    uint8[] contents;
                    yield file.load_contents_async (null, out contents, null);
                    var lyrics = Lyrics.from_text ((string) contents, _("Local file"));
                    if (lyrics != null) {
                        return lyrics;
                    }
                } catch (Error e) {
                    /* not there — try the next one */
                }
            }
            return null;
        }

        /* ---------- HTTP helpers ---------- */

        private async Json.Node? get_json (string base_url, string path, HashTable<string, string> query, string? referer, out bool answered) {
            answered = false;
            var builder = new StringBuilder (base_url + path + "?");
            bool first = true;
            query.foreach ((k, v) => {
                if (!first) {
                    builder.append_c ('&');
                }
                builder.append (Uri.escape_string (k, null, true));
                builder.append_c ('=');
                builder.append (Uri.escape_string (v, null, true));
                first = false;
            });

            var message = new Soup.Message ("GET", builder.str);
            if (message == null) {
                return null;
            }
            if (referer != null) {
                message.request_headers.append ("Referer", referer);
            }

            try {
                var bytes = yield session.send_and_read_async (message, Priority.DEFAULT, null);
                /* a 404 is a real answer ("not found"), a 5xx is not */
                answered = message.status_code < 500;
                if (message.status_code != Soup.Status.OK) {
                    debug ("%s%s -> %u", base_url, path, message.status_code);
                    return null;
                }
                var parser = new Json.Parser ();
                parser.load_from_data ((string) bytes.get_data (), (ssize_t) bytes.get_size ());
                return parser.get_root ();
            } catch (Error e) {
                debug ("Request to %s failed: %s", base_url, e.message);
                return null;
            }
        }

        private static string? member_string (Json.Object obj, string name) {
            if (!obj.has_member (name)) {
                return null;
            }
            var node = obj.get_member (name);
            if (node.get_node_type () != Json.NodeType.VALUE || node.get_value_type () != typeof (string)) {
                return null;
            }
            var value = node.get_string ();
            return (value != null && value.strip () != "") ? value : null;
        }

        private static double member_number (Json.Object obj, string name) {
            if (!obj.has_member (name) || obj.get_member (name).get_node_type () != Json.NodeType.VALUE) {
                return -1;
            }
            var node = obj.get_member (name);
            var type = node.get_value_type ();
            if (type == typeof (int64)) {
                return (double) node.get_int ();
            }
            if (type == typeof (double)) {
                return node.get_double ();
            }
            return -1;
        }

        /* ---------- LRCLIB ---------- */

        private static Lyrics? from_lrclib_record (Json.Object obj) {
            var lyrics = new Lyrics () { source = "LRCLIB" };
            lyrics.instrumental = obj.has_member ("instrumental") &&
                obj.get_member ("instrumental").get_node_type () == Json.NodeType.VALUE &&
                obj.get_boolean_member ("instrumental");

            var synced = member_string (obj, "syncedLyrics");
            if (synced != null) {
                lyrics.lines = parse_lrc (synced);
                lyrics.synced = lyrics.lines.length > 0;
            }

            lyrics.plain = member_string (obj, "plainLyrics") ?? "";
            return lyrics.is_empty () ? null : lyrics;
        }

        /*
         * /api/get (exact match by artist, title, album, duration) sometimes
         * answers with plain lyrics only, or fails, even when a synced version
         * exists — so fall back to /api/search and pick the best synced result.
         */
        private async Lyrics? from_lrclib (TrackQuery track, string title, string artist, out bool answered) {
            answered = false;
            Lyrics? plain_fallback = null;
            int duration = track.duration;

            if (duration > 0 && artist != "") {
                var q = new HashTable<string, string> (str_hash, str_equal);
                q.insert ("track_name", track.title.strip ());
                q.insert ("artist_name", artist);
                q.insert ("album_name", track.album);
                q.insert ("duration", duration.to_string ());

                bool ok;
                var node = yield get_json (lrclib_base, "/api/get", q, null, out ok);
                answered |= ok;
                if (node != null && node.get_node_type () == Json.NodeType.OBJECT) {
                    var found = from_lrclib_record (node.get_object ());
                    if (found != null && found.is_complete ()) {
                        return found;
                    }
                    plain_fallback = found;
                }
            }

            var sq = new HashTable<string, string> (str_hash, str_equal);
            sq.insert ("track_name", title);
            if (artist != "") {
                sq.insert ("artist_name", artist);
            }

            bool ok;
            var results = yield get_json (lrclib_base, "/api/search", sq, null, out ok);
            answered |= ok;
            Lyrics? best = null;
            double best_diff = double.MAX;

            if (results != null && results.get_node_type () == Json.NodeType.ARRAY) {
                foreach (var item in results.get_array ().get_elements ()) {
                    if (item.get_node_type () != Json.NodeType.OBJECT) {
                        continue;
                    }
                    var obj = item.get_object ();
                    var candidate = from_lrclib_record (obj);
                    if (candidate == null) {
                        continue;
                    }

                    double diff = duration > 0 ? (member_number (obj, "duration") - duration).abs () : 0;
                    if (duration > 0 && diff > 5) {
                        continue;  /* probably a different version */
                    }

                    if (candidate.synced) {
                        if (best == null || !best.synced || diff < best_diff) {
                            best = candidate;
                            best_diff = diff;
                        }
                    } else if (best == null) {
                        best = candidate;
                        best_diff = diff;
                    }
                }
            }

            return best ?? plain_fallback;
        }

        /* ---------- NetEase Cloud Music ---------- */

        private async Lyrics? from_netease (string title, string artist, int duration, out bool answered) {
            answered = false;
            var referer = netease_base + "/";

            var q = new HashTable<string, string> (str_hash, str_equal);
            q.insert ("s", artist != "" ? "%s %s".printf (title, artist) : title);
            q.insert ("type", "1");
            q.insert ("limit", "10");

            bool ok;
            var root = yield get_json (netease_base, "/api/search/get", q, referer, out ok);
            answered |= ok;
            if (root == null || root.get_node_type () != Json.NodeType.OBJECT) {
                return null;
            }

            var result = root.get_object ();
            if (!result.has_member ("result") || result.get_member ("result").get_node_type () != Json.NodeType.OBJECT) {
                return null;
            }
            var res_obj = result.get_object_member ("result");
            if (!res_obj.has_member ("songs") || res_obj.get_member ("songs").get_node_type () != Json.NodeType.ARRAY) {
                return null;
            }

            /*
             * Names often differ (e.g. romanised vs. original script), so the
             * duration is the main guard against wrong lyrics. Without a known
             * duration, insist on a matching title.
             */
            var want_title = normalize (title);
            int64 best_id = -1;
            double best_score = double.MAX;

            foreach (var item in res_obj.get_array_member ("songs").get_elements ()) {
                if (item.get_node_type () != Json.NodeType.OBJECT) {
                    continue;
                }
                var song = item.get_object ();
                double id = member_number (song, "id");
                if (id <= 0) {
                    continue;
                }

                double ms = member_number (song, "duration");
                if (ms <= 0) {
                    ms = member_number (song, "dt");
                }
                var name = normalize (member_string (song, "name") ?? "");
                bool title_match = name != "" && want_title != "" &&
                    (name == want_title || name.contains (want_title) || want_title.contains (name));

                double score;
                if (duration > 0 && ms > 0) {
                    double diff = (ms / 1000.0 - duration).abs ();
                    if (diff > 3) {
                        continue;
                    }
                    score = diff - (title_match ? 2 : 0);
                } else if (title_match) {
                    score = 10;
                } else {
                    continue;
                }

                if (score < best_score) {
                    best_score = score;
                    best_id = (int64) id;
                }
            }

            if (best_id < 0) {
                return null;
            }

            var lq = new HashTable<string, string> (str_hash, str_equal);
            lq.insert ("id", best_id.to_string ());
            lq.insert ("lv", "1");
            var lyric_root = yield get_json (netease_base, "/api/song/lyric", lq, referer, out ok);
            if (lyric_root == null || lyric_root.get_node_type () != Json.NodeType.OBJECT) {
                return null;
            }

            var lobj = lyric_root.get_object ();
            if (!lobj.has_member ("lrc") || lobj.get_member ("lrc").get_node_type () != Json.NodeType.OBJECT) {
                return null;
            }
            var text = member_string (lobj.get_object_member ("lrc"), "lyric");
            return text != null ? Lyrics.from_text (text, "NetEase") : null;
        }
    }
}
