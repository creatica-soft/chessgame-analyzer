"""Trains a piece classifier on the square crops: empty or one of 12 pieces, from a 96x48 colour crop.
Clips are split, not frames: every fourth clip is held out, so the test is on positions and camera
paths the network never saw. Reports square accuracy and whole boards (frames) read without a mistake.
usage: train3d.py crops.npz model.pt [epochs]
"""
import sys, time
import numpy as np
import torch, torch.nn as nn, torch.nn.functional as F

CLASSES = '.PNBRQKpnbrqk'


class PieceNet(nn.Module):
    def __init__(self):
        super().__init__()
        def block(i, o):
            return nn.Sequential(nn.Conv2d(i, o, 3, padding=1, bias=False), nn.BatchNorm2d(o), nn.ReLU(inplace=True),
                                 nn.Conv2d(o, o, 3, padding=1, bias=False), nn.BatchNorm2d(o), nn.ReLU(inplace=True))
        self.features = nn.Sequential(block(3, 32), nn.MaxPool2d(2), block(32, 64), nn.MaxPool2d(2),
                                      block(64, 128), nn.MaxPool2d(2), block(128, 192))
        self.head = nn.Sequential(nn.Dropout(0.3), nn.Linear(192 * 2, 13))

    def forward(self, x):                      # x: N,3,96,48 in 0..255
        x = x / 127.5 - 1
        f = self.features(x)                   # N,192,12,6
        # Average and max over the crop, but the bottom half counts twice: that is where the
        # square's own piece stands.
        avg = f.mean((2, 3)); mx = f.amax((2, 3))
        return self.head(torch.cat([avg, mx], 1))


def augment(x):
    n = x.shape[0]
    # Brightness, contrast and colour balance per crop; a small shift; mirror half of them.
    gain = torch.empty(n, 3, 1, 1, device=x.device).uniform_(0.8, 1.2) * torch.empty(n, 1, 1, 1, device=x.device).uniform_(0.75, 1.25)
    bias = torch.empty(n, 1, 1, 1, device=x.device).uniform_(-25, 25)
    mean = x.mean((1, 2, 3), keepdim=True)
    x = ((x - mean) * gain + mean + bias).clamp(0, 255)
    dx, dy = np.random.randint(-3, 4), np.random.randint(-4, 5)
    x = torch.roll(x, (dy, dx), (2, 3))
    flip = torch.rand(n, device=x.device) < 0.5
    x[flip] = x[flip].flip(3)
    return x


def evaluate(net, x, y, names, dev):
    net.eval()
    preds, probs = [], []
    with torch.no_grad():
        for i in range(0, len(x), 1024):
            p = F.softmax(net(torch.from_numpy(x[i:i + 1024]).permute(0, 3, 1, 2).float().to(dev)), 1).cpu().numpy()
            probs.append(p)
    p = np.concatenate(probs)
    pred = p.argmax(1)
    frames = np.array([s.split(':')[0] for s in names])
    wrong = pred != y
    per_frame = {f: wrong[frames == f].sum() for f in np.unique(frames)}
    errs = np.array(list(per_frame.values()))
    return wrong.mean(), np.mean(errs == 0), errs.mean(), pred, p


if __name__ == '__main__':
    data = np.load(sys.argv[1])
    out = sys.argv[2]
    epochs = int(sys.argv[3]) if len(sys.argv) > 3 else 15
    x, y, clip, names = data['x'], data['y'].astype(np.int64), data['clip'], data['name']
    ids = np.unique(clip)
    test_ids = ids[3::4]
    test = np.isin(clip, test_ids)
    xt, yt, xv, yv, nv = x[~test], y[~test], x[test], y[test], names[test]
    print(f'train {len(xt)} crops from {len(ids) - len(test_ids)} clips, test {len(xv)} from {len(test_ids)} clips')
    dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
    net = PieceNet().to(dev)
    counts = np.bincount(yt, minlength=13).astype(np.float32)
    weights = torch.tensor((counts.max() / np.maximum(counts, 1)) ** 0.5, device=dev)
    opt = torch.optim.AdamW(net.parameters(), lr=2e-3, weight_decay=1e-4)
    steps = epochs * (len(xt) // 128)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=2e-3, total_steps=steps)
    xt_t = torch.from_numpy(xt).permute(0, 3, 1, 2).contiguous()
    yt_t = torch.from_numpy(yt)
    for epoch in range(epochs):
        net.train()
        t0 = time.time()
        perm = torch.randperm(len(xt))
        total = 0
        for i in range(0, len(perm) - 127, 128):
            b = perm[i:i + 128]
            xb = augment(xt_t[b].float().to(dev)); yb = yt_t[b].to(dev)
            loss = F.cross_entropy(net(xb), yb, weight=weights, label_smoothing=0.05)
            opt.zero_grad(); loss.backward(); opt.step(); sched.step()
            total += loss.item()
        err, clean, mean_wrong, _, _ = evaluate(net, xv, yv, nv, dev)
        print(f'epoch {epoch + 1}: loss {total / (len(perm) // 128):.3f}  test squares wrong {err:.2%}  '
              f'boards all right {clean:.1%}  mean wrong squares {mean_wrong:.2f}  ({time.time() - t0:.0f}s)')
    torch.save(net.state_dict(), out)
    err, clean, mean_wrong, pred, p = evaluate(net, xv, yv, nv, dev)
    # Confusions.
    conf = np.zeros((13, 13), int)
    for a, b in zip(yv, pred): conf[a, b] += 1
    print('confusions (true -> read: count), most frequent:')
    pairs = sorted(((conf[a, b], CLASSES[a], CLASSES[b]) for a in range(13) for b in range(13) if a != b and conf[a, b]), reverse=True)[:12]
    print('  ' + ', '.join(f'{t}->{r}: {c}' for c, t, r in pairs))
    np.savez_compressed(out.replace('.pt', '-test.npz'), p=p, y=yv, name=nv)
