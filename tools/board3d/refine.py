"""The learned finder's board (finder.py quads), placed exactly on the board's X-corners (grid.py).

The network places the playing area within half a square nearly always, but no closer than a
quarter square or so: its maps are a quarter of its 256-pixel input. The X-corners are exact to a
pixel but are found on pieces, clutter and the table too, and a lattice fitted to them alone can
land a square off or on the wrong grid. Together: the network's board names each X-corner's square
corner (the nearest whole inner lattice point, which is right while the board is less than half a
square off), and the homography is fitted again to the X-corners that land on one, tighter each
pass. A refit that moves the board more than MAX_MOVE squares is not trusted, and the network's
board is kept.

    tools/work/venv/bin/python refine.py quads.json out.json [real.json [sheet.jpg]]

With real.json, prints how far the boards are from the labels before and after, per set, as
finder.py eval does. Run from tools/work.
"""
import sys, os, json
import numpy as np
import cv2

sys.path.insert(0, os.path.dirname(__file__))
from grid import xcorners, WORK

MAX_MOVE = float(os.environ.get("MAX_MOVE", 0.8))   # in squares: a slip of the lattice moves the board a whole one
TRIM = os.environ.get("TRIM", "1") == "1"
LATTICE_CORNERS = np.array([[0, 0], [8, 0], [8, 8], [0, 8]], np.float32)


def merged_xcorners(gray):
    """X-corners by both of grid.py's checks: the quadrants miss boards turned near 45 degrees,
    the ring takes more stray points, which the lattice sorts out here."""
    pts = [p for p in (xcorners(gray), xcorners(gray, ring=True)) if len(p)]
    if not pts:
        return np.zeros((0, 2), np.float32)
    pts = np.concatenate(pts)
    keep = []
    for p in pts:
        if all(np.linalg.norm(p - q) > 3 for q in keep):
            keep.append(p)
    return np.array(keep, np.float32)


def refine(image, quad):
    """The board's corners, refined on the X-corners, and how many X-corners the fit used (0 when
    the network's corners are kept)."""
    h, w = image.shape[:2]
    k = WORK / max(h, w)
    small = cv2.resize(image, (int(w * k), int(h * k)), interpolation=cv2.INTER_AREA)
    gray = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY)
    q0 = np.asarray(quad, np.float32) * k
    H = cv2.getPerspectiveTransform(LATTICE_CORNERS, q0)
    pts = merged_xcorners(gray)
    if len(pts) < 8:
        return np.asarray(quad), 0
    used = 0
    for tol in (0.3, 0.2, 0.12):
        g = cv2.perspectiveTransform(pts.reshape(-1, 1, 2), np.linalg.inv(H)).reshape(-1, 2)
        r = np.round(g)
        d = np.abs(g - r).max(1)
        # Only the 7 x 7 inner corners are X-corners: on the playing area's edge the squares meet
        # the frame, whose inlay lines and rim make corners of their own a little outside it.
        ok = (d < tol) & (r >= 1).all(1) & (r <= 7).all(1)
        # One X-corner per square corner: the one nearest it.
        best = {}
        for i in np.nonzero(ok)[0]:
            key = (int(r[i, 0]), int(r[i, 1]))
            if key not in best or d[i] < d[best[key]]:
                best[key] = i
        idx = np.array(list(best.values()), int)
        # Points on two lines or fewer fix no homography.
        if len(idx) < 8 or min(len({int(v) for v in r[idx, 0]}), len({int(v) for v in r[idx, 1]})) < 3:
            break
        H, _ = cv2.findHomography(r[idx].astype(np.float32), pts[idx], 0)
        # Once more without the points the fit misses by far (an X-corner on a piece, or placed a
        # few pixels off): least squares lets a few pull the corners, which lie beyond them all.
        miss = np.linalg.norm(cv2.perspectiveTransform(r[idx].reshape(-1, 1, 2).astype(np.float32), H).reshape(-1, 2) - pts[idx], axis=1)
        keep = miss <= max(2.0, 3 * np.median(miss))
        if TRIM and not keep.all() and keep.sum() >= 8:
            idx = idx[keep]
            H, _ = cv2.findHomography(r[idx].astype(np.float32), pts[idx], 0)
        used = len(idx)
    if not used:
        return np.asarray(quad), 0
    q = cv2.perspectiveTransform(LATTICE_CORNERS.reshape(-1, 1, 2), H).reshape(-1, 2)
    square = np.mean([np.linalg.norm(q0[i] - q0[(i + 1) % 4]) for i in range(4)]) / 8
    if not np.isfinite(q).all() or np.linalg.norm(q - q0, axis=1).max() > MAX_MOVE * square:
        return np.asarray(quad), 0
    return q / k, used


