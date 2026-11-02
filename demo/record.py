#!/usr/bin/env python3
"""Records the demo: starts two mock Jellyfin servers (tools/mock_jellyfin.py in DEMO mode), runs the real tendril in
tmux with its audio muted, drives a scripted tour, and captures the screen ~30 times a second to
~/.cache/tendril-demo/capture.pkl. make.py turns that into the film.

    python3 demo/record.py           record the whole tour
    python3 demo/record.py --scene C record one scene only (for tuning; skips the others)

The tour never touches anything outside its own tmux session and its own bus name."""
import json, os, pickle, re, shutil, signal, subprocess, sys, threading, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.expanduser("~/.cache/tendril-demo")
SESSION = "tdemo"
COLS, ROWS = 148, 38
PORTS = {"homelab": 18096, "seedbox": 18097}

ANSI = re.compile(r"\x1b\[[0-9;]*m")
state = {"cols": COLS, "rows": ROWS, "t0": 0.0}
frames, captions, keys, cmds, scenes_log = [], [], [], [], []
stop_capture = threading.Event()


def now(): return time.monotonic() - state["t0"]
def sh(*a, **k): return subprocess.run([str(x) for x in a], capture_output=True, text=True, **k)
def tmux(*a): return sh("tmux", *a)


def at(t):
    """Wait until `t` seconds into the recording."""
    d = t - now()
    if d > 0: time.sleep(d)


def send(*k): tmux("send-keys", "-t", SESSION, *k)


def key(name, label=None, show=True):
    send(name)
    if show: keys.append((now(), label or name))


def typed(text, cps=5.0, label_first="/"):
    for ch in text:
        tmux("send-keys", "-t", SESSION, "-l", ch)
        time.sleep(1 / cps)


def caption(tag, text, t0, t1): captions.append((t0, t1, tag, text))


def screen():
    return ANSI.sub("", tmux("capture-pane", "-t", SESSION, "-p").stdout)


def resize(cols, rows):
    tmux("resize-window", "-t", SESSION, "-x", str(cols), "-y", str(rows))
    state["cols"], state["rows"] = cols, rows


def center_lines():
    """(selected index, [names]) of the browser list in the middle pane."""
    sel, names = None, []
    for line in screen().split("\n"):
        seg = line[41:112] if len(line) > 41 else ""
        m = re.match(r"│([› ]) +(\S.*?)\s{2,}", seg + "  ")
        if m and "─" not in seg[:3]:
            names.append(m.group(2).strip())
            if m.group(1) == "›": sel = len(names) - 1
    return sel, names


def goto(name, pace=0.32):
    """Move the browser cursor onto the row whose text starts with `name`."""
    sel, names = center_lines()
    want = next((i for i, n in enumerate(names) if name.lower() in n.lower()), None)
    if want is None or sel is None:
        print(f"  ! goto {name!r}: sel={sel} names={names[:6]}", file=sys.stderr); return
    step = "Down" if want > sel else "Up"
    for i in range(abs(want - sel)):
        key(step, "↓" if step == "Down" else "↑", show=(i == 0))
        time.sleep(pace)


def breadcrumb():
    for line in screen().split("\n")[1:3]:
        m = re.search(r"╭ ([^─]*?) ─", line[41:])
        if m: return m.group(1).strip()
    return "?"


def my_player():
    """The playerctl name of THIS recording's tendril (never the user's own, which holds the plain name)."""
    pane = tmux("list-panes", "-t", SESSION, "-F", "#{pane_pid}").stdout.split()[0]
    pids = {pane} | set(sh("pgrep", "-P", pane).stdout.split())
    out = sh("busctl", "--user", "list", "--no-legend").stdout
    for ln in out.splitlines():
        f = ln.split()
        if f and f[0].startswith("org.mpris.MediaPlayer2.tendril") and f[1] in pids:
            return f[0].removeprefix("org.mpris.MediaPlayer2.")
    return None


def playerctl(player, *args): return sh("playerctl", "-p", player, *args)


# ---- environment --------------------------------------------------------------------------------------------------------

