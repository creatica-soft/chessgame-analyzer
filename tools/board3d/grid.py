"""Finds a real chessboard's playing area in a photo: the 9x9 lattice of square corners.

1. X-corners: where four squares meet, light and dark diagonally opposite. A saddle of the
   smoothed brightness, checked by the pattern round it.
2. Lattice: a cell of four X-corners is taken as one square; the homography it gives maps every
   X-corner into lattice coordinates, and the cell that puts most of them on whole numbers wins.
   Refined on all of those points.
3. Board: of the lattice's 8x8 blocks of squares, the one whose squares alternate light and dark
   most clearly, and whose border does not continue the pattern.
"""
import sys, itertools
import numpy as np
import cv2

WORK = 960  # longer side the search works at
FLAT_WEIGHT = 10  # see block_score


RING = np.arange(16) * (2 * np.pi / 16)


def x_pattern(g, x, y, r):
    """The pattern round an X-corner, at any angle: on a ring round it the brightness changes from
    light to dark four times, and is alike at opposite points (a corner of four squares is
    symmetric about its centre, and stays so in perspective)."""
    px, py = x + r * np.cos(RING), y + r * np.sin(RING)
    x0, y0 = np.floor(px).astype(int), np.floor(py).astype(int)
    fx, fy = px - x0, py - y0
    s = (g[y0, x0] * (1 - fx) * (1 - fy) + g[y0, x0 + 1] * fx * (1 - fy)
         + g[y0 + 1, x0] * (1 - fx) * fy + g[y0 + 1, x0 + 1] * fx * fy)
    o = np.sort(s)
    contrast = o[-4:].mean() - o[:4].mean()
    if contrast < 25:
        return False
    if np.abs(s[:8] - s[8:]).mean() > contrast * 0.3:
        return False
    above = s > (o[-4:].mean() + o[:4].mean()) / 2
    return int((above != np.roll(above, 1)).sum()) == 4


def quadrant_pattern(g, x, y, r):
    """The pattern round an X-corner whose squares' edges run near the picture's axes: of the four
    diagonal quadrants, opposite ones alike, neighbours different."""
    q = [g[y - r:y - 1, x - r:x - 1].mean(), g[y - r:y - 1, x + 2:x + r + 1].mean(),
         g[y + 2:y + r + 1, x + 2:x + r + 1].mean(), g[y + 2:y + r + 1, x - r:x - 1].mean()]
    a, b = (q[0] + q[2]) / 2, (q[1] + q[3]) / 2
    contrast = abs(a - b)
    return not (contrast < 25 or abs(q[0] - q[2]) > contrast * 0.6 or abs(q[1] - q[3]) > contrast * 0.6)


def xcorners(gray, sigma=2.0, max_points=400, ring=False):
    g = cv2.GaussianBlur(gray.astype(np.float32), (0, 0), sigma)
    ixx = cv2.Sobel(g, cv2.CV_32F, 2, 0, ksize=3)
    iyy = cv2.Sobel(g, cv2.CV_32F, 0, 2, ksize=3)
    ixy = cv2.Sobel(g, cv2.CV_32F, 1, 1, ksize=3)
    saddle = ixy * ixy - ixx * iyy          # positive at saddle points
    saddle[saddle < 0] = 0
    # Local maxima.
    dil = cv2.dilate(saddle, np.ones((9, 9), np.uint8))
    peaks = (saddle == dil) & (saddle > saddle.max() * 0.02)
    ys, xs = np.nonzero(peaks)
    order = np.argsort(-saddle[ys, xs])[:max_points * 3]
    pts = []
    h, w = gray.shape
    r = 6
    for i in order:
        x, y = xs[i], ys[i]
        if x < r + 1 or y < r + 1 or x >= w - r - 1 or y >= h - r - 1:
            continue
        if not (x_pattern if ring else quadrant_pattern)(g, x, y, r):
            continue
        pts.append((x, y))
        if len(pts) >= max_points:
            break
    pts = np.array(pts, np.float32)
    if len(pts):
        # Sub-pixel: OpenCV's corner refinement works on X-corners.
        pts = cv2.cornerSubPix(g.astype(np.uint8) if g.dtype != np.uint8 else g, pts.reshape(-1, 1, 2),
                               (4, 4), (-1, -1), (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.01)).reshape(-1, 2)
    return pts


