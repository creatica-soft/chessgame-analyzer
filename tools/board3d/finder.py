"""A learned board finder: where the 8 x 8 playing area is in a photo, from any side and on any
surface, for boards it has not seen (trained on renders of many boards, tools/render3d/boards3d.py).

The network sees the photo letterboxed into IN x IN and gives, at a quarter of that, three maps:
the playing area (which pieces standing on it do not break up), its four corners, and its 81 square
corners. The board is then fitted: the four corner peaks that best enclose the playing area, and
the homography refined on the square corners found, as grid.py refines on its X-corners. Which
corner is a1 is not its business (the squares' colours and the pieces settle it, as now).

    python3 finder.py train renders-dir[,more] model.pt epochs [real.json]
    python3 finder.py eval model.pt real.json [sheet.jpg]
    python3 finder.py quads model.pt real.json|frames-dir quads.json      (for refine.py)

real.json: [{"path": frame, "corners": [[x, y] x 4]}], corners as tools/board3d/locate.py names
them (any order round the board is fine). Run from tools/work. Error is the worst corner's
distance from its label, in widths of a square; a frame counts as found within a quarter square.
"""
import sys, os, json, time, math, random
import numpy as np
import torch, torch.nn as nn, torch.nn.functional as F
from PIL import Image

IN, OUT = 256, 64
STRIDE = IN // OUT


# MARK: - Data

def letterbox(img, scale_jitter=None, rng=None):
    """img (PIL) into IN x IN: scaled so its long side fits (times a random scale in training),
    placed at a random spot (the top left without rng). Returns the array and (scale, dx, dy)."""
    w, h = img.size
    s = IN / max(w, h)
    if scale_jitter:
        s *= rng.uniform(*scale_jitter)
    nw, nh = max(1, round(w * s)), max(1, round(h * s))
    small = np.asarray(img.convert('RGB').resize((nw, nh), Image.BILINEAR))
    canvas = np.full((IN, IN, 3), rng.randint(0, 255) if rng else 114, np.uint8)
    dx = rng.randint(0, IN - nw) if rng else 0
    dy = rng.randint(0, IN - nh) if rng else 0
    canvas[dy:dy + nh, dx:dx + nw] = small
    return canvas, (s, dx, dy)


def targets(corners, lattice):
    """The three maps at OUT x OUT from points already in the IN x IN canvas's pixels."""
    ys, xs = np.mgrid[0:OUT, 0:OUT].astype(np.float32)
    cx, cy = (xs + 0.5) * STRIDE, (ys + 0.5) * STRIDE
    q = np.asarray(corners, np.float32)
    # Inside the quad: on the same side of all four edges (a board seen in perspective is convex).
    sides = []
    for k in range(4):
        (x0, y0), (x1, y1) = q[k], q[(k + 1) % 4]
        sides.append((x1 - x0) * (cy - y0) - (y1 - y0) * (cx - x0))
    sides = np.stack(sides)
    mask = ((sides >= 0).all(0) | (sides <= 0).all(0)).astype(np.float32)

    def heat(points, sigma):
        m = np.zeros((OUT, OUT), np.float32)
        for x, y in points:
            gx, gy = x / STRIDE - 0.5, y / STRIDE - 0.5
            if -2 < gx < OUT + 1 and -2 < gy < OUT + 1:
                m = np.maximum(m, np.exp(-((xs - gx) ** 2 + (ys - gy) ** 2) / (2 * sigma ** 2)))
                # The nearest cell is the point's positive for the focal loss; the Gaussian keeps
                # the point's fraction of a cell round it, for the peak's centroid.
                ix, iy = int(round(gx)), int(round(gy))
                if 0 <= ix < OUT and 0 <= iy < OUT:
                    m[iy, ix] = 1.0
        return m
    return np.stack([mask, heat(q, 1.0), heat(np.asarray(lattice, np.float32), 0.8)])


