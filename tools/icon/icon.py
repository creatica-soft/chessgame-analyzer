"""Draws the app icon (1024 x 1024, opaque; iOS rounds the corners): an ivory knight under a gold
magnifying glass, on a dark board. Everything is drawn here: the knight is the side silhouette of
tools/render3d/render.py's knight, on a plinth.

    python3 tools/icon/icon.py App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png [preview.png]
"""
import sys, math
from PIL import Image, ImageDraw, ImageFilter

S = 4096                     # drawn at four times the size, then scaled down smooth
K = S / 1024

def board(img):
    d = ImageDraw.Draw(img)
    dark, light = (24, 44, 58), (34, 62, 79)
    n = 4
    for r in range(n):
        for f in range(n):
            d.rectangle([f * S / n, r * S / n, (f + 1) * S / n, (r + 1) * S / n], fill=light if (f + r) % 2 else dark)
    # Light from the top left.
    shade = Image.new('L', (S, S))
    sd = ImageDraw.Draw(shade)
    for i in range(0, S, 16):
        sd.line([(0, i), (i, 0)], fill=int(70 * (1 - i / S)), width=24)
    img.paste(Image.new('RGB', (S, S), (255, 255, 255)), mask=shade.point(lambda v: v // 3))

# The knight, facing right: render.py's head outline (x, z in mm) above a plinth.
HEAD = [(-10, 12), (-11, 22), (-10.5, 32), (-8.5, 41), (-5, 48), (-2.5, 53), (-1.5, 58), (0.5, 61),
        (2.5, 57), (6, 55), (10, 51.5), (14, 45.5), (16.5, 39.5), (17, 35.5), (15.5, 32.5), (11, 32.5),
        (7.5, 34), (5, 31), (6, 25.5), (8.5, 19), (10, 12)]

def smooth(points, n=12):
    """A closed Catmull-Rom curve through the points."""
    out = []
    m = len(points)
    for i in range(m):
        p0, p1, p2, p3 = points[i - 1], points[i], points[(i + 1) % m], points[(i + 2) % m]
        for k in range(n):
            t = k / n
            out.append(tuple(0.5 * ((2 * p1[j]) + (-p0[j] + p2[j]) * t + (2 * p0[j] - 5 * p1[j] + 4 * p2[j] - p3[j]) * t * t
                                    + (-p0[j] + 3 * p1[j] - 3 * p2[j] + p3[j]) * t ** 3) for j in range(2)))
    return out

def knight(cx, base_y, scale):
    """Polygons (head, collar, plinth) in pixels; z up."""
    def p(x, z): return (cx + x * scale, base_y - z * scale)
    head = smooth([p(x * 1.12, z) for x, z in HEAD])
    collar = [p(-14, 13), p(14, 13), p(15, 9), p(-15, 9)]
    plinth = [p(-19, 9), p(19, 9), p(21, 4), p(22, 0), p(-22, 0), p(-21, 4)]
    return head, collar, plinth

def draw(out, preview=None):
    img = Image.new('RGB', (S, S))
    board(img)
    # Lens: a ring centred a little up and left, the handle to the bottom right.
    lx, ly, lr = 460 * K, 440 * K, 300 * K
    ring = 46 * K
    gold, gold_dark = (222, 172, 72), (160, 116, 40)
    glass = Image.new('L', (S, S))
    ImageDraw.Draw(glass).ellipse([lx - lr, ly - lr, lx + lr, ly + lr], fill=255)
    tint = Image.new('RGB', (S, S), (60, 96, 112))
    img.paste(tint, mask=glass.point(lambda v: v * 150 // 255))
    # Knight's shadow, then the knight, inside the lens.
    scale = 7.4 * K
    kx, kby = lx - 22 * K, ly + 205 * K
    shapes = knight(kx, kby, scale)
    shadow = Image.new('L', (S, S))
    sd = ImageDraw.Draw(shadow)
    for poly in shapes:
        sd.polygon([(x + 18 * K, y + 22 * K) for x, y in poly], fill=150)
    shadow = shadow.filter(ImageFilter.GaussianBlur(14 * K))
    shadow = Image.fromarray(__import__('numpy').minimum(__import__('numpy').array(shadow), __import__('numpy').array(glass)))
    img.paste(Image.new('RGB', (S, S), (6, 14, 20)), mask=shadow)
    # The knight drawn on a layer of its own, clipped to the glass.
    layer = Image.new('RGB', (S, S))
    cut = Image.new('L', (S, S))
    ld, cd = ImageDraw.Draw(layer), ImageDraw.Draw(cut)
    ivory, ivory_shade = (246, 238, 220), (214, 202, 176)
    head, collar, plinth = shapes
    for poly, colour in ((head, ivory), (collar, ivory_shade), (plinth, ivory)):
        ld.polygon(poly, fill=colour)
        cd.polygon(poly, fill=255)
    ex, ey = kx + 6.5 * 1.12 * scale, kby - 47 * scale
    ld.ellipse([ex - 12 * K, ey - 12 * K, ex + 12 * K, ey + 12 * K], fill=(40, 52, 60))
    import numpy as np
    img.paste(layer, mask=Image.fromarray(np.minimum(np.array(cut), np.array(glass))))
    d = ImageDraw.Draw(img)
    # Handle, then the ring over everything.
    a = math.radians(45)
    hx0, hy0 = lx + (lr + ring * 0.4) * math.cos(a), ly + (lr + ring * 0.4) * math.sin(a)
    hx1, hy1 = lx + (lr + 330 * K) * math.cos(a), ly + (lr + 330 * K) * math.sin(a)
    d.line([(hx0, hy0), (hx1, hy1)], fill=gold_dark, width=int(110 * K))
    d.line([(hx0, hy0), (hx1, hy1)], fill=gold, width=int(80 * K))
    d.ellipse([hx1 - 55 * K, hy1 - 55 * K, hx1 + 55 * K, hy1 + 55 * K], fill=gold)
    d.ellipse([lx - lr - ring / 2, ly - lr - ring / 2, lx + lr + ring / 2, ly + lr + ring / 2], outline=gold_dark, width=int(ring + 10 * K))
    d.ellipse([lx - lr - ring / 2, ly - lr - ring / 2, lx + lr + ring / 2, ly + lr + ring / 2], outline=gold, width=int(ring))
    # A glint on the glass.
    d.arc([lx - lr + 40 * K, ly - lr + 40 * K, lx + lr - 40 * K, ly + lr - 40 * K], 200, 250, fill=(255, 255, 255), width=int(14 * K))
    icon = img.resize((1024, 1024), Image.LANCZOS)
    icon.save(out)
    if preview:
        # As iOS shows it: rounded, and small.
        mask = Image.new('L', (1024, 1024))
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, 1023, 1023], radius=230, fill=255)
        sheet = Image.new('RGB', (1024 + 40 + 180 + 40 + 60, 1024), (240, 240, 240))
        sheet.paste(icon, (0, 0), mask)
        small = icon.resize((180, 180), Image.LANCZOS); sm = mask.resize((180, 180))
        sheet.paste(small, (1064, 40), sm)
        tiny = icon.resize((60, 60), Image.LANCZOS); tm = mask.resize((60, 60))
        sheet.paste(tiny, (1064, 260), tm)
        sheet.save(preview)

if __name__ == '__main__':
    draw(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
