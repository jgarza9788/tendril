import pickle, sys, os
from PIL import Image, ImageDraw
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from term import Renderer
d = pickle.load(open(os.path.expanduser("~/.cache/tendril-demo/capture.pkl"), "rb"))
times = [float(x) for x in sys.argv[2:]]
r = Renderer()
def at(t):
    best = d["frames"][0]
    for f in d["frames"]:
        if f[0] <= t: best = f
    return best
tiles = []
for t in times:
    f = at(t)
    im = r.render(f[1], f[2], f[3]).convert("RGB")
    s = 0.36
    im = im.resize((int(im.width * s), int(im.height * s)), Image.LANCZOS)
    tile = Image.new("RGB", (int(1628 * s), int(836 * s) + 16), (30, 30, 40))
    tile.paste(im, (0, 16))
    ImageDraw.Draw(tile).text((4, 2), f"t={t:.1f}s  {f[2]}x{f[3]}", fill=(255, 255, 0))
    tiles.append(tile)
n = len(tiles); cols = 3; rows = (n + cols - 1) // cols
sheet = Image.new("RGB", (tiles[0].width * cols, tiles[0].height * rows))
for i, tl in enumerate(tiles): sheet.paste(tl, ((i % cols) * tl.width, (i // cols) * tl.height))
sheet.save(sys.argv[1])
print(sheet.size)
