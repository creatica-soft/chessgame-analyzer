"""Follows the board through each clip of a turning board, so that every frame of a clip names its
corners the same way round.

locate.py --turning names a1 at a dark corner, which leaves each frame possibly half turned, and
orient.py settles that per frame by reading the pieces: for a set no classifier knows yet, the
readings are too poor. But the board turns little from one frame to the next (a second apart), so
each frame's naming can follow the one before: of the two namings a half turn apart, the one whose
corners lie nearer the last frame's. A clip is then a single unknown half turn, which
`orient.py --per-clip` settles from all its frames' readings together.

usage: track.py located.json tracked.json
"""
import sys, json
import numpy as np

if __name__ == '__main__':
    loc = json.load(open(sys.argv[1]))
    clips = {}
    for f in sorted(loc):
        if loc[f].get('colours'):
            clips.setdefault(f.split('-')[0], []).append(f)
    flipped = 0
    for frames in clips.values():
        last = None
        for f in frames:
            c = np.array(loc[f]['corners'])
            if last is not None:
                half = np.roll(c, 2, axis=0)
                if np.linalg.norm(half - last, axis=1).mean() < np.linalg.norm(c - last, axis=1).mean():
                    c = half
                    flipped += 1
                    loc[f]['corners'] = c.tolist()
            last = c
    json.dump(loc, open(sys.argv[2], 'w'), indent=0)
    print(f'{sum(map(len, clips.values()))} frames in {len(clips)} clips, {flipped} turned to follow the one before')
