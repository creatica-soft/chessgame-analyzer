"""Synthetic chess diagrams, cut into squares the way the app cuts a straightened board.

Geometry shared with the app (DiagramGeometry.swift): the board plus a margin of MARGIN squares
on each side is warped to (8 + 2*MARGIN) * SQ pixels; each square is cropped with CELL_MARGIN of a
square around it and resized to CELL x CELL.
"""
import os, sys, random, io
import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from multiprocessing import Pool

SQ, MARGIN, CELL_MARGIN, CELL = 24, 0.25, 0.15, 32
CLASSES = ['empty', 'wP', 'wN', 'wB', 'wR', 'wQ', 'wK', 'bP', 'bN', 'bB', 'bR', 'bQ', 'bK']
ROOT = sys.argv[1] if len(sys.argv) > 1 else 'diagram/pieces'
# Diagram fonts cut into square tiles by fontglyphs.py: '<piece>_l', '<piece>_d', 'empty_d'.
TILES_ROOT = os.environ.get('TILES', 'diagram/fontglyphs')
PIECES = {}
TILES = {}

def load_pieces():
    for s in sorted(os.listdir(ROOT)):
        PIECES[s] = {c: Image.open(f'{ROOT}/{s}/{c}.png').convert('RGBA') for c in CLASSES[1:]}
    if os.path.isdir(TILES_ROOT):
        for s in sorted(os.listdir(TILES_ROOT)):
            names = [f'{c}_{sq}' for c in CLASSES[1:] for sq in 'ld'] + ['empty_d']
            TILES[s] = {n: Image.open(f'{TILES_ROOT}/{s}/{n}.png').convert('L') for n in names}

def styles():
    return sorted(PIECES) + sorted(TILES)

