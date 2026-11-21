"""Cuts every square of every located frame into a tall crop, labelled from the game.

A piece stands on its square and rises up the picture, so a square's crop is as wide as the square
(and a little more) and reaches about two squares' widths above its front edge. The pieces of the
squares behind show in it too: the classifier learns to name the piece standing at the bottom.
"""
import sys, os, json
import numpy as np
import cv2
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import locate
import cropset

CLASSES = '.PNBRQKpnbrqk'
CW, CH = 48, 96          # crop size: width, height
WIDE, TALL = 1.25, 2.4   # crop width and height, in widths of the square's front edge


def crop_square(img, Hb, f, r):
    corners = cv2.perspectiveTransform(np.array([[[f, r]], [[f + 1, r]], [[f + 1, r + 1]], [[f, r + 1]]], np.float32), Hb).reshape(-1, 2)
    xs, ys = corners[:, 0], corners[:, 1]
    # The front edge: the two corners lowest in the picture.
    front = corners[np.argsort(-ys)[:2]]
    width = np.linalg.norm(front[0] - front[1])
    cx = xs.mean()
    bottom = ys.max() + 0.08 * width
    x0, x1 = cx - WIDE * width / 2, cx + WIDE * width / 2
    y0, y1 = bottom - TALL * width, bottom
    # Affine map of the box to the crop, so boxes running past the picture are filled by edge pixels.
    M = np.array([[CW / (x1 - x0), 0, -x0 * CW / (x1 - x0)], [0, CH / (y1 - y0), -y0 * CH / (y1 - y0)]], np.float32)
    return cv2.warpAffine(img, M, (CW, CH), flags=cv2.INTER_AREA, borderMode=cv2.BORDER_REPLICATE)


def piece_at(board_fen, f, r):
    rows = board_fen.split('/')
    row = rows[7 - r]
    col = 0
    for ch in row:
        if ch.isdigit():
            col += int(ch)
        else:
            if col == f:
                return ch
            col += 1
    return '.'


if __name__ == '__main__':
    frames, located, labels, out = sys.argv[1:5]
    loc = json.load(open(located))
    lab = json.load(open(labels))
    kept = sorted(f for f, e in loc.items() if e.get('colours'))
    w = cropset.Writer(out, 64 * len(kept))
    for f in kept:
        clip = f.split('-')[0].split('.')[0]          # REN_<n>-000.jpg, BRD_<n>.jpg
        img = cv2.imread(os.path.join(frames, f))
        Hb = locate.board_homography(np.array(loc[f]['corners'], np.float32))
        for fi in range(8):
            for ri in range(8):
                w.add(cv2.cvtColor(crop_square(img, Hb, fi, ri), cv2.COLOR_BGR2RGB),
                      CLASSES.index(piece_at(lab[clip], fi, ri)), int(clip[4:]), f'{f}:{"abcdefgh"[fi]}{ri + 1}')
    n = w.close()
    print(n, 'crops from', len(kept), 'frames', np.bincount(cropset.load(out)['y'], minlength=13))
