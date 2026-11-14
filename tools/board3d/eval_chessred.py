"""The board finder against ChessReD2K's hand-marked corners: how often it finds the board, and how
far its corners are from the marked ones, in squares (a square being the board's side / 8)."""
import sys, os, json, zipfile, random
import numpy as np
import cv2
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import grid

root = sys.argv[1]
n = int(sys.argv[2]) if len(sys.argv) > 2 else 100
out = sys.argv[3] if len(sys.argv) > 3 else None
ann = json.load(open(os.path.join(root, 'annotations.json')))
images = {im['id']: im for im in ann['images']}
corners = ann['annotations']['corners']
random.Random(1).shuffle(corners)
z = zipfile.ZipFile(os.path.join(root, 'chessred2k.zip'))
names = set(z.namelist())
if out:
    os.makedirs(out, exist_ok=True)

errors, missed = [], 0
for c in corners[:n]:
    im = images[c['image_id']]
    if im['path'] not in names:
        continue
    data = np.frombuffer(z.read(im['path']), np.uint8)
    img = cv2.imdecode(data, cv2.IMREAD_COLOR)
    truth = np.array([c['corners'][k] for k in ('top_left', 'top_right', 'bottom_right', 'bottom_left')], np.float32)
    side = np.mean([np.linalg.norm(truth[i] - truth[(i + 1) % 4]) for i in range(4)]) / 8
    quad, pts, S = grid.find_board(img)
    if quad is None:
        missed += 1
        err = None
    else:
        q = np.asarray(quad, np.float32)
        # The finder does not know which corner is which: the best of the 4 turns, both directions.
        best = 1e9
        for order in (q, q[::-1]):
            for k in range(4):
                best = min(best, np.linalg.norm(np.roll(order, k, axis=0) - truth, axis=1).max())
        err = best / side
        errors.append(err)
    print(im['file_name'], 'none' if err is None else f'{err:.2f} squares')
    if out:
        vis = grid.draw(img, quad, pts, S)
        for x, y in truth:
            cv2.circle(vis, (int(x), int(y)), 18, (255, 0, 255), 5)
        cv2.imwrite(os.path.join(out, im['file_name']), cv2.resize(vis, (960, 960)))

e = np.array(errors)
total = len(e) + missed
print(f'{total} photos: found {len(e)} ({len(e) / total:.0%}); worst corner within 0.25 square in {np.mean(e < 0.25) * len(e) / total:.0%}, '
      f'within 0.5 in {np.mean(e < 0.5) * len(e) / total:.0%}, a square or more off in {np.mean(e >= 1) * len(e) / total:.0%}')