def corner_error(found, label):
    """As finder.py: the worst corner's distance in square widths, the quad taken round either way
    and from any corner."""
    found, label = np.asarray(found, np.float64), np.asarray(label, np.float64)
    square = np.mean([np.linalg.norm(label[k] - label[(k + 1) % 4]) for k in range(4)]) / 8
    best = 1e9
    for order in (found, found[::-1]):
        for k in range(4):
            best = min(best, np.linalg.norm(np.roll(order, k, 0) - label, axis=1).max())
    return best / square


def report(errs, label):
    errs = np.asarray(errs)
    found = errs < 99
    return (f'{label}: {len(errs)} frames, within 1/4 square {np.mean(errs < 0.25):.1%}, within 1/2 {np.mean(errs < 0.5):.1%}, '
            f'none found {np.mean(~found):.1%}, median error {np.median(errs[found]) if found.any() else 0:.3f}')


def draw_sheet(rows, path, tile=320):
    """Frames with the network's board (red), the refined one (green) and the label (blue)."""
    tiles = []
    for p, net_q, ref_q, label, text in rows:
        img = cv2.imread(p)
        s = tile / max(img.shape[:2])
        img = cv2.resize(img, (int(img.shape[1] * s), int(img.shape[0] * s)))
        for q, colour in ((label, (255, 80, 0)), (net_q, (0, 0, 255)), (ref_q, (0, 220, 0))):
            if q is not None:
                cv2.polylines(img, [np.int32(np.asarray(q) * s)], True, colour, 1, cv2.LINE_AA)
        canvas = np.full((tile, tile, 3), 40, np.uint8)
        canvas[:img.shape[0], :img.shape[1]] = img
        cv2.putText(canvas, text, (4, tile - 6), cv2.FONT_HERSHEY_SIMPLEX, 0.4, (255, 255, 255), 1, cv2.LINE_AA)
        tiles.append(canvas)
    while len(tiles) % 6:
        tiles.append(np.full((tile, tile, 3), 40, np.uint8))
    cv2.imwrite(path, np.vstack([np.hstack(tiles[i:i + 6]) for i in range(0, len(tiles), 6)]))


if __name__ == '__main__':
    quads = json.load(open(sys.argv[1]))
    out = {}
    for path, q in quads.items():
        out[path] = None if q is None else refine(cv2.imread(path), q)[0].tolist()
    json.dump(out, open(sys.argv[2], 'w'))
    if len(sys.argv) > 3:
        real = json.load(open(sys.argv[3]))
        before = {r['path']: 99.0 if quads.get(r['path']) is None else corner_error(quads[r['path']], r['corners']) for r in real}
        after = {r['path']: 99.0 if out.get(r['path']) is None else corner_error(out[r['path']], r['corners']) for r in real}
        for s in sorted({r.get('set', '') for r in real}):
            rs = [r for r in real if r.get('set', '') == s]
            print(report([before[r['path']] for r in rs], f'{s or "all"} network'))
            print(report([after[r['path']] for r in rs], f'{s or "all"} refined'))
        if len(sys.argv) > 4:
            worst = sorted(real, key=lambda r: -after[r['path']])[:36]
            draw_sheet([(r['path'], quads[r['path']], out[r['path']], r['corners'],
                         f'{os.path.basename(r["path"])} {before[r["path"]]:.2f} -> {after[r["path"]]:.2f}') for r in worst], sys.argv[4])
