"""A trained classifier on a set of crops: squares wrong, photos with every square right, and the
commonest confusions.

usage: measure.py model set-dir [more set-dirs ...]     (model: a PieceNet .pt or the app's .mlpackage)
"""
import sys
import numpy as np
import torch
from train3d import CLASSES
from orient import log_probabilities
import cropset

if __name__ == '__main__':
    model = sys.argv[1]
    for path in sys.argv[2:]:
        d = cropset.load(path)
        y = d['y'].astype(np.int64)
        pred = log_probabilities(model, d['x'], d['name']).argmax(1)
        frames = np.array([s.split(':')[0] for s in d['name']])
        wrong = pred != y
        errs = np.array([wrong[frames == f].sum() for f in np.unique(frames)])
        err, clean, mean_wrong = wrong.mean(), np.mean(errs == 0), errs.mean()
        conf = {}
        for a, b in zip(y, pred):
            if a != b:
                conf[(CLASSES[a], CLASSES[b])] = conf.get((CLASSES[a], CLASSES[b]), 0) + 1
        top = sorted(conf.items(), key=lambda kv: -kv[1])[:8]
        print(f'{path}: squares wrong {err:.2%}  all right {clean:.1%}  mean wrong {mean_wrong:.2f}  '
              + ', '.join(f'{a}->{b}: {n}' for (a, b), n in top))
