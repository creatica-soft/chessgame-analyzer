"""Trains the square classifier on gen.py's squares and reports accuracy on held-out piece styles."""
import sys, time
import numpy as np
import torch, torch.nn as nn, torch.nn.functional as F

class SquareNet(nn.Module):
    """32x32 grey square (0..255) -> 13 logits. Normalises each square itself."""
    def __init__(self):
        super().__init__()
        def block(i, o):
            return nn.Sequential(nn.Conv2d(i, o, 3, padding=1, bias=False), nn.BatchNorm2d(o), nn.ReLU())
        self.features = nn.Sequential(
            block(1, 32), block(32, 32), nn.MaxPool2d(2),      # 16
            block(32, 64), block(64, 64), nn.MaxPool2d(2),     # 8
            block(64, 128), block(128, 128), nn.MaxPool2d(2),  # 4
        )
        self.head = nn.Sequential(nn.Flatten(), nn.Dropout(0.3), nn.Linear(128 * 16, 13))

    def forward(self, x):
        mean = x.mean(dim=(1, 2, 3), keepdim=True)
        std = x.std(dim=(1, 2, 3), keepdim=True) + 8.0
        return self.head(self.features((x - mean) / std))

def augment(x):
    # x: (N,1,32,32) float 0..255. Shift by up to 2 px, change contrast and brightness.
    n = x.shape[0]
    dx, dy = np.random.randint(-2, 3, 2)
    x = torch.roll(x, shifts=(int(dy), int(dx)), dims=(2, 3))
    gain = torch.empty(n, 1, 1, 1, device=x.device).uniform_(0.6, 1.3)
    bias = torch.empty(n, 1, 1, 1, device=x.device).uniform_(-40, 40)
    return (x * gain + bias).clamp(0, 255)

def evaluate(model, x, y, device, classes):
    model.eval()
    preds = []
    with torch.no_grad():
        for i in range(0, len(x), 4096):
            xb = torch.from_numpy(x[i:i + 4096]).float().unsqueeze(1).to(device)
            preds.append(model(xb).argmax(1).cpu().numpy())
    p = np.concatenate(preds)
    acc = (p == y).mean()
    per = {classes[c]: float((p[y == c] == c).mean()) for c in range(13)}
    conf = np.zeros((13, 13), int)
    np.add.at(conf, (y, p), 1)
    model.train()
    return acc, per, conf

if __name__ == '__main__':
    data = np.load(sys.argv[1])
    out = sys.argv[2]
    epochs = int(sys.argv[3]) if len(sys.argv) > 3 and not sys.argv[3].startswith('--') else 8
    classes = list(data['classes'])
    xt, yt, xh, yh = data['x_train'], data['y_train'], data['x_held'], data['y_held']
    # Hold back 2% of the training styles' squares as a validation set.
    n_val = len(xt) // 50
    xv, yv, xt, yt = xt[:n_val], yt[:n_val], xt[n_val:], yt[n_val:]
    device = 'mps' if torch.backends.mps.is_available() else 'cpu'
    model = SquareNet().to(device)
    # Fine-tuning: start from earlier weights, at a lower rate.
    init = next((a.split('=', 1)[1] for a in sys.argv if a.startswith('--init=')), None)
    max_lr = 3e-3
    if init:
        model.load_state_dict(torch.load(init, map_location=device))
        max_lr = 1e-3
    print('parameters', sum(p.numel() for p in model.parameters()), 'device', device)
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    steps = epochs * (len(xt) // 512)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=max_lr, total_steps=steps)
    # Empty squares are 60% of the data; weigh the pieces up a little.
    weights = torch.tensor([0.5] + [1.0] * 12, device=device)
    xt_t = torch.from_numpy(xt); yt_t = torch.from_numpy(yt.astype(np.int64))
    for epoch in range(epochs):
        t0 = time.time()
        perm = torch.randperm(len(xt))
        total = 0.0
        for i in range(0, len(xt) - 511, 512):
            idx = perm[i:i + 512]
            xb = xt_t[idx].float().unsqueeze(1).to(device)
            yb = yt_t[idx].to(device)
            loss = F.cross_entropy(model(augment(xb)), yb, weight=weights, label_smoothing=0.05)
            opt.zero_grad(); loss.backward(); opt.step(); sched.step()
            total += loss.item()
        va, _, _ = evaluate(model, xv, yv, device, classes)
        ha, per, _ = evaluate(model, xh, yh, device, classes) if len(xh) else (float('nan'), {}, None)
        print(f'epoch {epoch + 1}: loss {total / (len(xt) // 512):.4f}  val {va:.4f}  held-out styles {ha:.4f}  ({time.time() - t0:.0f}s)', flush=True)
    torch.save(model.state_dict(), out)
    if not len(xh):
        sys.exit(0)
    ha, per, conf = evaluate(model, xh, yh, device, classes)
    print('held-out per class:', {k: round(v, 3) for k, v in per.items()})
    print('held-out confusions (true -> predicted, count):')
    for t in range(13):
        for p in range(13):
            if t != p and conf[t, p] >= 5:
                print(f'  {classes[t]} -> {classes[p]}: {conf[t, p]}')
    torch.save(model.state_dict(), out)