def distinct(lat, inl):
    """How many different lattice positions the inlying points take: a homography that maps many
    points onto one position (collapsed) fits nothing."""
    return len({(int(a), int(b)) for a, b in np.round(lat[inl])})


def fit_lattice(pts, gray=None, tries=4000, rng=np.random.default_rng(0)):
    """The homography from lattice coordinates to the image that puts most points on whole numbers."""
    n = len(pts)
    if n < 8:
        return None, None
    D = np.linalg.norm(pts[:, None, :] - pts[None, :, :], axis=2)
    near = np.argsort(D, axis=1)[:, :7]
    best = (0, None)
    candidates = []
    unit = np.array([[0, 0], [1, 0], [1, 1], [0, 1]], np.float32)
    for _ in range(tries):
        p = rng.integers(n)
        nb = near[p, 1:]
        if len(nb) < 3:
            continue
        a, b = rng.choice(nb, 2, replace=False)
        u, v = pts[a] - pts[p], pts[b] - pts[p]
        cross = u[0] * v[1] - u[1] * v[0]
        if abs(cross) < 0.3 * np.linalg.norm(u) * np.linalg.norm(v):
            continue                       # nearly parallel: not two sides of a square
        if cross < 0:
            a, b, u, v = b, a, v, u
        guess = pts[p] + u + v
        dg = np.linalg.norm(pts - guess, axis=1)
        c = int(np.argmin(dg)); dd = dg[c]
        if dd > 0.25 * min(np.linalg.norm(u), np.linalg.norm(v)):
            continue
        quad = np.array([pts[p], pts[a], pts[c], pts[b]], np.float32)
        H = cv2.getPerspectiveTransform(unit, quad)
        lat = cv2.perspectiveTransform(pts.reshape(-1, 1, 2), np.linalg.inv(H)).reshape(-1, 2)
        err = np.abs(lat - np.round(lat)).max(1)
        # Near the cell only: a homography from one cell drifts further out, the more so the
        # steeper the view. Grown outward below.
        local = distinct(lat, (err < 0.15) & (np.abs(lat - 0.5).max(1) < 2.6))
        candidates.append((local, H))
    if not candidates:
        return None, None
    for local, H in sorted(candidates, key=lambda t: -t[0])[:25]:
        for radius in (2.6, 4.6, 7.0, 99):
            lat = cv2.perspectiveTransform(pts.reshape(-1, 1, 2), np.linalg.inv(H)).reshape(-1, 2)
            r = np.round(lat)
            inl = (np.abs(lat - r).max(1) < 0.15) & (np.abs(lat - 0.5).max(1) < radius)
            if distinct(lat, inl) < 5:
                break
            H2, _ = cv2.findHomography(r[inl].astype(np.float32), pts[inl].astype(np.float32), 0)
            if H2 is None or np.size(H2) != 9:
                break
            H = H2
        lat = cv2.perspectiveTransform(pts.reshape(-1, 1, 2), np.linalg.inv(H)).reshape(-1, 2)
        score = distinct(lat, np.abs(lat - np.round(lat)).max(1) < 0.15)
        if score > best[0]:
            best = (score, H)
    if best[1] is None:
        return None, None
    # Refine on the inliers, and repeat once with the better homography.
    H = best[1]
    for _ in range(3):
        lat = cv2.perspectiveTransform(pts.reshape(-1, 1, 2), np.linalg.inv(H)).reshape(-1, 2)
        r = np.round(lat)
        inl = np.abs(lat - r).max(1) < 0.15
        if inl.sum() < 8:
            break
        H2, _ = cv2.findHomography(r[inl].astype(np.float32), pts[inl].astype(np.float32), 0)
        if H2 is None or np.size(H2) != 9:
            break
        H = H2
    lat = cv2.perspectiveTransform(pts.reshape(-1, 1, 2), np.linalg.inv(H)).reshape(-1, 2)
    r = np.round(lat).astype(int)
    inl = np.abs(lat - r).max(1) < 0.15
    H = reduce_basis(H, pts)
    lat = cv2.perspectiveTransform(pts.reshape(-1, 1, 2), np.linalg.inv(H)).reshape(-1, 2)
    r = np.round(lat).astype(int)
    if gray is not None and inl.sum() >= 4:
        H = choose_basis(H, r[inl], gray)
        lat = cv2.perspectiveTransform(pts.reshape(-1, 1, 2), np.linalg.inv(H)).reshape(-1, 2)
        r = np.round(lat).astype(int)
        inl = np.abs(lat - r).max(1) < 0.15
    return H, r[inl]


