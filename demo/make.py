#!/usr/bin/env python3
"""Turns the recording (record.py) into the film: ~/Videos/Tendirl-demo.mp4, 1920x1080, 30 fps.

    python3 demo/make.py              full render (uses every core; a few minutes)
    python3 demo/make.py --preview    one frame in twelve, to look at the timing quickly
    python3 demo/make.py --stills     also write the README's screenshots and demo.gif (needs a finished render)

The film is: a 4.5 s hook (jellyfish, name, tagline), the recorded tour with captions, key caps and wipes, and a 6 s outro.
Every frame of the middle part is the real app, drawn from what tmux captured."""
import bisect, multiprocessing as mp, os, pickle, re, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import gfx
from term import Renderer, DEFAULT_BG

W, H, FPS = 1920, 1080, 30
HOOK, TERM, OUTRO = 4.5, 62.0, 6.0
TOTAL = HOOK + TERM + OUTRO
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.expanduser("~/.cache/tendril-demo")
FRAMES = os.path.join(WORK, "frames")
OUT = os.path.expanduser("~/Videos/Tendirl-demo.mp4")
TAG_COLORS = [gfx.CYAN, gfx.TEAL, gfx.VIOLET, gfx.MAGENTA, gfx.CYAN, gfx.TEAL, gfx.VIOLET, gfx.MAGENTA, gfx.CYAN]
CHROME_TOP, CHROME_PAD = 40, 10
AREA_TOP, AREA_BOTTOM = 34, 936

# ---- shared, read-only state (set up in the parent, inherited by the workers) -------------------------------------------

cap = pickle.load(open(os.path.join(WORK, "capture.pkl"), "rb"))
FR = cap["frames"]
FT = [f[0] for f in FR]
CAPTIONS = [(a + HOOK, b + HOOK, tag, text) for a, b, tag, text in cap["captions"]]
KEYS = [(t + HOOK, label) for t, label in cap["keys"]]
CMDS = [(a + HOOK, b + HOOK, text) for a, b, text in cap["cmds"]]
SCENE_STARTS = [t + HOOK for t, name in cap["scenes"] if name != "A"]
RESIZES = [FR[i][0] + HOOK for i in range(1, len(FR)) if FR[i][2:] != FR[i - 1][2:]]
WIPES = sorted([HOOK, HOOK + TERM] + SCENE_STARTS + RESIZES[:: 1])
HEARTS = [t + HOOK for t, label in cap["keys"] if label == "f"]
HALF = re.compile(r"38;2;(\d+);(\d+);(\d+)m(?:\x1b\[48;2;\d+;\d+;\d+m)?▀")

def cover_color(ansi):
    m = HALF.findall(ansi)
    if len(m) < 20: return None
    a = np.array(m, dtype=np.float32)
    w = (a.max(1) - a.min(1)) ** 2 + 1                     # favour the saturated pixels, like the app does
    c = (a * w[:, None]).sum(0) / w.sum()
    c = c / max(c.max(), 1) * 255 if c.max() < 170 else c
    return tuple(float(x) / 255 for x in np.clip(c, 0, 255))

def accent_series():
    """The accent colour for every video frame of the tour: the cover's colour, eased."""
    raw = [cover_color(f[1]) for f in FR]
    out, cur = [], gfx.CYAN
    for i in range(int(TERM * FPS)):
        ct = i / FPS
        j = max(bisect.bisect_right(FT, ct) - 1, 0)
        target = raw[j] or gfx.CYAN
        cur = gfx.mix(cur, target, 0.08)
        out.append(cur)
    return out
ACCENT = accent_series()

_w = {}
def init_worker():
    _w["r"] = Renderer()
    _w["cache"] = {}
    _w["chrome"] = {}
    _w["small"] = {}
    _w["title_font"] = ImageFont.truetype("/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf", 17)

# ---- pieces ----------------------------------------------------------------------------------------------------------------

def tint(c): return tuple(int(x * 255) for x in c)

def term_image(idx):
    c = _w["cache"]
    if idx not in c:
        if len(c) > 4: c.clear()
        f = FR[idx]
        c[idx] = _w["r"].render(f[1], f[2], f[3]).convert("RGB")
    return c[idx]

