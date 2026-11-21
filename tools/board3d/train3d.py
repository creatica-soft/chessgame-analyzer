"""Trains a piece classifier on the square crops: empty or one of 12 pieces, from a 96x48 crop.
The network takes RGB (the app's interface) but reads lightness only: Staunton sets share their
shapes, and differ in colour and material (silver, boxwood, mahogany, plastic), which must not
count. Pieces are stretched taller and shorter in training, as sets differ in scale too.
Clips are split, not frames: every fourth clip is held out, so the test is on positions and camera
paths the network never saw. Reports square accuracy and whole boards (frames) read without a mistake.
usage: [INIT=start.pt LR=1e-3] train3d.py set-dir[,more-set-dirs...] model.pt [epochs]       (crop sets: see cropset.py)
"""
import sys, time
import numpy as np
import torch, torch.nn as nn, torch.nn.functional as F
import cropset

CLASSES = '.PNBRQKpnbrqk'


class PieceNet(nn.Module):
    def __init__(self, grey=True):
        super().__init__()
        self.grey = grey                       # False: the colour models up to piecenet5
        def block(i, o):
            return nn.Sequential(nn.Conv2d(i, o, 3, padding=1, bias=False), nn.BatchNorm2d(o), nn.ReLU(inplace=True),
                                 nn.Conv2d(o, o, 3, padding=1, bias=False), nn.BatchNorm2d(o), nn.ReLU(inplace=True))
        self.features = nn.Sequential(block(1 if grey else 3, 32), nn.MaxPool2d(2), block(32, 64), nn.MaxPool2d(2),
                                      block(64, 128), nn.MaxPool2d(2), block(128, 192))
        self.head = nn.Sequential(nn.Dropout(0.3), nn.Linear(192 * 2, 13))

    def forward(self, x):                      # x: N,3,96,48 RGB in 0..255
        if self.grey:
            x = 0.299 * x[:, 0:1] + 0.587 * x[:, 1:2] + 0.114 * x[:, 2:3]
        x = x / 127.5 - 1
        f = self.features(x)                   # N,192,12,6
        # Average and max over the crop, but the bottom half counts twice: that is where the
        # square's own piece stands.
        avg = f.mean((2, 3)); mx = f.amax((2, 3))
        return self.head(torch.cat([avg, mx], 1))


def load(path, dev='cpu'):
    """A saved PieceNet, greyscale or colour as it was trained."""
    state = torch.load(path, map_location=dev, weights_only=True)
    net = PieceNet(grey=state['features.0.0.weight'].shape[1] == 1).to(dev)
    net.load_state_dict(state)
    return net.eval()


def augment(x):
    n = x.shape[0]
    dev = x.device
    # Brightness, contrast and gamma per crop (colour does not count: see PieceNet).
    gain = torch.empty(n, 1, 1, 1, device=dev).uniform_(0.7, 1.3)
    bias = torch.empty(n, 1, 1, 1, device=dev).uniform_(-30, 30)
    gamma = torch.exp(torch.empty(n, 1, 1, 1, device=dev).uniform_(-0.35, 0.35))
    x = 255 * (x / 255) ** gamma
    mean = x.mean((1, 2, 3), keepdim=True)
    x = ((x - mean) * gain + mean + bias).clamp(0, 255)
    # Scale: taller or shorter about the square's front edge (the crop's bottom), a little wider or
    # narrower about the middle, with a small shift.
    sy = torch.exp(torch.empty(n, device=dev).uniform_(np.log(0.8), np.log(1.25)))
    sx = sy * torch.exp(torch.empty(n, device=dev).uniform_(-0.1, 0.1))
    theta = torch.zeros(n, 2, 3, device=dev)
    theta[:, 0, 0] = 1 / sx
    theta[:, 0, 2] = torch.empty(n, device=dev).uniform_(-0.12, 0.12)
    theta[:, 1, 1] = 1 / sy
    theta[:, 1, 2] = 1 - 1 / sy + torch.empty(n, device=dev).uniform_(-0.08, 0.08)
    grid = F.affine_grid(theta, list(x.shape), align_corners=False)
    # Past the crop's edge, its edge pixels (MPS has no 'border' padding): clamped to their centres.
    h, w = x.shape[2], x.shape[3]
    grid = torch.stack([grid[..., 0].clamp(-1 + 1 / w, 1 - 1 / w), grid[..., 1].clamp(-1 + 1 / h, 1 - 1 / h)], -1)
    x = F.grid_sample(x, grid, mode='bilinear', padding_mode='zeros', align_corners=False)
    flip = torch.rand(n, device=dev) < 0.5
    x[flip] = x[flip].flip(3)
    return x