def render_font(rng, tiles):
    """A board typeset in a diagram font, square by square, as books print them."""
    S = rng.randint(18, 90)
    pad = int(S * rng.uniform(0.6, 1.5))
    W = 8 * S + 2 * pad
    paper = rng.randint(215, 255)
    tint = np.array([paper, paper - rng.randint(0, 12), paper - rng.randint(0, 25)], np.float32)
    board = Image.new('L', (8 * S, 8 * S), 255)
    labels = []
    density = rng.uniform(0.2, 0.6)
    for r in range(8):
        for c in range(8):
            dark = (r + c) % 2 == 1
            if rng.random() < density:
                name = rng.choice(CLASSES[1:])
                tile = tiles[f'{name}_{"d" if dark else "l"}']
                labels.append(CLASSES.index(name))
            else:
                tile = tiles['empty_d'] if dark else None
                labels.append(0)
            if tile is not None:
                board.paste(tile.resize((S, S), Image.LANCZOS), (c * S, r * S))
    page = Image.new('L', (W, W), 255)
    page.paste(board, (pad, pad))
    d = ImageDraw.Draw(page)
    w = rng.randint(1, max(1, S // 10))
    gap = rng.choice([0, 0, rng.randint(1, max(1, S // 8))])
    d.rectangle([pad - gap - w, pad - gap - w, pad + 8 * S + gap + w - 1, pad + 8 * S + gap + w - 1],
                outline=rng.randint(0, 60), width=w)
    a = np.asarray(page).astype(np.float32)[..., None] / 255.0 * tint   # ink on tinted paper
    img = Image.fromarray(a.astype(np.uint8))
    corners = [(pad, pad), (pad + 8 * S, pad), (pad + 8 * S, pad + 8 * S), (pad, pad + 8 * S)]
    return img, corners, labels, S

def board_colors(rng):
    """(light, dark, pattern): pattern is 'solid', 'hatch', 'dots' or 'screen'."""
    r = rng.random()
    if r < 0.45:   # book: white squares, hatched dark squares
        return (rng.randint(235, 255),) * 3, (rng.randint(0, 90),) * 3, 'hatch'
    if r < 0.6:
        return (rng.randint(235, 255),) * 3, (rng.randint(60, 140),) * 3, 'dots'
    if r < 0.75:
        g = rng.randint(140, 215)
        return (rng.randint(230, 255),) * 3, (g, g, g), 'solid'
    palettes = [((240, 217, 181), (181, 136, 99)), ((238, 238, 210), (118, 150, 86)),
                ((222, 227, 230), (140, 162, 173)), ((255, 255, 255), (200, 200, 200)),
                ((232, 235, 239), (125, 135, 150)), ((255, 206, 158), (209, 139, 71))]
    light, dark = rng.choice(palettes)
    jitter = lambda c: tuple(max(0, min(255, v + rng.randint(-15, 15))) for v in c)
    return jitter(light), jitter(dark), 'screen'

def render(rng, sets):
    """One board: (RGB image, board corners (x, y) clockwise from top left, 64 labels)."""
    S = rng.randint(18, 90)                     # square size as printed or shown
    pad = int(S * rng.uniform(0.6, 1.5))
    W = 8 * S + 2 * pad
    paper = rng.randint(215, 255)
    tint = (paper, paper - rng.randint(0, 12), paper - rng.randint(0, 25))
    img = Image.new('RGB', (W, W), tint)
    light, dark, pattern = board_colors(rng)
    arr = np.array(img)
    yy, xx = np.mgrid[0:8 * S, 0:8 * S]
    is_dark = ((yy // S) + (xx // S)) % 2 == 1
    board = np.empty((8 * S, 8 * S, 3), np.uint8)
    board[:] = light
    if pattern == 'hatch':
        spacing = rng.randint(2, max(3, S // 6))
        width = max(1, int(spacing * rng.uniform(0.3, 0.6)))
        direction = rng.choice([1, -1])
        lines = ((xx + direction * yy) % spacing) < width
        board[is_dark & lines] = dark
    elif pattern == 'dots':
        spacing = rng.randint(2, 4)
        dots = ((xx % spacing) == 0) & ((yy % spacing) == 0) | (rng.random() < 0.5) & (((xx + yy) % spacing) == 0)
        board[is_dark & dots] = dark
    else:
        board[is_dark] = dark
    if pattern == 'screen' and rng.random() < 0.6:
        # Last-move highlights, as lichess and chess.com draw them.
        tint = rng.choice([(205, 210, 106), (246, 246, 105), (170, 162, 58), (155, 199, 0), (100, 170, 220)])
        alpha = rng.uniform(0.5, 0.9)
        for _ in range(rng.randint(1, 2)):
            r, c = rng.randrange(8), rng.randrange(8)
            sq = board[r * S:(r + 1) * S, c * S:(c + 1) * S].astype(np.float32)
            board[r * S:(r + 1) * S, c * S:(c + 1) * S] = (sq * (1 - alpha) + np.array(tint) * alpha).astype(np.uint8)
    arr[pad:pad + 8 * S, pad:pad + 8 * S] = board
    img = Image.fromarray(arr)
    d = ImageDraw.Draw(img)
    if pattern != 'screen' or rng.random() < 0.3:   # a printed frame
        w = rng.randint(1, max(1, S // 10))
        gap = rng.choice([0, 0, rng.randint(1, max(1, S // 8))])
        d.rectangle([pad - gap - w, pad - gap - w, pad + 8 * S + gap + w - 1, pad + 8 * S + gap + w - 1],
                    outline=(rng.randint(0, 60),) * 3, width=w)

    # Pieces: a quarter to a half of the squares, any piece.
    pset = PIECES[rng.choice(sets)]
    labels = []
    density = rng.uniform(0.2, 0.6)
    scale = rng.uniform(0.78, 1.0)
    squash_x, squash_y = rng.uniform(0.86, 1.08), rng.uniform(0.86, 1.08)
    for r in range(8):
        for c in range(8):
            if rng.random() < density:
                name = rng.choice(CLASSES[1:])
                size = max(4, int(S * scale * rng.uniform(0.96, 1.04)))
                # Proportions vary between styles: squash or stretch a little.
                sw = max(4, min(S, int(size * squash_x))); sh = max(4, min(S, int(size * squash_y)))
                piece = pset[name].resize((sw, sh), Image.LANCZOS)
                ox = pad + c * S + (S - sw) // 2 + rng.randint(-1, 1)
                oy = pad + r * S + (S - sh) // 2 + rng.randint(-1, 1)
                img.paste(piece, (ox, oy), piece)
                labels.append(CLASSES.index(name))
            else:
                labels.append(0)
    corners = [(pad, pad), (pad + 8 * S, pad), (pad + 8 * S, pad + 8 * S), (pad, pad + 8 * S)]
    return img, corners, labels, S

def degrade(rng, img, S):
    # Ink spreading (strokes thicker) or a light print (thinner), at the printed size.
    # Thinning only where strokes are several pixels wide, or fine lines vanish altogether.
    if S >= 30 and rng.random() < 0.35:
        thin = S >= 60 and rng.random() < 0.4
        img = img.filter(ImageFilter.MaxFilter(3) if thin else ImageFilter.MinFilter(3))
    if rng.random() < 0.5:
        img = img.filter(ImageFilter.GaussianBlur(rng.uniform(0.2, 0.9) * S / 30))
    a = np.asarray(img).astype(np.float32)
    # Uneven light, contrast, noise.
    h, w = a.shape[:2]
    gy, gx = np.mgrid[0:h, 0:w]
    if rng.random() < 0.35:
        # A photo of a screen: moire, the screen's pixel grid beating with the camera's, as
        # coloured bands at any angle and spacing; sometimes two at once.
        for _ in range(rng.choice([1, 1, 2])):
            period = rng.uniform(3, 40) * S / 30
            angle = rng.uniform(0, np.pi)
            amp = rng.uniform(0.04, 0.22)
            phase = (gx * np.cos(angle) + gy * np.sin(angle)) * 2 * np.pi / period
            shifts = [0, rng.uniform(0, 2 * np.pi), rng.uniform(0, 2 * np.pi)]
            for ch in range(3):
                a[..., ch] *= 1 + amp * np.sin(phase + shifts[ch])
    if rng.random() < 0.25:
        # Glare: a patch washed towards white.
        cy, cx = rng.uniform(0, h), rng.uniform(0, w)
        sigma = rng.uniform(0.15, 0.6) * max(h, w)
        g = rng.uniform(0.3, 0.85) * np.exp(-((gx - cx) ** 2 + (gy - cy) ** 2) / (2 * sigma ** 2))
        a = a + (255 - a) * g[..., None]
    light = 1 + rng.uniform(-0.25, 0.1) * (gx / w) + rng.uniform(-0.25, 0.1) * (gy / h)
    a = a * light[..., None]
    lo, hi = rng.uniform(0, 50), rng.uniform(200, 255)
    a = lo + a * (hi - lo) / 255
    a += np.random.default_rng(rng.randint(0, 1 << 30)).normal(0, rng.uniform(0, 12), a.shape)
    img = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
    if rng.random() < 0.6:
        buf = io.BytesIO()
        img.save(buf, 'JPEG', quality=rng.randint(30, 90))
        img = Image.open(buf).convert('RGB')
    return img

def cells(rng, img, corners, S, jitter):
    """Warp the board as the app would, from slightly wrong corners, and cut the squares."""
    (x0, y0), (x1, y1), (x2, y2), (x3, y3) = corners
    j = lambda: rng.uniform(-jitter, jitter) * S
    quad = [(x0 + j(), y0 + j()), (x1 + j(), y1 + j()), (x2 + j(), y2 + j()), (x3 + j(), y3 + j())]
    # Expand the quad by MARGIN squares on each side.
    cx = sum(p[0] for p in quad) / 4; cy = sum(p[1] for p in quad) / 4
    f = (8 + 2 * MARGIN) / 8
    quad = [(cx + (x - cx) * f, cy + (y - cy) * f) for x, y in quad]
    out = round((8 + 2 * MARGIN) * SQ)
    # PIL's QUAD data: upper left, lower left, lower right, upper right.
    data = [*quad[0], *quad[3], *quad[2], *quad[1]]
    warped = img.convert('L').transform((out, out), Image.QUAD, data, Image.BILINEAR)
    res = []
    for r in range(8):
        for c in range(8):
            left = (MARGIN + c - CELL_MARGIN) * SQ
            top = (MARGIN + r - CELL_MARGIN) * SQ
            size = (1 + 2 * CELL_MARGIN) * SQ
            res.append(np.asarray(warped.resize((CELL, CELL), Image.BILINEAR,
                                                box=(left, top, left + size, top + size))))
    return np.stack(res)

def make(args):
    seed, sets, jitter = args
    rng = random.Random(seed)
    if not PIECES: load_pieces()
    style = rng.choice(sets)
    if style in TILES:
        img, corners, labels, S = render_font(rng, TILES[style])
    else:
        img, corners, labels, S = render(rng, [style])
    img = degrade(rng, img, S)
    return cells(rng, img, corners, S, jitter), np.array(labels, np.uint8)

if __name__ == '__main__':
    out, n, held = sys.argv[2], int(sys.argv[3]), sys.argv[4].split(',')
    load_pieces()
    all_sets = styles()
    held = [h for h in held if h in all_sets]   # none: train on every style
    train_sets = [s for s in all_sets if s not in held]
    jobs = [(i, train_sets, 0.12) for i in range(n)] + ([(10_000_000 + i, held, 0.12) for i in range(n // 10)] if held else [])
    with Pool(8) as pool:
        results = pool.map(make, jobs, chunksize=32)
    x = np.concatenate([r[0] for r in results]); y = np.concatenate([r[1] for r in results])
    if not held:   # keep the arrays' shapes: an empty held-out set
        x = np.concatenate([x, np.zeros((0, CELL, CELL), np.uint8)]); y = np.concatenate([y, np.zeros(0, np.uint8)])
    split = n * 64
    np.savez_compressed(out, x_train=x[:split], y_train=y[:split], x_held=x[split:], y_held=y[split:],
                        classes=np.array(CLASSES), held=np.array(held))
    print('train', x[:split].shape, 'held-out', x[split:].shape, np.bincount(y[:split], minlength=13))
