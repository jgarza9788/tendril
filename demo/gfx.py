"""Cairo drawing for the demo film: the sea background, the jellyfish, the hook and outro cards, caption pills,
key caps and the wipe between scenes. Everything returns or draws onto a cairo surface; to_pil() turns one into a
PIL image so make.py can composite it with the terminal frames."""
import math
import cairo
import numpy as np
from PIL import Image

TAU = math.tau
def rgb(r, g, b): return (r / 255, g / 255, b / 255)
ABYSS = rgb(7, 11, 26); DEEP = rgb(13, 22, 46); TRENCH = rgb(22, 35, 69)
CYAN = rgb(45, 240, 255); TEAL = rgb(25, 211, 176); VIOLET = rgb(139, 92, 255); MAGENTA = rgb(255, 61, 216)
FOAM = rgb(230, 241, 255); MIST = rgb(107, 122, 168)
GLOW = [TEAL, CYAN, VIOLET, MAGENTA]
SANS, MONO = "Noto Sans", "JetBrainsMono Nerd Font"


def smooth(u):
    u = min(max(u, 0.0), 1.0)
    return u * u * (3 - 2 * u)

def ease_out(u):
    u = min(max(u, 0.0), 1.0)
    return 1 - (1 - u) ** 3

def lerp(a, b, t): return a + (b - a) * t
def mix(c1, c2, t): return tuple(lerp(c1[i], c2[i], t) for i in range(3))

def gradient(stops, t):
    t = min(max(t, 0.0), 1.0) * (len(stops) - 1)
    i = min(int(t), len(stops) - 2)
    return mix(stops[i], stops[i + 1], t - i)

def new_surface(w, h):
    s = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
    return s, cairo.Context(s)

def to_pil(surface):
    """cairo's premultiplied BGRA -> a straight-alpha RGBA PIL image."""
    w, h = surface.get_width(), surface.get_height()
    a = np.frombuffer(surface.get_data(), dtype=np.uint8).reshape(h, w, 4).astype(np.float32)
    alpha = a[..., 3:4]
    rgb_ = np.where(alpha > 0, a[..., :3] / np.maximum(alpha, 1) * 255, 0)[..., ::-1]
    return Image.fromarray(np.concatenate([np.clip(rgb_, 0, 255), alpha], axis=2).astype(np.uint8), "RGBA")

def font(ctx, family, size, bold=False):
    ctx.select_font_face(family, cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD if bold else cairo.FONT_WEIGHT_NORMAL)
    ctx.set_font_size(size)

def text_width(ctx, s, spacing=0.0):
    return ctx.text_extents(s).x_advance + spacing * max(len(s) - 1, 0)

def draw_text(ctx, s, x, y, color, anchor="center", spacing=0.0, alpha=1.0):
    ctx.set_source_rgba(*color, alpha)
    w = text_width(ctx, s, spacing)
    x0 = x - w / 2 if anchor == "center" else (x - w if anchor == "right" else x)
    if spacing == 0:
        ctx.move_to(x0, y); ctx.show_text(s)
    else:
        for ch in s:
            ctx.move_to(x0, y); ctx.show_text(ch); x0 += ctx.text_extents(ch).x_advance + spacing
    return w

def rounded(ctx, x, y, w, h, r):
    r = min(r, w / 2, h / 2)
    ctx.new_sub_path()
    ctx.arc(x + w - r, y + r, r, -TAU / 4, 0)
    ctx.arc(x + w - r, y + h - r, r, 0, TAU / 4)
    ctx.arc(x + r, y + h - r, r, TAU / 4, TAU / 2)
    ctx.arc(x + r, y + r, r, TAU / 2, 3 * TAU / 4)
    ctx.close_path()

# ---- the sea ------------------------------------------------------------------------------------------------------

_RNG = np.random.default_rng(7)
PLANKTON = [(_RNG.random(), _RNG.random(), 0.01 + 0.03 * _RNG.random(), 1 + 3 * _RNG.random() ** 2, _RNG.random() * TAU, _RNG.integers(0, 4))
            for _ in range(110)]