class Renders(torch.utils.data.Dataset):
    """Rendered boards (boards3d.py), and optionally real frames with corners (no lattice: their
    square corners are made from the corners by the homography)."""
    def __init__(self, dirs, real=None, train=True):
        self.items = []
        for d in dirs:
            meta = json.load(open(os.path.join(d, 'meta.json')))
            for name, m in meta.items():
                self.items.append((os.path.join(d, name), m['corners'], m['lattice']))
        if real:
            for r in real:
                H = homography(np.array([[0, 0], [8, 0], [8, 8], [0, 8]], np.float64), np.array(r['corners'], np.float64))
                lat = apply(H, np.array([[f, rr] for f in range(9) for rr in range(9)], np.float64))
                self.items.append((r['path'], r['corners'], lat.tolist()))
        self.train = train

    def __len__(self):
        return len(self.items)

    def __getitem__(self, i):
        rng = random.Random() if self.train else random.Random(i)
        path, corners, lattice = self.items[i]
        img = Image.open(path)
        x, (s, dx, dy) = letterbox(img, (0.6, 1.0) if self.train else None, rng if self.train else None)
        pts = lambda p: [[a * s + dx, b * s + dy] for a, b in p]
        c, lat = pts(corners), pts(lattice)
        if self.train and rng.random() < 0.5:
            x = x[:, ::-1].copy()
            c = [[IN - a, b] for a, b in c]
            lat = [[IN - a, b] for a, b in lat]
        return torch.from_numpy(x).permute(2, 0, 1), torch.from_numpy(targets(c, lat))


def augment(x):
    """Light, colour, blur and noise, per image, on the device. x: N,3,IN,IN in 0..255."""
    n, dev = x.shape[0], x.device
    x = x / 255
    x = x ** torch.exp(torch.empty(n, 1, 1, 1, device=dev).uniform_(-0.4, 0.4))
    x = x * torch.empty(n, 3, 1, 1, device=dev).uniform_(0.85, 1.15) * torch.empty(n, 1, 1, 1, device=dev).uniform_(0.6, 1.3)
    grey = torch.rand(n, 1, 1, 1, device=dev) < 0.2
    x = torch.where(grey, x.mean(1, keepdim=True).expand_as(x), x)
    sigma = float(np.random.uniform(0.01, 1.6))
    k = torch.arange(-3, 4, device=dev, dtype=torch.float32)
    g = torch.exp(-k ** 2 / (2 * sigma ** 2)); g = g / g.sum()
    x = F.conv2d(F.pad(x, (3, 3, 0, 0), mode='replicate'), g.view(1, 1, 1, 7).repeat(3, 1, 1, 1), groups=3)
    x = F.conv2d(F.pad(x, (0, 0, 3, 3), mode='replicate'), g.view(1, 1, 7, 1).repeat(3, 1, 1, 1), groups=3)
    x = x + torch.randn_like(x) * torch.empty(n, 1, 1, 1, device=dev).uniform_(0, 0.04)
    return (x.clamp(0, 1) * 255)


# MARK: - Network

def block(i, o):
    return nn.Sequential(nn.Conv2d(i, o, 3, padding=1, bias=False), nn.BatchNorm2d(o), nn.ReLU(inplace=True),
                         nn.Conv2d(o, o, 3, padding=1, bias=False), nn.BatchNorm2d(o), nn.ReLU(inplace=True))


class BoardNet(nn.Module):
    """A U-Net from IN x IN RGB (0..255) to 3 maps at OUT x OUT (logits): playing area, corners,
    square corners."""
    def __init__(self):
        super().__init__()
        ch = [16, 32, 64, 96, 128, 160]
        self.stem = block(3, ch[0])                                    # 256
        self.down = nn.ModuleList([block(ch[k], ch[k + 1]) for k in range(5)])   # 128 .. 8
        self.up = nn.ModuleList([block(ch[k + 1] + ch[k], ch[k]) for k in (4, 3, 2)])   # 16, 32, 64
        self.head = nn.Conv2d(ch[2], 3, 1)
        with torch.no_grad():                                   # start the peak maps near empty (CenterNet's prior)
            self.head.bias.copy_(torch.tensor([0.0, -2.19, -2.19]))

    def forward(self, x):
        x = x / 127.5 - 1
        skips = [self.stem(x)]
        for d in self.down:
            skips.append(d(F.max_pool2d(skips[-1], 2)))
        y = skips[-1]
        for k, u in zip((4, 3, 2), self.up):
            y = F.interpolate(y, scale_factor=2, mode='bilinear', align_corners=False)
            y = u(torch.cat([y, skips[k]], 1))
        return self.head(y)                                            # 64 x 64


