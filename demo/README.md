# The demo film

`python3 demo/record.py` then `python3 demo/make.py` produce a 72-second, 1080p, 30 fps film
(`~/Videos/Tendirl-demo.mp4`) of the real app, with a synthesized soundtrack.

| File | Does |
|---|---|
| `record.py` | Starts two demo servers (`tools/mock_jellyfin.py` with `DEMO=a` / `b`), runs `bin/tendril` in tmux with its audio muted, drives a scripted tour, and captures the screen about 30 times a second. It talks to its own bus name only, never another running Tendril. |
| `term.py` | Draws a captured terminal screen as an image, cell by cell (cover art and spectrum bars from exact geometry, so there are no seams). |
| `gfx.py` | The jellyfish, the hook and outro cards, caption pills, key caps and the wipe, drawn with cairo. |
| `audio.py` | The soundtrack: pads, bass, arps and drums at 120 BPM, built from the CaptainFM trailer synth. Every scene starts on a beat. |
| `make.py` | Composes every frame across all cores, encodes the film, and with `--stills` writes the README's screenshots and `docs/demo.gif`. |
| `contact.py` | Renders a contact sheet of recorded frames, for checking the tour: `python3 demo/contact.py sheet.png 2 7 13 ...`. |

Needs `tmux`, `ffmpeg`, `playerctl`, Python with `numpy`, `Pillow` and `pycairo`, and the Adwaita Mono and
JetBrainsMono Nerd fonts. Frames and the recording live in `~/.cache/tendril-demo/`. Edit the tour in `run_tour()` in
`record.py`; scene lengths are whole seconds so the beats line up.
