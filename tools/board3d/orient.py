"""Settles which way round the board stands in each frame of clips where it was turned while filmed.

locate.py --turning names the corners so that a1 is a dark corner, which leaves the board possibly
half turned: the real a1 may be at the named h8. An existing classifier reads the crops both ways
round and the frame is labelled the way its reading fits the known position better. Frames where
the two fit about equally are dropped, and so are frames read with many squares wrong either way:
those are nearly all a grid placed a square off (a shifted grid's colours agree with the naming
once it is moved round a corner), not hard views. Also prints, per clip, how well the reading fits the clip's
position and the positions one move either side, to catch a clip given the wrong position.

With --colour, the fit is judged on white piece, black piece or empty alone (each class's
probabilities summed into those three): for a set the classifier has not learnt, whose piece kinds
it misreads but whose colours it mostly gets.

With --per-clip (frames named alike through each clip by track.py), one way round is chosen
per clip, from all its frames' readings summed, and min-margin applies to that sum.

usage: orient.py raw-set labels.json model out-set [min-margin] [max-wrong] [--colour] [--per-clip]
       (crop sets: see cropset.py; model: a PieceNet .pt, or the app's PieceClassifier.mlpackage)
"""
import sys, json
import numpy as np
import torch, torch.nn.functional as F
from train3d import load, CLASSES
import cropset


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


def log_probabilities(model, x, names):
    """Per crop, the log probability of each class."""
    if model.endswith('.mlpackage'):
        # The app's model takes a frame's 64 crops at once, a1, b1, ..., h8, as N x 3 x 96 x 48.
        import coremltools as ct
        ml = ct.models.MLModel(model)
        out = np.zeros((len(x), 13), np.float32)
        frame = np.array([n.split(':')[0] for n in names])
        square = np.array(['abcdefgh'.index(n[-2]) + 8 * (int(n[-1]) - 1) for n in names])
        for f in np.unique(frame):
            idx = np.where(frame == f)[0]
            idx = idx[np.argsort(square[idx])]
            batch = np.asarray(x[idx], np.float32).transpose(0, 3, 1, 2)
            out[idx] = ml.predict({'crops': batch})['probabilities']
        return np.log(np.maximum(out, 1e-9))
    dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
    net = load(model, dev)
    logp = []
    with torch.no_grad():
        for i in range(0, len(x), 1024):
            b = torch.from_numpy(np.asarray(x[i:i + 1024])).permute(0, 3, 1, 2).float().to(dev)
            logp.append(F.log_softmax(net(b), 1).cpu().numpy())
    return np.concatenate(logp)


def labels_for(fen):
    """Class per square, a1 = 0, sq = rank * 8 + file."""
    return np.array([CLASSES.index(piece_at(fen, sq % 8, sq // 8)) for sq in range(64)])


if __name__ == '__main__':
    colour = '--colour' in sys.argv
    per_clip = '--per-clip' in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    src, labels, model, out = args[:4]
    min_margin = float(args[4]) if len(args) > 4 else 5.0
    max_wrong = int(args[5]) if len(args) > 5 else 20
    data = cropset.load(src)
    x, clip, names = data['x'], data['clip'], data['name']
    lab = json.load(open(labels))
    clips = sorted(lab)
    logp = log_probabilities(model, x, names)
    group = np.arange(len(CLASSES))
    if colour:
        group = np.array([0 if c == '.' else 1 if c.isupper() else 2 for c in CLASSES])
        logp = np.stack([np.logaddexp.reduce(logp[:, group == g], axis=1) for g in range(3)], 1)

    frame = np.array([n.split(':')[0] for n in names])
    square = np.array(['abcdefgh'.index(n[-2]) + 8 * (int(n[-1]) - 1) for n in names])
    y = np.zeros(len(x), np.uint8)
    keep = np.zeros(len(x), bool)
    report = {}
    ordered = {}
    for f in np.unique(frame):
        idx = np.where(frame == f)[0]
        ordered[f] = idx[np.argsort(square[idx])]          # a1 .. h8

    def fits(f):
        """Log probability of the clip's position read as named and half turned."""
        p = logp[ordered[f]]
        ident = labels_for(lab[f.split('-')[0]])
        return p[np.arange(64), group[ident]].sum(), p[np.arange(64), group[ident[::-1]]].sum()

    turned = {}
    if per_clip:
        for c in clips:
            fs = [f for f in ordered if f.split('-')[0] == c]
            if fs:
                d = sum(a - b for a, b in map(fits, fs))
                turned[c] = (d < 0, abs(d))
    for f, idx in ordered.items():
        c = f.split('-')[0]
        k = clips.index(c)
        p = logp[idx]
        a, b = fits(f)
        if per_clip:
            half, margin = turned[c]
        else:
            half, margin = b > a, abs(a - b)
        ident = labels_for(lab[c])
        lbl = ident[::-1] if half else ident
        score = b if half else a
        wrong = int((p.argmax(1) != group[lbl]).sum())
        near = []
        for j in (k - 1, k + 1):
            if 0 <= j < len(clips) and lab[clips[j]] != lab[c]:
                other = labels_for(lab[clips[j]])
                near.append(p[np.arange(64), group[other[::-1] if half else other]].sum())
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
    w = cropset.Writer(out, int(keep.sum()))
    for i in np.where(keep)[0]:
        w.add(x[i], y[i], clip[i], names[i])
    w.close()