def focal(logits, target):
    """CenterNet's penalty-reduced focal loss for peaks on a Gaussian target."""
    p = torch.sigmoid(logits).clamp(1e-4, 1 - 1e-4)
    pos = target.ge(0.99).float()
    neg = 1 - pos
    loss = -(pos * (1 - p) ** 2 * torch.log(p) + neg * (1 - target) ** 4 * p ** 2 * torch.log(1 - p))
    return loss.sum() / pos.sum().clamp(min=1)


def dice(logits, target):
    """1 - soft Dice per image: the board is a tenth of the picture or less, which per-pixel
    cross-entropy alone learns slowly."""
    p = torch.sigmoid(logits)
    return (1 - (2 * (p * target).sum((1, 2)) + 1) / (p.sum((1, 2)) + target.sum((1, 2)) + 1)).mean()


def loss_fn(out, t):
    return (F.binary_cross_entropy_with_logits(out[:, 0], t[:, 0]) + dice(out[:, 0], t[:, 0])
            + 0.5 * focal(out[:, 1], t[:, 1]) + 0.5 * focal(out[:, 2], t[:, 2]))


# MARK: - Fitting the board

def homography(src, dst):
    """The homography taking src points to dst (least squares, DLT, normalised)."""
    def norm(p):
        m, s = p.mean(0), np.sqrt(2) / max(1e-9, np.linalg.norm(p - p.mean(0), axis=1).mean())
        return np.array([[s, 0, -s * m[0]], [0, s, -s * m[1]], [0, 0, 1]])
    Ts, Td = norm(src), norm(dst)
    a = apply(Ts, src); b = apply(Td, dst)
    A = []
    for (x, y), (u, v) in zip(a, b):
        A.append([-x, -y, -1, 0, 0, 0, u * x, u * y, u])
        A.append([0, 0, 0, -x, -y, -1, v * x, v * y, v])
    H = np.linalg.svd(np.array(A))[2][-1].reshape(3, 3)
    H = np.linalg.inv(Td) @ H @ Ts
    return H / H[2, 2]


def apply(H, p):
    p = np.asarray(p, np.float64)
    q = np.c_[p, np.ones(len(p))] @ H.T
    return q[:, :2] / q[:, 2:3]


def peaks(heat, threshold, top):
    """Local maxima of a map (OUT x OUT, 0..1), refined by the centroid round each; in IN pixels."""
    t = torch.from_numpy(heat)[None, None]
    is_max = (t == F.max_pool2d(t, 3, 1, 1))[0, 0].numpy() & (heat > threshold)
    ys, xs = np.nonzero(is_max)
    order = np.argsort(-heat[ys, xs])[:top]
    out = []
    for y, x in zip(ys[order], xs[order]):
        y0, y1, x0, x1 = max(0, y - 1), min(OUT, y + 2), max(0, x - 1), min(OUT, x + 2)
        w = heat[y0:y1, x0:x1]
        gy, gx = np.mgrid[y0:y1, x0:x1]
        out.append(((float((gx * w).sum() / w.sum()) + 0.5) * STRIDE, (float((gy * w).sum() / w.sum()) + 0.5) * STRIDE, float(heat[y, x])))
    return out