def window_parts(tw, th):
    """(rounded mask, glow mask, frame image with the titlebar) for a terminal of tw x th pixels; cached."""
    key = (tw, th)
    ch = _w["chrome"]
    if key not in ch:
        ww, wh = tw + 2 * CHROME_PAD, th + CHROME_TOP + CHROME_PAD
        mask = Image.new("L", (ww, wh), 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, ww - 1, wh - 1), 16, fill=255)
        glow = Image.new("L", (ww + 240, wh + 240), 0)
        ImageDraw.Draw(glow).rounded_rectangle((120, 120, 120 + ww, 120 + wh), 22, fill=255)
        glow = glow.filter(ImageFilter.GaussianBlur(46))
        frame = Image.new("RGB", (ww, wh), tint(gfx.ABYSS))
        d = ImageDraw.Draw(frame)
        d.rectangle((0, 0, ww, CHROME_TOP - 2), fill=tint(gfx.mix(gfx.DEEP, gfx.TRENCH, 0.35)))
        for i, col in enumerate(((255, 95, 86), (255, 189, 46), (39, 201, 63))):
            d.ellipse((18 + i * 26, 12, 18 + i * 26 + 14, 26), fill=col)
        title = "tendril"
        tw_ = _w["title_font"].getlength(title)
        d.text(((ww - tw_) / 2, 10), title, font=_w["title_font"], fill=tint(gfx.MIST))
        ch[key] = (mask, glow, frame)
    return ch[key]

def fade_alpha(img, a):
    if a >= 0.999: return img
    r = img.copy()
    r.putalpha(r.getchannel("A").point(lambda p: int(p * max(a, 0))))
    return r

def paste_center(canvas, img, cx, cy, a=1.0):
    img = fade_alpha(img, a)
    canvas.alpha_composite(img, (int(cx - img.width / 2), int(cy - img.height / 2)))

def small(kind, *args):
    c = _w["small"]
    key = (kind,) + args
    if key not in c:
        c[key] = {"cap": lambda: gfx.caption_img(args[1], args[2], TAG_COLORS[args[0] % len(TAG_COLORS)]),
                  "key": lambda: gfx.keycap_img(args[0]), "cmd": lambda: gfx.command_img(args[0])}[kind]()
    return c[key]

def wipe_overlay(canvas, t):
    for wc in WIPES:
        u = (t - (wc - 0.28)) / 0.82
        if 0 <= u <= 1:
            canvas.alpha_composite(gfx.wipe_img(W, H, u)); return

def overlays(canvas, t):
    # captions
    for i, (a, b, tag, text) in enumerate(CAPTIONS):
        if a <= t <= b:
            u, v = (t - a) / 0.4, (b - t) / 0.3
            al = min(gfx.smooth(u), gfx.smooth(v))
            paste_center(canvas, small("cap", i, tag, text), W / 2, H - 100 + (1 - gfx.ease_out(u)) * 30, al)
    # the command pill (media-key scene)
    for a, b, text in CMDS:
        if a <= t <= b:
            u, v = (t - a) / 0.3, (b - t) / 0.3
            paste_center(canvas, small("cmd", text), W / 2, H - 218 + (1 - gfx.ease_out(u)) * 24, min(gfx.smooth(u), gfx.smooth(v)))
    # key caps: the last few, newest on the right
    recent = [(tk, lb) for tk, lb in KEYS if 0 <= t - tk <= 1.15][-3:]
    x = W - 70
    for tk, lb in reversed(recent):
        age = t - tk
        img = small("key", lb)
        al = gfx.smooth((1.15 - age) / 0.35)
        paste_center(canvas, img, x - img.width / 2, H - 100 + (1 - gfx.ease_out(age / 0.14)) * 14, al)
        x -= img.width + 14

def terminal_frame(i, t):
    ct = t - HOOK
    idx = max(bisect.bisect_right(FT, ct) - 1, 0)
    acc = ACCENT[min(int(ct * FPS), len(ACCENT) - 1)]
    s, c = gfx.new_surface(W, H)
    gfx.draw_background(c, W, H, t, accent=acc)
    canvas = gfx.to_pil(s).convert("RGB")

    img = term_image(idx)
    tw, th = img.size
    mask, glow, frame = window_parts(tw, th)
    ww, wh = frame.size
    x = (W - ww) // 2
    y = AREA_TOP + (AREA_BOTTOM - AREA_TOP - wh) // 2
    pop = gfx.smooth(ct / 0.7)
    y += int((1 - gfx.ease_out(ct / 0.7)) * 36)
    win = frame.copy(); win.paste(img, (CHROME_PAD, CHROME_TOP))
    gmask = glow.point(lambda p: int(p * 0.5 * (0.6 + 0.4 * pop)))
    canvas.paste(Image.new("RGB", glow.size, tint(acc)), (x - 120, y - 120), gmask)
    canvas.paste(win, (x, y), mask.point(lambda p: int(p * pop)))
    rgba = canvas.convert("RGBA")
    overlays(rgba, t)
    return rgba

