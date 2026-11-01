# tendril: todo

`[x]` means built **and** checked (by tests, a live session, or both). Notes say how it was
checked and what is left.

## Correctness and robustness
1. [x] **Paging.** Lists load in pages of 200 per server as the cursor nears the end, with `loaded / total` shown. `g` + a letter jumps. *Checked live against a 702-artist mock: 200 → 400 → 600 → 702, and the jump lands on the right letter.*
2. [x] **Better failure handling.** The server is asked why a track failed; a 401 prompts a login, an unreachable server stops playback and offers `R`, other errors skip the track, and playback stops after 3 failures in a row. *Checked live: HTTP 500, a file that isn't audio, and a server that disappears mid-playback.*
3. [x] **Token expiry mid-session.** A 401 anywhere opens the login dialog for that server; `R` re-prompts if it is still expired. *Checked live, including re-login.*
4. [x] **Memory.** The queue owns its strings, shutdown frees everything, and `./build.sh track` prints a leak report. *A session that touches every feature reports 0 leaks, 0 bad frees. Two real leaks and an allocator mix-up were found and fixed this way.*
5. [x] **More tests.** 57 unit tests: config, session, settings, queue editing and ownership, paging, merge and sort across servers, stale results, expiry, failure streaks, key bindings, themes, lyrics timing, grouped search, layouts, the FFT, the D-Bus wire format, and 8 concurrent worker jobs. *`./build.sh test`. (The app tests run single-threaded because they share the worker queue.)*

## Features
6. [x] **Scrobbling.** Reports playback start, progress (every 10 s and on pause/resume) and stop. *Checked: the server received start and stop reports. The 10-second progress report is implemented but was not observed live (the demo tracks are 8 s).*
7. [x] **Favourites.** `f` favourites the selected item, `F` the playing track; hearts show in lists, the queue and now playing; a **5. Favourites** tab lists them. *Checked live against the mock. **Ratings are not implemented** (Jellyfin's like/dislike).*
8. [x] **Queue management.** Remove (`d`), reorder (`J`/`K`), clear (`C`), play next (`A`), save as a playlist (`W`). *Remove, reorder and save checked live; play next is covered by unit tests.*
9. [x] **Resume.** The queue, order, shuffle/repeat, volume and position come back after a restart; space resumes. *Checked live.*
10. [x] **Media keys and MPRIS.** Appears as `org.mpris.MediaPlayer2.tendril`; read status, metadata, position, volume; play/pause/next/previous/seek/volume/shuffle/loop/stop and change notifications. *Checked live with `playerctl` and `busctl`. A real media-key press on the keyboard was not tried (it goes through the same interface).*
11. [x] **Lyrics.** `l` shows them, synced to the position when the server provides timing. *Checked live against the mock. Unsynced lyrics just show from the top and don't scroll.*
12. [x] **Gapless playback.** The next track is handed to mpv shortly before the current one ends. *Checked: 3 of 4 tracks rolled over inside mpv without a reload. ReplayGain is switched on in mpv but its effect was not measured.*

## The "jealousy" part
13. [x] **A real visualizer.** Records mpv's own audio stream and runs an FFT. *Checked: a 1000 Hz tone lights the bar at ~1031 Hz. Falls back to a simulation when `parec` isn't available. Volume-compensated.*
14. [ ] **Smoother motion.** *Partly done:* views fade in, the focused border pulses with the bass, lyrics scroll with easing, and the colours ease between covers. **Not done:** animated list scrolling and an eased selection highlight (the list widget draws instantly).*
15. [x] **Themes.** Four palettes (`abyss`, `sunset`, `forest`, `mono`), `T` cycles, and `"accent": "#rrggbb"` pins the accent instead of following the cover. *Checked live.*
16. [x] **Adaptive layout.** Wide (110+), medium (76–109) and narrow (under 76) layouts; `v` cycles the middle pane on small terminals. *Checked live at 150, 90 and 60 columns.*
17. [ ] **Real cover images (kitty graphics).** *Skipped on request: the half-block cover stays.*

## Housekeeping
18. [x] **Search across everything.** One search returns artists, albums, playlists and tracks, grouped in that order and tagged by type. *Checked live.*
19. [x] **Config file.** `~/.config/tendril/config.json`: volume, scrobbling, MPRIS, theme, accent and rebindable keys. *Checked live (volume, theme, accent, a custom key). Unknown keys are reported on startup.*
20. [ ] **Packaging.** Done: `./build.sh release` (tarball), `--version`/`--help`, MIT license, `packaging/arch/PKGBUILD`, a GitHub Actions workflow. *The PKGBUILD has not been built with `makepkg` and the workflow has not run yet.*

## Known gaps
- Tested against one real server (Jellyfin 12.4) and a mock. Other versions are untested.
- Ratings, unsynced-lyric scrolling, animated list scrolling, and a measured ReplayGain check are the open items above.
- The visualizer listens to mpv's stream, so it needs PipeWire/PulseAudio tools to be real.