def fit_board(maps):
    """The playing area's corners in the IN x IN canvas, from the network's maps (sigmoids), or None."""
    from itertools import combinations
    area, corner, lattice = maps
    inside = area > 0.5
    if inside.sum() < 4:
        return None
    cands = peaks(corner, 0.1, 8)
    if len(cands) < 4:
        return None
    ys, xs = np.mgrid[0:OUT, 0:OUT]
    cx, cy = (xs + 0.5) * STRIDE, (ys + 0.5) * STRIDE
    best = None
    for combo in combinations(range(len(cands)), 4):
        pts = np.array([cands[k][:2] for k in combo])
        c = pts.mean(0)
        pts = pts[np.argsort(np.arctan2(pts[:, 1] - c[1], pts[:, 0] - c[0]))]      # round the board
        if abs(sum(pts[k][0] * pts[(k + 1) % 4][1] - pts[(k + 1) % 4][0] * pts[k][1] for k in range(4))) / 2 < 100:
            continue                                                  # three in a line, or a sliver
        sides = np.stack([(pts[(k + 1) % 4][0] - pts[k][0]) * (cy - pts[k][1]) - (pts[(k + 1) % 4][1] - pts[k][1]) * (cx - pts[k][0])
                          for k in range(4)])
        quad = (sides >= 0).all(0) | (sides <= 0).all(0)
        iou = (quad & inside).sum() / max(1, (quad | inside).sum())
        score = iou + 0.2 * np.mean([cands[k][2] for k in combo])
        if best is None or score > best[0]:
            best = (score, pts)
    if best is None:
        return None
    quad = best[1]
    # Refined on the square corners found: each is named by the board's grid and the homography
    # fitted to all of them.
    H = homography(np.array([[0, 0], [8, 0], [8, 8], [0, 8]], np.float64), quad)
    lat = peaks(lattice, 0.2, 120)
    if len(lat) >= 6:
        p = np.array([q[:2] for q in lat])
        for _ in range(2):
            g = apply(np.linalg.inv(H), p)
            r = np.round(g)
            ok = (np.abs(g - r).max(1) < 0.3) & (r >= 0).all(1) & (r <= 8).all(1)
            # Points on two lines or fewer fix no homography.
            if ok.sum() < 6 or min(len(set(r[ok][:, 0])), len(set(r[ok][:, 1]))) < 3:
                break
            refined = homography(r[ok], p[ok])
            if not np.isfinite(refined).all() or abs(np.linalg.det(refined)) < 1e-12:
                break
            H = refined
    q = apply(H, np.array([[0, 0], [8, 0], [8, 8], [0, 8]], np.float64))
    return q if np.isfinite(q).all() else None


def corner_error(found, label):
    """The worst corner's distance, in square widths, the found quad taken round either way and
    from any corner."""
    label = np.asarray(label, np.float64)
    square = np.mean([np.linalg.norm(label[k] - label[(k + 1) % 4]) for k in range(4)]) / 8
    best = 1e9
    for order in (found, found[::-1]):
        for k in range(4):
            best = min(best, np.linalg.norm(np.roll(order, k, 0) - label, axis=1).max())
    return best / square


def find(net, path, dev):
    """Corners of the playing area in the photo's pixels, or None."""
    img = Image.open(path)
    x, (s, dx, dy) = letterbox(img)
    with torch.no_grad():
        out = torch.sigmoid(net(torch.from_numpy(x).permute(2, 0, 1)[None].float().to(dev)))[0].cpu().numpy()
    q = fit_board(out)
    if q is None:
        return None, out, x
    return (q - [dx, dy]) / s, out, x


# MARK: - Train and measure

def evaluate(net, real, dev, sheet=None):
    net.eval()
    errs, tiles = [], []
    for r in real:
        q, out, x = find(net, r['path'], dev)
        e = 99.0 if q is None else corner_error(q, r['corners'])
        errs.append(e)
        if sheet and len(tiles) < 48 and (e > 0.25 or len(tiles) < 12):
            tiles.append((x, out, e, r['path']))
    errs = np.array(errs)
    if sheet and tiles:
        draw_sheet(tiles, sheet)
    net.train()
    return errs