def draw_background(ctx, W, H, t, accent=CYAN, glow=1.0):
    """Deep water: a vertical gradient, slow tinted light, and drifting plankton."""
    g = cairo.LinearGradient(0, 0, 0, H)
    g.add_color_stop_rgb(0, *mix(ABYSS, DEEP, 0.55)); g.add_color_stop_rgb(1, *ABYSS)
    ctx.set_source(g); ctx.paint()
    for k, (fx, fy, r, a) in enumerate([(0.18, 0.25, 0.70, 0.16), (0.82, 0.70, 0.62, 0.13), (0.55, 0.05, 0.55, 0.10)]):
        cx = W * (fx + 0.05 * math.sin(t * 0.17 + k * 2.1)); cy = H * (fy + 0.05 * math.cos(t * 0.13 + k))
        rg = cairo.RadialGradient(cx, cy, 0, cx, cy, H * r)
        c = mix(accent, VIOLET if k % 2 else TEAL, 0.35 * (k + 1) / 3)
        rg.add_color_stop_rgba(0, *c, a * glow); rg.add_color_stop_rgba(1, *c, 0)
        ctx.set_source(rg); ctx.paint()
    for (x0, y0, speed, size, ph, col) in PLANKTON:
        x = (x0 * W + 40 * math.sin(t * 0.35 + ph)) % W
        y = (y0 * H - t * speed * H) % H
        tw = 0.35 + 0.65 * (0.5 + 0.5 * math.sin(t * 1.6 + ph * 3))
        c = mix(GLOW[col], accent, 0.4)
        rg = cairo.RadialGradient(x, y, 0, x, y, size * 5)
        rg.add_color_stop_rgba(0, *c, 0.55 * tw); rg.add_color_stop_rgba(1, *c, 0)
        ctx.set_source(rg); ctx.arc(x, y, size * 5, 0, TAU); ctx.fill()
    # vignette
    v = cairo.RadialGradient(W / 2, H / 2, H * 0.45, W / 2, H / 2, H * 1.05)
    v.add_color_stop_rgba(0, 0, 0, 0, 0); v.add_color_stop_rgba(1, 0, 0, 0, 0.55)
    ctx.set_source(v); ctx.paint()

def draw_jelly(ctx, cx, cy, R, t, alpha=1.0, accent=CYAN):
    """A jellyfish: pulsing bell, soft glow, and trailing tentacles that sway."""
    p = 1 + 0.07 * math.sin(t * 2.3)                    # the bell squeezes as it pulses
    rw, rh = R * p, R * (2 - p) * 0.95
    bell = lambda: (ctx.new_path(), ctx.move_to(cx - rw, cy),
                    ctx.curve_to(cx - rw, cy - rh * 1.35, cx + rw, cy - rh * 1.35, cx + rw, cy),
                    ctx.curve_to(cx + rw * 0.55, cy + rh * 0.20, cx + rw * 0.2, cy - rh * 0.02, cx, cy + rh * 0.10),
                    ctx.curve_to(cx - rw * 0.2, cy - rh * 0.02, cx - rw * 0.55, cy + rh * 0.20, cx - rw, cy), ctx.close_path())
    # glow
    for lw, a in ((R * 0.50, 0.025), (R * 0.32, 0.04), (R * 0.18, 0.07)):
        bell(); ctx.set_line_width(lw); ctx.set_line_join(cairo.LINE_JOIN_ROUND)
        ctx.set_source_rgba(*accent, a * alpha); ctx.stroke()
    # tentacles
    L = R * 3.2
    for k in range(9):
        x0 = cx - rw * 0.78 + k * (rw * 1.56 / 8)
        phase = k * 0.8
        long_ = 1.0 if k % 2 == 0 else 0.7
        prev = None
        for j in range(0, 46):
            s = j / 45
            x = x0 + math.sin(s * 5.5 + t * 1.9 + phase) * R * 0.20 * s + math.sin(t * 0.9 + phase) * R * 0.05 * s
            y = cy + rh * 0.05 + s * L * long_
            if prev:
                a = (1 - s) ** 1.3 * 0.9 * alpha
                c = mix(accent, VIOLET, s)
                ctx.set_source_rgba(*c, a)
                ctx.set_line_width(max(R * 0.055 * (1 - 0.7 * s), 1.2)); ctx.set_line_cap(cairo.LINE_CAP_ROUND)
                ctx.move_to(*prev); ctx.line_to(x, y); ctx.stroke()
            prev = (x, y)
    # the bell itself
    bell()
    rg = cairo.RadialGradient(cx, cy - rh * 0.55, R * 0.05, cx, cy - rh * 0.2, R * 1.35)
    rg.add_color_stop_rgba(0, *mix(accent, FOAM, 0.55), 0.96 * alpha)
    rg.add_color_stop_rgba(0.45, *mix(accent, VIOLET, 0.55), 0.88 * alpha)
    rg.add_color_stop_rgba(1, *mix(VIOLET, MAGENTA, 0.7), 0.62 * alpha)
    ctx.set_source(rg); ctx.fill_preserve()
    ctx.set_source_rgba(*mix(accent, FOAM, 0.4), 0.55 * alpha); ctx.set_line_width(max(R * 0.025, 1.5)); ctx.stroke()
    # a highlight
    ctx.save(); ctx.translate(cx - rw * 0.35, cy - rh * 0.78); ctx.rotate(-0.5); ctx.scale(R * 0.30, R * 0.13)
    ctx.arc(0, 0, 1, 0, TAU); ctx.restore()
    ctx.set_source_rgba(*FOAM, 0.38 * alpha); ctx.fill()