# One shear step either way, in either direction; the identity first, so that it wins a tie.
STEPS = [np.eye(3)] + [np.array(m, float) for m in (
    [[1, 1, 0], [0, 1, 0], [0, 0, 1]], [[1, -1, 0], [0, 1, 0], [0, 0, 1]],
    [[1, 0, 0], [1, 1, 0], [0, 0, 1]], [[1, 0, 0], [-1, 1, 0], [0, 0, 1]])]


def reduce_basis(H, pts):
    """The same lattice with its squarest cell in the picture (Gauss's reduction of the image
    steps at the points' centre). That is the board's squares in most views; seen corner-on, a
    square looks like a flat diamond, and the reduction may take its short diagonal for a side:
    `choose_basis` then corrects it by one shear step."""
    centre = pts.mean(0).reshape(1, 1, 2).astype(np.float32)
    T = np.eye(3)
    for _ in range(20):
        M = H @ T
        c = cv2.perspectiveTransform(centre, np.linalg.inv(M)).reshape(2)
        def step(d):
            q = cv2.perspectiveTransform(np.array([[c], [c + d]], np.float32), M).reshape(2, 2)
            return q[1] - q[0]
        u, v = step(np.array([1, 0], np.float32)), step(np.array([0, 1], np.float32))
        if not (np.isfinite(u).all() and np.isfinite(v).all()) or min(u @ u, v @ v) < 4:
            return H
        if u @ u > v @ v:
            T = T @ np.array([[0, 1, 0], [1, 0, 0], [0, 0, 1]], float)
            continue
        m = round(float(u @ v) / float(u @ u))
        if m == 0:
            break
        T = T @ np.array([[1, -m, 0], [0, 1, 0], [0, 0, 1]], float)
    return H @ T


def choose_basis(H, lat, gray):
    """The board's own squares among the lattice's bases. Any whole-number shear of the lattice
    passes through the same points, so the fit cannot choose; nor can the cells' shape (a board
    seen corner-on has squares that look like flat diamonds, shorter across than along a side).
    The squares' colours can: in the board's basis each cell's middle lies inside one square, and
    cells alternate light and dark; in a sheared one the middles fall on the squares' edges."""
    # Judged on the cells all four of whose corners were found: they are on the board. The
    # lattice's whole span also takes in stray points off the board, whose cells would swamp it.
    found = {(int(a), int(b)) for a, b in lat}
    cells = np.array([[i + 0.5, j + 0.5] for i, j in found
                      if (i + 1, j) in found and (i, j + 1) in found and (i + 1, j + 1) in found], np.float32)
    if len(cells) < 6:
        lo, hi = lat.min(0), lat.max(0)
        cells = np.array([[i + 0.5, j + 0.5] for i in range(lo[0] - 1, hi[0] + 1) for j in range(lo[1] - 1, hi[1] + 1)], np.float32)
    h, w = gray.shape
    best = (-1, H)
    for T in STEPS:
        M = H @ T
        Ti = np.linalg.inv(T)
        # The same image cells, named in the new basis: their middles are what is sampled.
        mids = cv2.perspectiveTransform(cv2.perspectiveTransform(cells.reshape(-1, 1, 2), Ti), np.eye(3)).reshape(-1, 2)
        ij = np.floor(mids)
        centres = cv2.perspectiveTransform((ij + 0.5).reshape(-1, 1, 2).astype(np.float32), M).reshape(-1, 2)
        ok = (centres[:, 0] >= 0) & (centres[:, 1] >= 0) & (centres[:, 0] < w) & (centres[:, 1] < h)
        if ok.sum() < 8:
            continue
        v = gray[centres[ok, 1].astype(int), centres[ok, 0].astype(int)].astype(np.float32)
        parity = (ij[ok].sum(1) % 2).astype(bool)
        if parity.all() or (~parity).all():
            continue
        contrast = abs(np.median(v[parity]) - np.median(v[~parity]))
        if contrast > best[0] * 1.05:      # a clear gain only: the identity wins ties
            best = (contrast, M)
    return best[1]


