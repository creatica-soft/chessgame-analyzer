"""render.py's meta.json as tools/board3d's inputs: located.json (the corners, as locate.py writes
them) and labels.json (each render its own clip, REN_<n>, with its position), for crops.py.

usage: meta2board3d.py render-dir located.json labels.json
"""
import sys, os, json

if __name__ == '__main__':
    src, located_out, labels_out = sys.argv[1:4]
    meta = json.load(open(os.path.join(src, 'meta.json')))
    located, labels = {}, {}
    for name, m in meta.items():
        located[name] = {'found': True, 'corners': m['corners'], 'colours': True}
        labels[name.split('-')[0]] = m['fen']
    json.dump(located, open(located_out, 'w'))
    json.dump(labels, open(labels_out, 'w'))
    print(len(located), 'renders')
