"""Settles which way round the board stands in each frame of clips where it was turned while filmed.

locate.py --turning names the corners so that a1 is a dark corner, which leaves the board possibly
half turned: the real a1 may be at the named h8. An existing classifier reads the crops both ways
round and the frame is labelled the way its reading fits the known position better. Frames where
the two fit about equally are dropped, and so are frames read with many squares wrong either way:
those are nearly all a grid placed a square off (a shifted grid's colours agree with the naming
once it is moved round a corner), not hard views. Also prints, per clip, how well the reading fits the clip's
position and the positions one move either side, to catch a clip given the wrong position.

usage: orient.py crops-raw.npz labels.json model.pt out.npz [min-margin] [max-wrong]
"""
import sys, json
import numpy as np
import torch, torch.nn.functional as F
from train3d import PieceNet, CLASSES


def piece_at(board_fen, f, r):
    """As crops.piece_at (crops.py needs OpenCV, which the PyTorch environment lacks)."""
    row, col = board_fen.split('/')[7 - r], 0
    for ch in row:
        if ch.isdigit():
            col += int(ch)
        else:
            if col == f:
                return ch
            col += 1
    return '.'


def labels_for(fen):
    """Class per square, a1 = 0, sq = rank * 8 + file."""
    return np.array([CLASSES.index(piece_at(fen, sq % 8, sq // 8)) for sq in range(64)])


if __name__ == '__main__':
    src, labels, model, out = sys.argv[1:5]
    min_margin = float(sys.argv[5]) if len(sys.argv) > 5 else 5.0
    max_wrong = int(sys.argv[6]) if len(sys.argv) > 6 else 20
    data = np.load(src)
    x, clip, names = data['x'], data['clip'], data['name']
    lab = json.load(open(labels))
    clips = sorted(lab)
    dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
    net = PieceNet().to(dev)
    net.load_state_dict(torch.load(model, map_location=dev, weights_only=True))
    net.eval()
    logp = []
    with torch.no_grad():
        for i in range(0, len(x), 1024):
            b = torch.from_numpy(x[i:i + 1024]).permute(0, 3, 1, 2).float().to(dev)
            logp.append(F.log_softmax(net(b), 1).cpu().numpy())
    logp = np.concatenate(logp)

    frame = np.array([n.split(':')[0] for n in names])
    square = np.array(['abcdefgh'.index(n[-2]) + 8 * (int(n[-1]) - 1) for n in names])
    y = np.zeros(len(x), np.uint8)
    keep = np.zeros(len(x), bool)
    report = {}
    for f in np.unique(frame):
        idx = np.where(frame == f)[0]
        idx = idx[np.argsort(square[idx])]          # a1 .. h8
        c = f.split('-')[0]
        k = clips.index(c)
        p = logp[idx]
        def fit(fen):
            ident = labels_for(fen)
            half = ident[::-1]                       # the board half turned: a1 <-> h8
            a, b = p[np.arange(64), ident].sum(), p[np.arange(64), half].sum()
            return (a, ident) if a >= b else (b, half), abs(a - b)
        (score, lbl), margin = fit(lab[c])
        wrong = int((p.argmax(1) != lbl).sum())
        near = [fit(lab[clips[j]])[0][0] for j in (k - 1, k + 1) if 0 <= j < len(clips) and lab[clips[j]] != lab[c]]
        r = report.setdefault(c, {'frames': 0, 'kept': 0, 'wrong': [], 'beaten': 0})
        r['frames'] += 1
        if near and max(near) > score:
            r['beaten'] += 1
        if margin >= min_margin and wrong <= max_wrong:
            r['kept'] += 1
            r['wrong'].append(wrong)
            y[idx] = lbl
            keep[idx] = True
    for c in clips:
        r = report.get(c)
        if r:
            w = np.array(r['wrong'] or [0])
            print(f"{c} {lab[c]:<44} frames {r['frames']:3d} kept {r['kept']:3d}  "
                  f"wrong mean {w.mean():5.2f} max {w.max():2d}  a neighbour fits better in {r['beaten']}")
    print(f'kept {keep.sum() // 64} frames of {len(np.unique(frame))}')
    np.savez_compressed(out, x=x[keep], y=y[keep], clip=clip[keep], name=names[keep])
