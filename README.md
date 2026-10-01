# Now Playing — media indicator for elementary OS

<img width="378" height="526" alt="now playing" src="https://github.com/user-attachments/assets/fe163eb6-b122-426b-884f-f96a855aa3ef" />


A Wingpanel indicator for **elementary OS 8.x** that shows what's playing in the
panel and full controls in a popover. Works with any **MPRIS** player (Spotify,
VLC, Rhythmbox, web browsers, YouTube Music clients…).

🇧🇷 [Leia em português](README.pt-BR.md)

<!-- Add a screenshot at docs/screenshot.png and uncomment:
![Screenshot](docs/screenshot.png)
-->

## Features

- **Panel:** icon + "Title — Artist". Long titles keep scrolling while music
  plays. Middle-click to play/pause.
- **Lyrics in the panel** (optional): show the line being sung instead of the
  title; long lines glide across while they're sung.
- **Popover:** album art, track info, seek bar, shuffle, previous, play/pause,
  next and repeat. Tabs when several players are open.
- **Vinyl mode:** a record spinning at 33⅓ rpm with the album art as its label;
  the tonearm drops on play, lifts on pause and moves inwards as the song goes.
- **Synced lyrics:** the current line is highlighted and centred; click a line
  to jump to it.
- **Modes:** header buttons, or double-click the art (vinyl) / triple-click
  (lyrics). The mode is remembered per app.
- **Preferences** inside the popover. Respects the system "reduce motion"
  setting. Translated to Brazilian Portuguese.

## Lyrics sources

Tried in this order; synced lyrics always win over plain text:

1. **The player** — lyrics sent in the MPRIS metadata (`xesam:asText`).
2. **Local `.lrc` files** — next to the song (`song.mp3` → `song.lrc`) or in
   `~/.lyrics/Artist - Title.lrc` (or `~/.lyrics/Title.lrc`).
3. **[LRCLIB](https://lrclib.net)** — free, open lyrics database (on by default).
4. **NetEase Cloud Music** — large catalogue of Asian music. Unofficial access
   that may stop working; off by default.

## Build and install

```bash
sudo apt install valac meson libwingpanel-dev libgee-0.8-dev libgtk-3-dev \
    libsoup-3.0-dev libjson-glib-dev gettext

git clone https://github.com/maylton/wingpanel-indicator-nowplaying.git
cd wingpanel-indicator-nowplaying
meson setup build --prefix=/usr
ninja -C build
sudo ninja -C build install
killall io.elementary.wingpanel   # the panel restarts by itself
```

To uninstall: `sudo ninja -C build uninstall && killall io.elementary.wingpanel`.

## Language

The interface is in English and follows your system language when a
translation exists. Available translations: Brazilian Portuguese (`pt_BR`).

### Translating

1. Copy `po/nowplaying-indicator.pot` to `po/<language>.po` (e.g. `po/es.po`)
   and translate the `msgstr` lines (a tool like Poedit helps).
2. Add the language code to `po/LINGUAS`.
3. Rebuild and install. To refresh the template after changing strings:
   `ninja -C build nowplaying-indicator-pot`.

## Settings from the terminal

```bash
gsettings list-recursively io.github.maylton.nowplaying
```

## Notes

- Built for Wingpanel 8 (GTK 3). elementary OS 9 is expected to move the panel
  to GTK 4, which will need a port of the widgets; the code under
  `src/Services/` doesn't depend on GTK.
- Not affiliated with elementary, Inc.

## License

GPL-3.0-or-later
