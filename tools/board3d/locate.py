"""Runs the board finder over every frame and names the corners: a1, h1, h8, a8 in the image.

The clips are filmed from White's side, so rank 1 is the board edge nearest the camera (lowest in
the picture) and the a-file is its left end. Checked by the squares' colours: a1 is dark, so the
squares with file + rank even must be the darker half. A frame is kept only if the finder put the
board on a grid that alternates clearly and the colours agree.
"""
import sys, os, json
import numpy as np
import cv2
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import grid

SKIP = {'IMG_9031', 'IMG_9032'}   # filmed from the side and from Black's side


def name_corners(quad):
    """quad: the board's four corners in lattice order. Returns a1, h1, h8, a8."""
    q = np.asarray(quad)
    sides = [(k, (k + 1) % 4) for k in range(4)]
    near = max(sides, key=lambda s: q[s[0], 1] + q[s[1], 1])        # lowest edge in the picture
    a, b = near
    a1, h1 = (a, b) if q[a, 0] < q[b, 0] else (b, a)
    # The corner next to a1 that is not h1 is a8; the remaining one is h8.
    a8 = [k for k in ((a1 + 1) % 4, (a1 + 3) % 4) if k != h1][0]
    h8 = [k for k in range(4) if k not in (a1, h1, a8)][0]
    return q[[a1, h1, h8, a8]]


def board_homography(corners):
    """Board coordinates (file, rank in 0..8, a1's corner at 0,0) to image pixels."""
    src = np.array([[0, 0], [8, 0], [8, 8], [0, 8]], np.float32)
    return cv2.getPerspectiveTransform(src, corners.astype(np.float32))


def colours_agree(gray, Hb):
    """Dark squares (file + rank even, as a1) darker than light ones, judged on the part of each
    square nearest the camera."""
    g = gray.astype(np.float32)
    h, w = g.shape
    dark, light = [], []
    for f in range(8):
        for r in range(8):
            p = cv2.perspectiveTransform(grid.GRID + np.array([f, r], np.float32), Hb).reshape(-1, 2)
            if (p < 0).any() or (p[:, 0] >= w).any() or (p[:, 1] >= h).any():
                continue
            near = p[np.argsort(-p[:, 1])[:8]]
            v = np.median([g[int(y), int(x)] for x, y in near])
            (dark if (f + r) % 2 == 0 else light).append(v)
    if len(dark) < 16 or len(light) < 16:
        return False, 0.0
    d, l = np.median(dark), np.median(light)
    return bool(d < l - 30), float(l - d)


if __name__ == '__main__':
    src, out = sys.argv[1], sys.argv[2]
    files = sorted(f for f in os.listdir(src) if f.endswith('.jpg'))
    result = {}
    kept = 0
    for f in files:
        clip = f.split('-')[0]
        if clip in SKIP:
            continue
        img = cv2.imread(os.path.join(src, f))
        quad, pts, S = grid.find_board(img)
        entry = {'found': quad is not None}
        if quad is not None:
            corners = name_corners(quad)
            Hb = board_homography(corners)
            gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
            ok, diff = colours_agree(gray, Hb)
            entry.update(corners=corners.tolist(), colours=bool(ok), contrast=float(diff),
                         inside=int(S[1][2]))
            if ok:
                kept += 1
        result[f] = entry
    json.dump(result, open(out, 'w'), indent=0)
    found = sum(e['found'] for e in result.values())
    print(f'{len(result)} frames: board found in {found}, kept (colours agree) {kept}')
