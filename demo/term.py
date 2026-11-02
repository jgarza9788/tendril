"""Renders a screen captured with `tmux capture-pane -p -e` into an image, cell by cell.

Half blocks and the spectrum's eighth blocks are drawn from geometry, not from the font, so the cover art and the
bars have no seams between cells. Everything else (box lines, text, icons) comes from the font."""
import re
import numpy as np
from PIL import Image, ImageDraw, ImageFont

FONT = "/usr/share/fonts/Adwaita/AdwaitaMono-Regular.ttf"
FONT_BOLD = "/usr/share/fonts/Adwaita/AdwaitaMono-Bold.ttf"
DEFAULT_FG = (230, 241, 255)
DEFAULT_BG = (7, 11, 26)
NAMED = [(0, 0, 0), (205, 49, 49), (13, 188, 121), (229, 229, 16), (36, 114, 200), (188, 63, 188), (17, 168, 205), (229, 229, 229),
         (102, 102, 102), (241, 76, 76), (35, 209, 139), (245, 245, 67), (59, 142, 234), (214, 112, 214), (41, 184, 219), (255, 255, 255)]
SGR = re.compile(r"\x1b\[([0-9;]*)m")
EIGHTHS = {"▁": 1, "▂": 2, "▃": 3, "▄": 4, "▅": 5, "▆": 6, "▇": 7, "█": 8}


def xterm256(n):
    if n < 16:
        return NAMED[n]
    if n < 232:
        n -= 16
        lv = [0, 95, 135, 175, 215, 255]
        return (lv[n // 36], lv[(n // 6) % 6], lv[n % 6])
    g = 8 + (n - 232) * 10
    return (g, g, g)


class Renderer:
    def __init__(self, cw=11, ch=22):
        self.cw, self.ch = cw, ch
        size = 8
        while ImageFont.truetype(FONT, size + 1).getlength("M") <= cw:
            size += 1
        self.font = ImageFont.truetype(FONT, size)
        self.font_b = ImageFont.truetype(FONT_BOLD, size)
        self.ascent = self.font.getmetrics()[0]
        self.pad_y = max((ch - sum(self.font.getmetrics())) // 2, 0)
        self.masks = {}

    def glyph(self, c, bold):
        key = (c, bold)
        m = self.masks.get(key)
        if m is None:
            im = Image.new("L", (self.cw * 2, self.ch), 0)
            ImageDraw.Draw(im).text((0, self.pad_y), c, font=self.font_b if bold else self.font, fill=255)
            m = np.asarray(im.crop((0, 0, self.cw, self.ch)), dtype=np.float32) / 255.0
            self.masks[key] = m
        return m

    def parse(self, text, cols, rows):
        """-> grid of (char, fg, bg, bold, underline) for rows x cols."""
        grid = [[(" ", DEFAULT_FG, DEFAULT_BG, False, False)] * cols for _ in range(rows)]
        for y, line in enumerate(text.split("\n")[:rows]):
            fg, bg, bold, dim, ul, rev = DEFAULT_FG, DEFAULT_BG, False, False, False, False
            x, pos = 0, 0
            row = list(grid[y])
            while pos < len(line) and x < cols:
                m = SGR.match(line, pos)
                if m:
                    p = [int(v) if v else 0 for v in m.group(1).split(";")]
                    i = 0
                    while i < len(p):
                        v = p[i]
                        if v == 0: fg, bg, bold, dim, ul, rev = DEFAULT_FG, DEFAULT_BG, False, False, False, False
                        elif v == 1: bold = True
                        elif v == 2: dim = True
                        elif v == 4: ul = True
                        elif v == 7: rev = True
                        elif v == 22: bold = dim = False
                        elif v == 24: ul = False
                        elif v == 27: rev = False
                        elif v == 39: fg = DEFAULT_FG
                        elif v == 49: bg = DEFAULT_BG
                        elif 30 <= v <= 37: fg = NAMED[v - 30]
                        elif 40 <= v <= 47: bg = NAMED[v - 40]
                        elif 90 <= v <= 97: fg = NAMED[v - 90 + 8]
                        elif 100 <= v <= 107: bg = NAMED[v - 100 + 8]
                        elif v in (38, 48) and i + 1 < len(p):
                            if p[i + 1] == 2 and i + 4 < len(p):
                                c = (p[i + 2], p[i + 3], p[i + 4]); i += 4
                            elif p[i + 1] == 5 and i + 2 < len(p):
                                c = xterm256(p[i + 2]); i += 2
                            else:
                                c = None
                            if c is not None:
                                if v == 38: fg = c
                                else: bg = c
                        i += 1
                    pos = m.end()
                    continue
                if line[pos] == "\x1b":          # some other escape: skip it
                    pos += 1
                    continue
                f, b = (bg, fg) if rev else (fg, bg)
                if dim:
                    f = tuple(int(f[k] * 0.6 + b[k] * 0.4) for k in range(3))
                row[x] = (line[pos], f, b, bold, ul)
                x += 1
                pos += 1
            grid[y] = row
        return grid

    def render(self, text, cols, rows):
        cw, ch = self.cw, self.ch
        grid = self.parse(text, cols, rows)
        bg = np.empty((rows, cols, 3), dtype=np.uint8)
        for y in range(rows):
            for x in range(cols):
                bg[y, x] = grid[y][x][2]
        img = np.repeat(np.repeat(bg, ch, axis=0), cw, axis=1).astype(np.float32)
        for y in range(rows):
            for x in range(cols):
                c, fg, b, bold, ul = grid[y][x]
                if c == " " and not ul:
                    continue
                y0, x0 = y * ch, x * cw
                reg = img[y0:y0 + ch, x0:x0 + cw]
                fgv = np.array(fg, dtype=np.float32)
                if c == "▀":
                    reg[: ch // 2] = fgv
                elif c in EIGHTHS:
                    h = max(1, round(ch * EIGHTHS[c] / 8))
                    reg[ch - h:] = fgv
                elif c != " ":
                    m = self.glyph(c, bold)[..., None]
                    reg[:] = reg * (1 - m) + fgv * m
                if ul:
                    reg[ch - 3:ch - 2] = fgv
        return Image.fromarray(np.clip(img, 0, 255).astype(np.uint8))


if __name__ == "__main__":
    import sys
    text = open(sys.argv[1], errors="replace").read()
    cols, rows = int(sys.argv[3]), int(sys.argv[4])
    Renderer().render(text, cols, rows).save(sys.argv[2])