def draw_ring(ctx, cx, cy, r, alpha, color=CYAN, width=4):
    ctx.set_source_rgba(*color, alpha); ctx.set_line_width(width); ctx.arc(cx, cy, r, 0, TAU); ctx.stroke()

def wordmark(ctx, cx, cy, size, t, reveal=1.0, alpha=1.0, shimmer=True):
    """'tendril' in the app's own header gradient. `reveal` is how many letters are in (0..7)."""
    font(ctx, MONO, size, bold=True)
    word = "tendril"
    adv = [ctx.text_extents(ch).x_advance for ch in word]
    gap = size * 0.06
    total = sum(adv) + gap * (len(word) - 1)
    x = cx - total / 2
    for i, ch in enumerate(word):
        a = smooth(reveal - i) * alpha
        if a > 0:
            phase = (t * 0.35 + i * 0.09) % 1.0
            col = gradient(GLOW, 0.5 + 0.5 * math.sin(phase * TAU)) if shimmer else gradient(GLOW, i / 6)
            lift = (1 - smooth(reveal - i)) * size * 0.35
            # soft glow behind each letter
            ctx.set_source_rgba(*col, 0.18 * a)
            for d in (6, 3):
                ctx.set_line_width(d * size / 60)
                ctx.move_to(x, cy + lift); ctx.text_path(ch); ctx.stroke()
            ctx.set_source_rgba(*col, a)
            ctx.move_to(x, cy + lift); ctx.show_text(ch)
        x += adv[i] + gap
    return total

def typed(s, t, t0, cps=22.0):
    n = int(max(t - t0, 0) * cps)
    return s[:n]

def hook_frame(ctx, W, H, t):
    """4.5 s: the jellyfish drifts up out of the dark, the name appears, a tagline is typed, a sonar ring goes out."""
    draw_background(ctx, W, H, t)
    appear = smooth(t / 1.2)
    cy = lerp(H * 0.86, H * 0.36, ease_out(t / 2.4))
    draw_jelly(ctx, W / 2, cy, H * 0.115, t, alpha=appear)
    wordmark(ctx, W / 2, H * 0.80, H * 0.15, t, reveal=max((t - 1.0) / 0.1, 0) * 0.0 + max(t - 1.0, 0) * 11)
    font(ctx, SANS, H * 0.044, bold=False)
    line = typed("Jellyfin. In your terminal.", t, 2.3, 20)
    if line:
        w = draw_text(ctx, line, W / 2, H * 0.90, FOAM, spacing=1.5, alpha=0.92)
        if int(t * 2.5) % 2 == 0 or len(line) < 27:
            ctx.set_source_rgba(*CYAN, 0.9); ctx.rectangle(W / 2 + text_width(ctx, "Jellyfin. In your terminal.", 1.5) / 2 + 8 if len(line) >= 27 else W / 2 + w / 2 + 8, H * 0.90 - H * 0.036, H * 0.016, H * 0.044); ctx.fill()
    if t > 3.2:
        u = (t - 3.2) / 1.3
        draw_ring(ctx, W / 2, cy, H * 0.12 + u * H * 0.9, (1 - u) * 0.5, CYAN, 5)
        draw_ring(ctx, W / 2, cy, H * 0.12 + max(u - 0.15, 0) * H * 0.9, (1 - u) * 0.3, MAGENTA, 3)
    fade = smooth(t / 0.5)
    ctx.set_source_rgba(0, 0, 0, 1 - fade); ctx.paint()

