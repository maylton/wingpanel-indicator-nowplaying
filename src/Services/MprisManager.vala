/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Watches the session bus for MPRIS players appearing and disappearing.
 */

public class NowPlaying.MprisManager : Object {
    public signal void player_added (Player player);
    public signal void player_removed (Player player);

    /* bus name -> player (also holds players still initializing) */
    private HashTable<string, Player> players;
    private GenericSet<string> ready;
    private DBusConnection? connection = null;
    private uint subscription = 0;

    construct {
        players = new HashTable<string, Player> (str_hash, str_equal);
        ready = new GenericSet<string> (str_hash, str_equal);
    }

    public async void start () {
        try {
            connection = yield Bus.get (BusType.SESSION);
        } catch (Error e) {
            critical ("Unable to connect to the session bus: %s", e.message);
            return;
        }

        subscription = connection.signal_subscribe (
            "org.freedesktop.DBus",
            "org.freedesktop.DBus",
            "NameOwnerChanged",
            "/org/freedesktop/DBus",
            "org.mpris.MediaPlayer2",
            DBusSignalFlags.MATCH_ARG0_NAMESPACE,
            on_name_owner_changed
        );

        try {
            var reply = yield connection.call (
                "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                "ListNames", null, new VariantType ("(as)"), DBusCallFlags.NONE, -1, null
            );

            foreach (unowned string name in reply.get_child_value (0).get_strv ()) {
                if (name.has_prefix (MPRIS_PREFIX)) {
                    add_player (name);
                }
            }
        } catch (Error e) {
            warning ("ListNames failed: %s", e.message);
        }
    }

    private void on_name_owner_changed (
        DBusConnection conn, string? sender, string path, string iface, string signal_name, Variant parameters
    ) {
        string name, old_owner, new_owner;
        parameters.get ("(sss)", out name, out old_owner, out new_owner);

        if (!name.has_prefix (MPRIS_PREFIX)) {
            return;
        }

        if (old_owner != "") {
            remove_player (name);
        }

        if (new_owner != "") {
            add_player (name);
        }
    }

    private void add_player (string name) {
        if (players.contains (name)) {
            return;
        }

        var player = new Player (name);
        players.insert (name, player);

        player.init.begin ((obj, res) => {
            bool ok = player.init.end (res);

            /* The player may have vanished while we were connecting */
            if (players.lookup (name) != player) {
                return;
            }

            if (ok) {
                ready.add (name);
                player_added (player);
            } else {
                players.remove (name);
            }
        });
    }

    private void remove_player (string name) {
        var player = players.lookup (name);
        if (player == null) {
            return;
        }

        players.remove (name);
        if (name in ready) {
            ready.remove (name);
            player_removed (player);
        }
    }
}
