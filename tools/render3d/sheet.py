"""A contact sheet of rendered boards with their labels drawn: the playing area's outline (a1 green)
and the square corners. usage: sheet.py render-dir out.jpg [first] [count]"""
import sys, os, json
import numpy as np, cv2
d, out = sys.argv[1], sys.argv[2]
first = int(sys.argv[3]) if len(sys.argv) > 3 else 0
count = int(sys.argv[4]) if len(sys.argv) > 4 else 24
meta = json.load(open(os.path.join(d, 'meta.json')))
names = sorted(meta, key=lambda s: int(s.split('_')[1].split('.')[0]))[first:first + count]
tiles = []
for name in names:
    img = cv2.imread(os.path.join(d, name))
    m = meta[name]
    for x, y in m['lattice']:
        cv2.circle(img, (int(x), int(y)), 2, (0, 255, 255), -1)
    cv2.polylines(img, [np.array(m['corners'], np.int32)], True, (0, 0, 255), 2)
    cv2.circle(img, tuple(int(v) for v in m['corners'][0]), 6, (0, 255, 0), -1)
    cv2.putText(img, f"{name} {m['style']}/{m['table']}", (5, 18), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 0), 1)
    t = np.zeros((360, 360, 3), np.uint8)
    k = 360 / max(img.shape[:2])
    r = cv2.resize(img, None, fx=k, fy=k)
    t[:r.shape[0], :r.shape[1]] = r
    tiles.append(t)
while len(tiles) % 6:
    tiles.append(np.zeros_like(tiles[0]))
cv2.imwrite(out, np.vstack([np.hstack(tiles[i:i + 6]) for i in range(0, len(tiles), 6)]))