GRID = np.array([[[x, y]] for x in np.linspace(0.12, 0.88, 5) for y in np.linspace(0.12, 0.88, 5)], np.float32)


def square_values(gray, H, i0, j0, n=10):
    """Brightness of each lattice square (i, j) from (i0-1, j0-1), n x n: the median of the part
    of the square nearest the camera (lowest in the picture). Pieces stand up from their squares
    and hide what is behind them, higher in the picture; the near part is the likeliest seen."""
    h, w = gray.shape
    offs = np.array([[i0 - 1 + a, j0 - 1 + b] for b in range(n) for a in range(n)], np.float32)
    allp = (GRID.reshape(1, -1, 2) + offs[:, None, :]).reshape(-1, 1, 2)
    p = cv2.perspectiveTransform(allp, H).reshape(n * n, -1, 2)
    inside = ((p[..., 0] >= 0) & (p[..., 1] >= 0) & (p[..., 0] < w) & (p[..., 1] < h)).all(1)
    order = np.argsort(-p[..., 1], axis=1)[:, :8]
    near = np.take_along_axis(p, order[..., None], axis=1)
    xi = np.clip(near[..., 0].astype(int), 0, w - 1); yi = np.clip(near[..., 1].astype(int), 0, h - 1)
    vals = np.median(gray[yi, xi].astype(np.float32), axis=1)
    vals[~inside] = np.nan
    return vals.reshape(n, n)


def block_score(gray, H, lat, i0, j0):
    """How well the 8x8 block of lattice squares from (i0, j0) fits a board: None if it is mostly
    outside the picture, else (score, i0, j0, corners inside, contrast, carry, flat lines)."""
    v = square_values(gray, H, i0, j0)
    inner = v[1:9, 1:9]
    if np.isnan(inner).mean() > 0.2:
        return None
    parity = (np.add.outer(np.arange(8), np.arange(8)) % 2).astype(bool)
    a, b = np.nanmedian(inner[parity]), np.nanmedian(inner[~parity])
    contrast = abs(a - b)
    # Every row and column of a board alternates light and dark, square to square. A block taking
    # in a row of the board's wooden frame has a line that does not (pieces standing on the
    # squares spoil single squares, which the medians above shrug off, but not a whole line).
    sign = np.where(parity, 1.0, -1.0) * (1.0 if a > b else -1.0)
    lines = [inner[k, :] for k in range(8)] + [inner[:, k] for k in range(8)]
    signs = [sign[k, :] for k in range(8)] + [sign[:, k] for k in range(8)]
    flat = 0.0
    for u, sg in zip(lines, signs):
        d = (u[:-1] - u[1:]) * sg[:-1]
        d = d[~np.isnan(d)]
        if len(d) >= 4:
            flat += max(0.0, 0.4 - float(np.mean(d)) / (contrast + 1e-6))
    misfit = flat
    # The X-corners found inside this block, out of the 49 there are.
    corners_in = ((lat[:, 0] > i0) & (lat[:, 0] < i0 + 8) & (lat[:, 1] > j0) & (lat[:, 1] < j0 + 8)).sum()
    # The ring of squares round it should not carry the pattern on; but not the far side, where
    # pieces stand in front.
    sides = {'L': [(0, k) for k in range(1, 9)], 'R': [(9, k) for k in range(1, 9)],
             'T': [(k, 0) for k in range(1, 9)], 'B': [(k, 9) for k in range(1, 9)]}
    centre = lambda x, y: cv2.perspectiveTransform(np.array([[[i0 - 1 + x + 0.5, j0 - 1 + y + 0.5]]], np.float32), H)[0, 0, 1]
    far = min(sides, key=lambda k: np.mean([centre(x, y) for x, y in sides[k]]))
    ring = []
    for side, cells in sides.items():
        if side == far:
            continue
        for (x, y) in cells:
            val = v[y, x]
            if np.isnan(val):
                continue
            expect_a = ((x - 1) + (y - 1)) % 2 == 1
            ring.append((val - (a + b) / 2) / ((a - b) / 2 + 1e-6) * (1 if expect_a else -1))
    carry = max(0.0, np.mean(ring)) if ring else 0.0
    score = corners_in + 10 * contrast / 255 - 20 * carry - FLAT_WEIGHT * misfit
    return score, i0, j0, corners_in, contrast, carry, misfit