def setup():
    shutil.rmtree(WORK, ignore_errors=True)
    for d in ("config/tendril", "state", "mpv"): os.makedirs(f"{WORK}/{d}")
    open(f"{WORK}/mpv/mpv.conf", "w").write("ao=null\n")                      # no sound while recording
    dev = "tendril-demo-0001"
    json.dump({"device_id": dev, "servers": [
        {"id": f"s{i + 1}", "name": n, "url": f"http://127.0.0.1:{p}", "user": "justin", "user_id": f"u-{n}", "token": f"tok-{n}", "device_id": dev}
        for i, (n, p) in enumerate(PORTS.items())]}, open(f"{WORK}/config/tendril/servers.json", "w"))
    for p in PORTS.values(): sh("fuser", "-k", f"{p}/tcp")
    time.sleep(0.5)
    procs = []
    for (name, port), variant in zip(PORTS.items(), "ab"):
        procs.append(subprocess.Popen([sys.executable, f"{REPO}/tools/mock_jellyfin.py", str(port), name], cwd=REPO,
                                      env={**os.environ, "DEMO": variant}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    time.sleep(3.5)
    tmux("kill-session", "-t", SESSION)
    cmd = f"env XDG_CONFIG_HOME={WORK}/config XDG_STATE_HOME={WORK}/state MPV_HOME={WORK}/mpv {REPO}/bin/tendril 2>{WORK}/app.err; sleep 60"
    tmux("new-session", "-d", "-s", SESSION, "-x", str(COLS), "-y", str(ROWS), cmd)
    time.sleep(3.0)
    return procs


def capture_loop():
    last = None
    while not stop_capture.is_set():
        t = now()
        txt = tmux("capture-pane", "-t", SESSION, "-p", "-e").stdout
        if txt != last or not frames or frames[-1][3] != (state["cols"], state["rows"]):
            frames.append((t, txt, state["cols"], state["rows"]) if False else (t, txt, state["cols"], state["rows"]))
            last = txt
        else:
            frames[-1] = frames[-1]
        time.sleep(max(0.0, 1 / 30 - (now() - t)))


# ---- the tour -----------------------------------------------------------------------------------------------------------
# Every scene starts on a whole second so the soundtrack's beats (0.5 s) line up with the captions.

def run_tour(only=None):
    def scene(name, t0, dur, tag, text):
        scenes_log.append((t0, name))
        caption(tag, text, t0 + 0.15, t0 + dur - 0.15)
        at(t0)
        print(f"[{t0:5.1f}s] scene {name}: {text}")

    do = lambda n: only is None or only == n

    # A: two servers, one list
    scene("A", 0.0, 5.0, "servers", "Every server. One library.")
    at(0.9); goto("Neon Medusa", 0.5)
    at(4.4)

    # B: browse, play, and the UI takes the cover's colours
    scene("B", 5.0, 8.0, "browse", "Browse. Play. Look good doing it.")
    at(5.6); key("Enter", "⏎")
    at(6.9); key("Enter", "⏎")
    at(8.1); key("Enter", "⏎")
    at(12.6)

    # C: other albums, other colours
    scene("C", 13.0, 9.0, "colour", "The whole UI repaints from the cover.")
    at(13.4); key("Escape", "esc"); time.sleep(0.5); key("Escape", "esc", show=False)
    at(14.5); goto("Kraken Jones", 0.45)
    at(15.6); key("Enter", "⏎"); time.sleep(1.0); key("Enter", "⏎", show=False); time.sleep(1.0); key("Enter", "⏎", show=False)
    at(19.0); key("Escape", "esc", show=False); time.sleep(0.5); key("Escape", "esc", show=False)
    at(19.8); goto("Lanternfish", 0.45)
    at(20.6); key("Enter", "⏎", show=False); time.sleep(0.9); key("Enter", "⏎", show=False); time.sleep(0.9); key("Enter", "⏎", show=False)
    at(21.9)

    # D: lyrics
    scene("D", 22.0, 6.5, "lyrics", "Synced lyrics. Obviously.")
    at(22.5); key("l", "l")
    at(28.2); key("l", "l", show=False)

    # E: search
    scene("E", 28.5, 7.0, "search", "Search everything.")
    at(28.9); key("/", "/")
    at(29.5); typed("tid", cps=4.2)
    at(31.0); key("Enter", "⏎")
    at(32.8); key("Down", "↓", show=False); time.sleep(0.4); key("Down", "↓", show=False)
    at(34.8)

    # F: heart it, queue it, reorder it
    scene("F", 35.5, 8.0, "queue", "Heart it. Queue it. Reorder it.")
    at(35.7); goto("Tidepool", 0.3)
    at(36.4); key("f", "f")
    at(36.9); key("a", "a")
    at(37.6); key("Down", "↓", show=False)
    at(38.1); key("a", "a", show=False); time.sleep(0.4); key("f", "f", show=False)
    at(38.9); key("Down", "↓", show=False)
    at(39.4); key("a", "a", show=False)
    at(40.3); key("Tab", "tab"); time.sleep(0.4); key("Tab", "tab", show=False)
    at(41.2); key("J", "J")
    at(42.0); key("J", "J", show=False)
    at(42.8); key("K", "K")
    at(43.3)

    # G: media keys
    scene("G", 43.5, 5.5, "media keys", "Media keys just work.")
    player = my_player()
    print("  player:", player)
    at(44.2)
    if player:
        cmds.append((now(), now() + 1.4, f"playerctl next")); playerctl(player, "next")
        at(46.0); cmds.append((now(), now() + 1.2, "playerctl pause")); playerctl(player, "pause")
        at(47.4); cmds.append((now(), now() + 1.2, "playerctl play")); playerctl(player, "play")
    at(48.9)

    # H: it fits any window
    scene("H", 49.0, 7.0, "layout", "Fits any window.")
    at(49.8); resize(100, 32)
    at(52.3); resize(66, 28)
    at(54.2); key("v", "v"); time.sleep(0.9); key("v", "v", show=False)
    at(55.9); resize(COLS, ROWS)

    # I: themes
    scene("I", 56.0, 5.5, "themes", "Make it yours.")
    at(56.6); key("T", "T")
    at(57.8); key("T", "T", show=False)
    at(59.0); key("T", "T", show=False)
    at(60.2); key("T", "T", show=False)
    at(61.4)


def main():
    only = sys.argv[sys.argv.index("--scene") + 1] if "--scene" in sys.argv else None
    subprocess.run([os.path.join(REPO, "build.sh"), "build"], check=True, stdout=subprocess.DEVNULL)
    procs = setup()
    state["t0"] = time.monotonic()
    th = threading.Thread(target=capture_loop, daemon=True); th.start()
    try:
        run_tour(only)
    finally:
        time.sleep(0.4)
        stop_capture.set(); th.join()
        tmux("send-keys", "-t", SESSION, "q"); time.sleep(1.0); tmux("kill-session", "-t", SESSION)
        for p in procs: p.terminate()
    out = {"frames": frames, "captions": captions, "keys": keys, "cmds": cmds, "scenes": scenes_log, "duration": now()}
    pickle.dump(out, open(f"{WORK}/capture.pkl", "wb"))
    print(f"recorded {len(frames)} distinct frames over {out['duration']:.1f}s -> {WORK}/capture.pkl")


if __name__ == "__main__":
    main()
