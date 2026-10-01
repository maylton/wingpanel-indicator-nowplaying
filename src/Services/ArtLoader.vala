/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Loads album art from file://, http(s):// or data: URLs, with a small cache.
 */

public class NowPlaying.ArtLoader : Object {
    private const int MAX_SIZE = 512;
    private const uint CACHE_SIZE = 16;

    private static ArtLoader? instance = null;

    public static unowned ArtLoader get_default () {
        if (instance == null) {
            instance = new ArtLoader ();
        }
        return instance;
    }

    private Soup.Session session;
    private HashTable<string, Gdk.Pixbuf> cache;
    private Queue<string> cache_order;

    construct {
        session = new Soup.Session () {
            timeout = 15,
            user_agent = "wingpanel-indicator-nowplaying"
        };
        cache = new HashTable<string, Gdk.Pixbuf> (str_hash, str_equal);
        cache_order = new Queue<string> ();
    }

    public async Gdk.Pixbuf? load (string url) {
        if (url == "") {
            return null;
        }

        var cached = cache.lookup (url);
        if (cached != null) {
            return cached;
        }

        Gdk.Pixbuf? pixbuf = null;
        try {
            InputStream? stream = null;

            if (url.has_prefix ("file://") || url.has_prefix ("/")) {
                var file = url.has_prefix ("/") ? File.new_for_path (url) : File.new_for_uri (url);
                stream = yield file.read_async (Priority.DEFAULT, null);
            } else if (url.has_prefix ("http://") || url.has_prefix ("https://")) {
                if (!Uri.is_valid (url, UriFlags.NONE)) {
                    return null;
                }
                var message = new Soup.Message ("GET", url);
                var bytes = yield session.send_and_read_async (message, Priority.DEFAULT, null);
                if (message.status_code != Soup.Status.OK) {
                    debug ("Art download failed (%u): %s", message.status_code, url);
                    return null;
                }
                stream = new MemoryInputStream.from_bytes (bytes);
            } else if (url.has_prefix ("data:")) {
                var comma = url.index_of_char (',');
                if (comma > 0 && url.substring (0, comma).has_suffix (";base64")) {
                    var data = Base64.decode (url.substring (comma + 1));
                    stream = new MemoryInputStream.from_bytes (new Bytes (data));
                }
            }

            if (stream == null) {
                return null;
            }

            pixbuf = yield new Gdk.Pixbuf.from_stream_at_scale_async (stream, MAX_SIZE, MAX_SIZE, true, null);
        } catch (Error e) {
            debug ("Unable to load art %s: %s", url, e.message);
            return null;
        }

        if (pixbuf != null) {
            cache.insert (url, pixbuf);
            cache_order.push_tail (url);
            while (cache_order.length > CACHE_SIZE) {
                cache.remove (cache_order.pop_head ());
            }
        }

        return pixbuf;
    }
}