def place_board(gray, H, lat):
    """The 8x8 block of lattice squares that is the board: corners at lattice (i0, j0)..(i0+8, j0+8)."""
    lo, hi = lat.min(0), lat.max(0)
    best = None
    for i0 in range(lo[0] - 2, hi[0] - 5):
        for j0 in range(lo[1] - 2, hi[1] - 5):
            s = block_score(gray, H, lat, i0, j0)
            if s is not None and (best is None or s[0] > best[0]):
                best = s
    return None if best is None else best[1:6]


def plausible(q):
    """A board seen in perspective is a convex quadrilateral without very sharp corners; a lattice
    fitted to stray points can make a thin sliver instead."""
    crosses = []
    for k in range(4):
        u, v = q[k - 1] - q[k], q[(k + 1) % 4] - q[k]
        crosses.append(u[0] * v[1] - u[1] * v[0])
        cos = np.dot(u, v) / (np.linalg.norm(u) * np.linalg.norm(v) + 1e-9)
        if np.arccos(np.clip(cos, -1, 1)) <= np.radians(20):
            return False
    return all(c > 0 for c in crosses) or all(c < 0 for c in crosses)


def find_board(image, ring=False):
    """The board's corners in `image` (top left, top right, bottom right, bottom left as seen), or None.
    The X-corners are checked by quadrants, or with `ring` by a ring round them: the ring finds
    boards turned near 45 degrees, which the quadrants miss, but takes more points on the board's
    printed border and pieces, and places the board a square off more often. locate.py tries the
    quadrants first."""
    h, w = image.shape[:2]
    k = WORK / max(h, w)
    small = cv2.resize(image, (int(w * k), int(h * k)), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    pts = xcorners(gray, ring=ring)
    H, lat = fit_lattice(pts, gray)
    if H is None or len(lat) == 0:
        return None, pts / k, None
    placed = place_board(gray, H, lat)
    if placed is None:
        return None, pts / k, None
    i0, j0 = placed[:2]
    quad = cv2.perspectiveTransform(np.array([[[i0, j0]], [[i0 + 8, j0]], [[i0 + 8, j0 + 8]], [[i0, j0 + 8]]], np.float32), H).reshape(-1, 2)
    if not plausible(quad):
        return None, pts / k, None
    # Lattice to image, in full-size pixels, with the board's corner at lattice (0, 0).
    S = np.diag([1 / k, 1 / k, 1]) @ H @ np.array([[1, 0, i0], [0, 1, j0], [0, 0, 1]], np.float64)
    return quad / k, pts / k, (S, placed)


def draw(image, quad, pts, S):
    out = image.copy()
    for x, y in pts:
        cv2.circle(out, (int(x), int(y)), 4, (0, 0, 255), -1)
    if S is not None:
        H = S[0]
        for t in range(9):
            for a, b in [((t, 0), (t, 8)), ((0, t), (8, t))]:
                p = cv2.perspectiveTransform(np.array([[a], [b]], np.float32), H).reshape(-1, 2)
                cv2.line(out, tuple(map(int, p[0])), tuple(map(int, p[1])), (0, 255, 0), 2)
    return out


if __name__ == '__main__':
    import os
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)
    files = sorted(f for f in os.listdir(src) if f.endswith('.jpg'))
    if len(sys.argv) > 3:
        files = files[::int(sys.argv[3])]
    for f in files:
        img = cv2.imread(os.path.join(src, f))
        quad, pts, S = find_board(img)
        info = '' if S is None else f'corners inside {S[1][2]}/49 contrast {S[1][3]:.0f} carry {S[1][4]:.2f}'
        print(f, 'FOUND' if quad is not None else 'none', len(pts), info)
        cv2.imwrite(os.path.join(dst, f), draw(img, quad, pts, S))