def chip(ctx, x, y, label, size, alpha, accent):
    font(ctx, SANS, size, bold=True)
    w = text_width(ctx, label) + size * 1.6
    h = size * 2.0
    rounded(ctx, x - w / 2, y - h / 2, w, h, h / 2)
    ctx.set_source_rgba(*accent, 0.12 * alpha); ctx.fill_preserve()
    ctx.set_source_rgba(*accent, 0.85 * alpha); ctx.set_line_width(2); ctx.stroke()
    draw_text(ctx, label, x, y + size * 0.35, FOAM, alpha=alpha)
    return w

def outro_frame(ctx, W, H, t, total=6.0):
    """The name, the address (typed), where to get it, and a closing line."""
    draw_background(ctx, W, H, t + 20)
    draw_jelly(ctx, W / 2, H * 0.26, H * 0.075, t + 3, alpha=smooth(t / 0.8))
    wordmark(ctx, W / 2, H * 0.58, H * 0.17, t + 4, reveal=7.0, alpha=smooth(t / 0.6))
    font(ctx, MONO, H * 0.05, bold=True)
    url = "github.com/jgarza9788/tendril"
    shown = typed(url, t, 0.9, 26)
    if shown:
        w = draw_text(ctx, shown, W / 2, H * 0.69, CYAN, spacing=1.0)
        if int(t * 2.5) % 2 == 0 and len(shown) < len(url) + 1:
            ctx.set_source_rgba(*CYAN, 0.9); ctx.rectangle(W / 2 + w / 2 + 8, H * 0.69 - H * 0.04, H * 0.018, H * 0.05); ctx.fill()
    chips = [("AppImage", TEAL), ("Arch Linux", CYAN), ("Linux x86-64", VIOLET), ("MIT", MAGENTA)]
    sizes = H * 0.026
    font(ctx, SANS, sizes, bold=True)
    widths = [text_width(ctx, c[0]) + sizes * 1.6 for c in chips]
    gap = sizes * 1.1
    x = W / 2 - (sum(widths) + gap * (len(chips) - 1)) / 2
    for i, (label, col) in enumerate(chips):
        a = smooth((t - 2.2 - i * 0.25) / 0.4)
        if a > 0:
            chip(ctx, x + widths[i] / 2, H * 0.78 - (1 - a) * 12, label, sizes, a, col)
        x += widths[i] + gap
    font(ctx, SANS, H * 0.036, bold=False)
    a = smooth((t - 3.6) / 0.6)
    draw_text(ctx, "Download it. Open a terminal. Press play.", W / 2, H * 0.90, FOAM, spacing=1.0, alpha=a * 0.95)
    fade = 1 - smooth((t - (total - 0.9)) / 0.9)
    ctx.set_source_rgba(0, 0, 0, 1 - fade); ctx.paint()

# ---- overlays -------------------------------------------------------------------------------------------------------

