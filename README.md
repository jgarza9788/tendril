# tendril

A Jellyfin music player for the terminal, written in [Odin](https://odin-lang.org) with
[hnoss](https://github.com/Huseynteymurzade28/hnoss) (a pure-Odin TUI library).

- **Many servers at once.** Log into as many Jellyfin servers as you like. Artists,
  albums, playlists, favourites and search results from all of them are merged into one list.
- **Browse** artists → albums → tracks, playlists, favourites, and search across artists,
  albums, playlists and tracks. Big libraries load in pages as you scroll, and
  `g` + a letter jumps straight there.
- **A real player.** Play/pause, seek, volume, shuffle, repeat, gapless playback, ReplayGain,
  a queue you can edit (remove, reorder, play next, save as a playlist), and your queue and
  position come back when you restart.
- **It feels good.** The whole UI re-tints itself from the current album cover. The cover is
  drawn in half-block pixels, with a live spectrum analyser of what mpv is actually playing,
  synced lyrics, a border that breathes with the bass, and four palettes.
- **It talks to the rest of your desktop.** Media keys, `playerctl` and status-bar widgets
  work through MPRIS. Plays and favourites are reported back to Jellyfin.
- **It adapts.** Three layouts by terminal width; every key is rebindable.

## Requirements

- Linux and a truecolor terminal (Alacritty, kitty, foot, Ghostty and friends)
- [mpv](https://mpv.io) (does the playback) and `curl` (talks to Jellyfin)
- Optional: PipeWire/PulseAudio tools (`parec`, `pactl`) for the real spectrum; without them
  the visualizer falls back to a gentle simulation
- To build: [Odin](https://odin-lang.org) (the `dev-2026-10` release was used)

## Install

**Prebuilt:** download `tendril-<version>-linux-x86_64.tar.gz` from the releases page and put
`tendril` on your `PATH`.

**From source:**

```
git clone --recurse-submodules https://github.com/jgarza9788/tendril
cd tendril
./build.sh run          # build and launch
./build.sh release      # dist/tendril-<version>-linux-x86_64.tar.gz
```

**Arch Linux:** `packaging/arch/PKGBUILD` (not yet published to the AUR).

On first launch a dialog asks for a server URL, username and password. Only the access token
is saved, in `~/.config/tendril/servers.json` with mode `0600`; your password is never stored.
`tendril --help` lists the file locations.

## Keys

Press `?` in the app for the list. Every key below is rebindable (see *Configuration*).

| Key | Action |
|---|---|
| `space` | play / pause |
| `n` `p` | next / previous (`p` restarts the track if it is more than 3 s in) |
| `s` `r` | shuffle / repeat (off → all → one) |
| `+` `-` | volume |
| `,` `.` or `←` `→` | seek 10 s |
| `1`–`5`, `[` `]` | Artists / Albums / Playlists / Search / Favourites, previous / next tab |
| `/` | search artists, albums, playlists and tracks |
| `enter` | open, or play |
| `esc` | back (in the search box: back to the list) |
| `a` `A` | add to the queue / play next |
| `f` `F` | favourite the selected item / the playing track |
| `l` | lyrics (synced when the server has them) |
| `d` `J` `K` | remove / move down / move up the selected queue row (queue pane focused) |
| `C` `W` | clear the queue / save it as a playlist |
| `g` + letter | jump to that letter in a long list |
| `R` | reload; retry a server that is down or expired |
| `T` | next theme |
| `v` | on a small terminal: cycle the middle pane (browser, queue, servers, now playing) |
| `tab` | change pane |
| `N` `X` | add / remove a server |
| `q` | quit |

The mouse works too: click tabs, rows, the transport buttons and the seek bar.

### Layouts

| Width | Layout |
|---|---|
| 110+ columns | servers and queue on the left, browser in the middle, now playing on the right |
| 76–109 | browser and now playing (`v` shows the queue and servers in place of the browser) |
| under 76 | one pane at a time (`v` cycles) |

## Configuration

Settings are optional, in `~/.config/tendril/config.json`. Anything you leave out keeps its default.

```json
{
  "volume": 70,
  "scrobble": true,
  "mpris": true,
  "theme": "abyss",
  "accent": "",
  "keys": {
    "next": ["n", "ctrl+n"],
    "help": ["f1"]
  }
}
```

- `theme`: `abyss`, `sunset`, `forest` or `mono`.
- `accent`: `"#rrggbb"` pins the accent colour. Empty means follow the album cover.
- `scrobble`: report plays to the server (play counts, "recently played").
- `mpris`: expose Tendril to media keys and `playerctl`.
- `keys`: an action name mapped to its keys. Setting an action replaces its default keys.
  Keys are a character (`n`, `N`, `+`), or `space`, `enter`, `esc`, `tab`, `backspace`,
  `up`, `down`, `left`, `right`, `f1`–`f12`, with an optional `ctrl+` or `alt+` prefix.
  Action names: `quit`, `play_pause`, `next`, `prev`, `shuffle`, `repeat`, `vol_up`, `vol_down`,
  `seek_fwd`, `seek_back`, `tab_1`…`tab_5`, `tab_next`, `tab_prev`, `search`, `add_server`,
  `remove_server`, `queue_add`, `play_next`, `queue_remove`, `queue_up`, `queue_down`,
  `queue_clear`, `save_playlist`, `favorite`, `favorite_current`, `lyrics`, `retry`, `jump`,
  `help`, `back`, `theme_next`, `view_cycle`.

Files: servers and tokens in `servers.json` (same folder), the last queue in
`~/.local/state/tendril/session.json`.

## Media keys

With `mpris` on (the default), Tendril appears on the session bus as
`org.mpris.MediaPlayer2.tendril`, so your desktop's media keys, `playerctl -p tendril …` and
widgets such as waybar's `mpris` module can read what is playing and control it (play/pause,
next, previous, seek, volume, shuffle, loop).

## Try it without a Jellyfin server

`tools/mock_jellyfin.py` is a small fake server with a few artists, albums, covers, lyrics and
an 8-second tone for each track:

```
python3 tools/mock_jellyfin.py 18096 homelab &
python3 tools/mock_jellyfin.py 18097 seedbox &
./build.sh run        # log in with 127.0.0.1:18096, any username, password: pw
```

Environment variables switch on a 702-artist library (`BIG=1`), failing audio (`ERR_ALBUM`,
`BAD_ALBUM`), token revocation (`REVOKE_FILE`) and a request log (`LOG_FILE`).

## How it works

```
src/
  main.odin     frame loop, drawing, key handling
  app.odin      app state, navigation, playback, queue, scrobbling, lyrics, cover art
  keys.odin     rebindable actions
  worker.odin   network jobs on short-lived threads; results come back through a queue
  theme.odin    palettes and the hnoss theme
  config/       servers.json and config.json
  session/      the saved queue
  jellyfin/     REST client (curl) and API calls
  player/       mpv controller (JSON IPC over a Unix socket) and the play queue
  viz/          audio spectrum: records mpv's stream with parec and runs an FFT
  mpris/        a small D-Bus client that implements the MPRIS player interface
```

The UI thread never waits on the network. Each request parses into its own arena, which is
freed when its view goes away. `./build.sh track` makes a build that prints a leak report on
exit; the tested sessions report zero leaks.

## Tests

```
./build.sh test
```

Unit tests cover the queue, paging, merging across servers, expiry and failure handling,
config and session files, key bindings, the FFT, the D-Bus wire format, and concurrent worker
jobs. They don't need a server or mpv (one test spawns `curl` against a closed port).

## Status

Tested against a Jellyfin 12.4 server and the mock server. Other versions are untested. CI
(type-check, tests, build) runs on every push. The Arch package has not been built yet.

## License

MIT. See `LICENSE`.
