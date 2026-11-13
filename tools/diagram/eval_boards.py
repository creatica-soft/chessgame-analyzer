"""Whole boards in held-out styles: how many are read without a mistake, and how many squares are wrong."""
import sys, random
import numpy as np, torch
import os; sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen
from train import SquareNet

net = SquareNet(); net.load_state_dict(torch.load(sys.argv[1], map_location='cpu')); net.eval()
sets = sys.argv[2].split(',')
n = int(sys.argv[3]) if len(sys.argv) > 3 else 300
gen.ROOT = sys.argv[4] if len(sys.argv) > 4 else 'diagram/pieces'
gen.load_pieces()
errors, low = [], []
for seed in range(n):
    x, y = gen.make((20_000_000 + seed, sets, 0.12))
    with torch.no_grad():
        p = torch.softmax(net(torch.from_numpy(x).float().unsqueeze(1)), 1).numpy()
    pred = p.argmax(1)
    wrong = pred != y
    errors.append(int(wrong.sum()))
    # Would the doubtful marks (confidence < 0.8) have caught the mistakes?
    low.append(int((wrong & (p.max(1) >= 0.8)).sum()))
errors = np.array(errors); low = np.array(low)
print(f'{n} boards in {sets}: all right {np.mean(errors == 0):.1%}, mean wrong squares {errors.mean():.2f}, '
      f'mistakes not marked doubtful {low.mean():.2f} per board, boards with an unmarked mistake {np.mean(low > 0):.1%}')