def draw_sheet(tiles, path):
    rows = []
    for x, out, e, name in tiles:
        a = x.astype(np.float32)
        m = np.kron(out[0], np.ones((STRIDE, STRIDE)))[..., None]
        c = np.kron(np.maximum(out[1], out[2]), np.ones((STRIDE, STRIDE)))[..., None]
        a = a * (0.6 + 0.4 * m) + c * np.array([255, 0, 0]) * 0.8
        rows.append(np.clip(a, 0, 255).astype(np.uint8))
    while len(rows) % 6:
        rows.append(np.zeros_like(rows[0]))
    grid = np.vstack([np.hstack(rows[i:i + 6]) for i in range(0, len(rows), 6)])
    Image.fromarray(grid).save(path)


def report(errs, label):
    found = errs < 99
    return (f'{label}: {len(errs)} frames, within 1/4 square {np.mean(errs < 0.25):.1%}, within 1/2 {np.mean(errs < 0.5):.1%}, '
            f'none found {np.mean(~found):.1%}, median error {np.median(errs[found]) if found.any() else 0:.3f}')


if __name__ == '__main__':
    dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
    if sys.argv[1] == 'train':
        dirs, out_path, epochs = sys.argv[2].split(','), sys.argv[3], int(sys.argv[4])
        real = json.load(open(sys.argv[5])) if len(sys.argv) > 5 else None
        data = Renders(dirs)
        loader = torch.utils.data.DataLoader(data, batch_size=48, shuffle=True, num_workers=4, drop_last=True,
                                             persistent_workers=True)
        net = BoardNet().to(dev)
        opt = torch.optim.AdamW(net.parameters(), lr=2e-3, weight_decay=1e-4)
        steps = epochs * len(loader)
        sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=2e-3, total_steps=steps, pct_start=0.1)
        print(f'{len(data)} renders, {sum(p.numel() for p in net.parameters()) / 1e6:.2f} M parameters', flush=True)
        for epoch in range(epochs):
            t0, total, n = time.time(), 0.0, 0
            for x, t in loader:
                x, t = augment(x.float().to(dev)), t.to(dev)
                loss = loss_fn(net(x), t)
                opt.zero_grad(); loss.backward(); opt.step(); sched.step()
                total += loss.item(); n += 1
            torch.save(net.state_dict(), out_path)
            line = f'epoch {epoch + 1}: loss {total / n:.3f} ({time.time() - t0:.0f}s)'
            print(line, end='', flush=True)
            line = ''
            if real:
                line += '  ' + report(evaluate(net, real, dev), 'real')
            print(line, flush=True)
    elif sys.argv[1] == 'quads':
        # The corners found in each frame, for refine.py: frames from a real.json or a folder.
        net = BoardNet().to(dev)
        net.load_state_dict(torch.load(sys.argv[2], map_location=dev, weights_only=True))
        net.eval()
        src = sys.argv[3]
        paths = ([os.path.join(src, f) for f in sorted(os.listdir(src)) if f.endswith('.jpg')] if os.path.isdir(src)
                 else [r['path'] for r in json.load(open(src))])
        quads = {}
        for path in paths:
            q = find(net, path, dev)[0]
            quads[path] = None if q is None else q.tolist()
        json.dump(quads, open(sys.argv[4], 'w'))
        print(f'{len(quads)} frames, {sum(q is not None for q in quads.values())} with a board')
    else:
        net = BoardNet().to(dev)
        net.load_state_dict(torch.load(sys.argv[2], map_location=dev, weights_only=True))
        net.eval()
        real = json.load(open(sys.argv[3]))
        errs = evaluate(net, real, dev, sys.argv[4] if len(sys.argv) > 4 else None)
        for s in sorted({r.get('set', '') for r in real}):
            idx = [i for i, r in enumerate(real) if r.get('set', '') == s]
            print(report(errs[idx], s or 'all'))