def caption_img(tag, text, accent=CYAN, scale=1.0):
    """A pill with a coloured tag and the caption. Returns a PIL RGBA image."""
    probe, pc = new_surface(10, 10)
    size_t, size_m = 30 * scale, 58 * scale
    font(pc, SANS, size_t, True); tw = text_width(pc, tag.upper(), 3.0)
    font(pc, SANS, size_m, True); mw = text_width(pc, text)
    pad, h = 34 * scale, 106 * scale
    tagw = tw + pad * 1.4
    W = int(pad + tagw + 26 * scale + mw + pad + 8)
    H = int(h + 8)
    s, c = new_surface(W, H)
    rounded(c, 4, 4, W - 8, h, h / 2)
    c.set_source_rgba(*mix(ABYSS, (0, 0, 0), 0.4), 0.82); c.fill_preserve()
    g = cairo.LinearGradient(0, 0, W, 0)
    g.add_color_stop_rgba(0, *accent, 0.95); g.add_color_stop_rgba(1, *MAGENTA, 0.85)
    c.set_source(g); c.set_line_width(3 * scale); c.stroke()
    rounded(c, 4 + pad * 0.45, 4 + h * 0.22, tagw, h * 0.56, h * 0.28)
    c.set_source(g); c.fill()
    font(c, SANS, size_t, True)
    draw_text(c, tag.upper(), 4 + pad * 0.45 + tagw / 2, 4 + h / 2 + size_t * 0.36, ABYSS, spacing=3.0)
    font(c, SANS, size_m, True)
    draw_text(c, text, 4 + pad * 0.45 + tagw + 26 * scale, 4 + h / 2 + size_m * 0.34, FOAM, anchor="left")
    return to_pil(s)

def command_img(cmd, scale=1.0):
    """`$ command` in a terminal-looking pill (for the playerctl scene)."""
    probe, pc = new_surface(10, 10)
    size = 40 * scale
    font(pc, MONO, size, True); w = text_width(pc, "$ " + cmd)
    pad, h = 30 * scale, 78 * scale
    W, H = int(w + pad * 2 + 8), int(h + 8)
    s, c = new_surface(W, H)
    rounded(c, 4, 4, W - 8, h, 16 * scale)
    c.set_source_rgba(*ABYSS, 0.92); c.fill_preserve()
    c.set_source_rgba(*CYAN, 0.9); c.set_line_width(2.5 * scale); c.stroke()
    font(c, MONO, size, True)
    draw_text(c, "$", 4 + pad, 4 + h / 2 + size * 0.34, MAGENTA, anchor="left")
    draw_text(c, cmd, 4 + pad + text_width(c, "$ "), 4 + h / 2 + size * 0.34, FOAM, anchor="left")
    return to_pil(s)

def keycap_img(label, scale=1.0):
    probe, pc = new_surface(10, 10)
    size = 34 * scale
    font(pc, MONO, size, True)
    w = max(text_width(pc, label) + 36 * scale, 70 * scale)
    h = 70 * scale
    W, H = int(w + 8), int(h + 16)
    s, c = new_surface(W, H)
    rounded(c, 4, 12, w, h, 14 * scale); c.set_source_rgba(0.03, 0.04, 0.10, 0.95); c.fill()          # the key's side
    rounded(c, 4, 4, w, h, 14 * scale)
    g = cairo.LinearGradient(0, 4, 0, 4 + h); g.add_color_stop_rgb(0, *mix(TRENCH, FOAM, 0.22)); g.add_color_stop_rgb(1, *mix(TRENCH, ABYSS, 0.1))
    c.set_source(g); c.fill_preserve(); c.set_source_rgba(*CYAN, 0.7); c.set_line_width(2 * scale); c.stroke()
    font(c, MONO, size, True)
    draw_text(c, label, 4 + w / 2, 4 + h / 2 + size * 0.34, FOAM)
    return to_pil(s)

def wipe_img(W, H, u):
    """A bright diagonal band sweeping left to right; u in 0..1."""
    s, c = new_surface(W, H)
    skew = H * 0.35
    width = W * 0.42
    x = lerp(-width - skew, W + skew, ease_out(u) * 0.4 + u * 0.6)
    for off, a, cols in ((0.0, 0.85, (CYAN, MAGENTA)), (-width * 0.55, 0.45, (TEAL, VIOLET))):
        x0 = x + off
        g = cairo.LinearGradient(x0, 0, x0 + width, 0)
        g.add_color_stop_rgba(0, *cols[0], 0); g.add_color_stop_rgba(0.35, *cols[0], a)
        g.add_color_stop_rgba(0.7, *cols[1], a); g.add_color_stop_rgba(1, *cols[1], 0)
        c.set_source(g)
        c.move_to(x0 + skew, 0); c.line_to(x0 + width + skew, 0); c.line_to(x0 + width, H); c.line_to(x0, H); c.close_path(); c.fill()
    return to_pil(s)