def evaluate(net, x, y, names, dev):
    net.eval()
    preds, probs = [], []
    with torch.no_grad():
        for i in range(0, len(x), 1024):
            p = F.softmax(net(torch.from_numpy(np.array(x[i:i + 1024])).permute(0, 3, 1, 2).float().to(dev)), 1).cpu().numpy()
            probs.append(p)
    p = np.concatenate(probs)
    pred = p.argmax(1)
    frames = np.array([s.split(':')[0] for s in names])
    wrong = pred != y
    per_frame = {f: wrong[frames == f].sum() for f in np.unique(frames)}
    errs = np.array(list(per_frame.values()))
    return wrong.mean(), np.mean(errs == 0), errs.mean(), pred, p


if __name__ == '__main__':
    out = sys.argv[2]
    epochs = int(sys.argv[3]) if len(sys.argv) > 3 else 15
    # The sets stay on disk, memory-mapped: each batch reads its crops (the Mac has 8 GB).
    paths = sys.argv[1].split(',')
    data = cropset.Sets(paths)
    y, clip, names, source = data.y, data.clip, data.name, data.source
    ids = np.unique(clip)
    test_ids = ids[3::4]
    test = np.isin(clip, test_ids)
    train_idx = np.where(~test)[0]
    test_idx = np.where(test)[0]
    xv, yv, nv, sv = cropset.View(data, test_idx), y[test_idx], names[test_idx], source[test_idx]
    yt = y[train_idx]
    print(f'train {len(train_idx)} crops from {len(ids) - len(test_ids)} clips, test {len(xv)} from {len(test_ids)} clips', flush=True)
    dev = 'mps' if torch.backends.mps.is_available() else 'cpu'
    # INIT=model.pt starts from a trained model (fine-tuning on more sets), LR its learning rate.
    import os
    net = load(os.environ['INIT'], dev).train() if os.environ.get('INIT') else PieceNet().to(dev)
    lr = float(os.environ.get('LR', 2e-3))
    counts = np.bincount(yt, minlength=13).astype(np.float32)
    weights = torch.tensor((counts.max() / np.maximum(counts, 1)) ** 0.5, device=dev)
    opt = torch.optim.AdamW(net.parameters(), lr=lr, weight_decay=1e-4)
    steps = epochs * (len(train_idx) // 128)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=lr, total_steps=steps)
    for epoch in range(epochs):
        net.train()
        t0 = time.time()
        perm = torch.randperm(len(train_idx))
        total = 0
        for i in range(0, len(perm) - 127, 128):
            b = perm[i:i + 128]
            rows = train_idx[b.numpy()]
            xb = augment(torch.from_numpy(data.take(rows)).permute(0, 3, 1, 2).contiguous().float().to(dev))
            yb = torch.from_numpy(y[rows]).to(dev)
            loss = F.cross_entropy(net(xb), yb, weight=weights, label_smoothing=0.05)
            opt.zero_grad(); loss.backward(); opt.step(); sched.step()
            total += loss.item()
        err, clean, mean_wrong, _, _ = evaluate(net, xv, yv, nv, dev)
        print(f'epoch {epoch + 1}: loss {total / (len(perm) // 128):.3f}  test squares wrong {err:.2%}  '
              f'boards all right {clean:.1%}  mean wrong squares {mean_wrong:.2f}  ({time.time() - t0:.0f}s)', flush=True)
    torch.save(net.state_dict(), out)
    err, clean, mean_wrong, pred, p = evaluate(net, xv, yv, nv, dev)
    if len(set(sv)) > 1:
        for i, path in enumerate(sys.argv[1].split(',')):
            e, c, m, _, _ = evaluate(net, cropset.View(data, test_idx[sv == i]), yv[sv == i], nv[sv == i], dev)
            print(f'{path}: test squares wrong {e:.2%}  boards all right {c:.1%}  mean wrong squares {m:.2f}')
    # Confusions.
    conf = np.zeros((13, 13), int)
    for a, b in zip(yv, pred): conf[a, b] += 1
    print('confusions (true -> read: count), most frequent:')
    pairs = sorted(((conf[a, b], CLASSES[a], CLASSES[b]) for a in range(13) for b in range(13) if a != b and conf[a, b]), reverse=True)[:12]
    print('  ' + ', '.join(f'{t}->{r}: {c}' for c, t, r in pairs))
    np.savez_compressed(out.replace('.pt', '-test.npz'), p=p, y=yv, name=nv)