def render_frame(i):
    t = i / FPS
    if t < HOOK:
        s, c = gfx.new_surface(W, H); gfx.hook_frame(c, W, H, t); canvas = gfx.to_pil(s)
    elif t < HOOK + TERM:
        canvas = terminal_frame(i, t)
    else:
        s, c = gfx.new_surface(W, H); gfx.outro_frame(c, W, H, t - HOOK - TERM, OUTRO); canvas = gfx.to_pil(s)
    canvas = canvas.convert("RGBA")
    wipe_overlay(canvas, t)
    canvas.convert("RGB").save(os.path.join(FRAMES, f"{i:05d}.png"), compress_level=1)
    return i

def chunk(args):
    lo, hi, step = args
    for i in range(lo, hi, step): render_frame(i)
    return hi - lo

# ---- driver -----------------------------------------------------------------------------------------------------------------

def run(*cmd):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode: sys.exit(f"failed: {' '.join(map(str, cmd[:6]))}\n{r.stderr[-800:]}")

def render_all(step):
    os.makedirs(FRAMES, exist_ok=True)
    n = int(TOTAL * FPS)
    for f in os.listdir(FRAMES): os.remove(os.path.join(FRAMES, f))
    jobs = [(lo, min(lo + 24, n), step) for lo in range(0, n, 24)]
    t0 = time.time(); done = 0
    with mp.Pool(max(os.cpu_count() - 1, 1), initializer=init_worker) as pool:
        for k in pool.imap_unordered(chunk, jobs):
            done += k
            print(f"\r  frames {done}/{n}  {time.time() - t0:5.0f}s", end="", flush=True)
    print()

def encode():
    import audio
    wav = os.path.join(WORK, "soundtrack.wav")
    audio.make(wav, TOTAL, HOOK, HOOK + TERM, WIPES, [t for t, _ in KEYS], HEARTS)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    run("ffmpeg", "-v", "error", "-y", "-framerate", FPS, "-i", os.path.join(FRAMES, "%05d.png"), "-i", wav,
        "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p", "-r", FPS,
        "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-shortest", OUT)
    print("wrote", OUT, f"{os.path.getsize(OUT) / 1e6:.1f} MB")

def stills():
    """README assets from the finished film: a few screenshots and a short looping GIF."""
    docs = os.path.join(REPO, "docs"); os.makedirs(docs, exist_ok=True)
    shots = {"player": 10.5, "colours": 19.0, "lyrics": 26.0, "search": 33.5, "queue": 43.0, "layouts": 54.0}
    for name, ct in shots.items():
        run("ffmpeg", "-v", "error", "-y", "-ss", ct + HOOK, "-i", OUT, "-frames:v", 1, "-vf", "scale=1280:-1:flags=lanczos", os.path.join(docs, f"screenshot-{name}.png"))
    segs = [(0.6, 3.6), (HOOK + 5.5, HOOK + 11.5), (HOOK + 22.8, HOOK + 26.8), (HOOK + 28.8, HOOK + 33.3)]
    parts = []
    for k, (a, b) in enumerate(segs):
        p = os.path.join(WORK, f"seg{k}.mp4")
        run("ffmpeg", "-v", "error", "-y", "-ss", a, "-t", b - a, "-i", OUT, "-an", "-vf", "fps=12,scale=880:-2:flags=lanczos", p)
        parts.append(p)
    lst = os.path.join(WORK, "segs.txt")
    open(lst, "w").write("".join(f"file '{p}'\n" for p in parts))
    joined = os.path.join(WORK, "joined.mp4")
    run("ffmpeg", "-v", "error", "-y", "-f", "concat", "-safe", 0, "-i", lst, "-c", "copy", joined)
    pal = os.path.join(WORK, "palette.png")
    run("ffmpeg", "-v", "error", "-y", "-i", joined, "-vf", "palettegen=max_colors=96:stats_mode=diff", pal)
    gif = os.path.join(docs, "demo.gif")
    run("ffmpeg", "-v", "error", "-y", "-i", joined, "-i", pal, "-lavfi", "paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle", "-loop", 0, gif)
    print("docs:", sorted(os.listdir(docs)), f"gif {os.path.getsize(gif) / 1e6:.1f} MB")

if __name__ == "__main__":
    if "--stills" in sys.argv:
        stills()
    else:
        step = 12 if "--preview" in sys.argv else 1
        print(f"{len(FR)} captured frames, {TOTAL:.1f}s film, {len(WIPES)} wipes, {len(KEYS)} key caps, {len(CAPTIONS)} captions")
        render_all(step)
        if step == 1: encode()
