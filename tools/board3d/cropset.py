"""Crop sets on disk, so that no step holds a whole set in memory (the Mac has 8 GB).

A crop set is a directory: x.npy (N x 96 x 48 x 3, RGB, uint8: the crops, memory-mapped when
read), y.npy (classes, CLASSES order), clip.npy (the clip each crop comes from: clips are what the
held-out test is split by) and name.npy ('<frame>:<square>').
"""
import os
import numpy as np

SHAPE = (96, 48, 3)


class Writer:
    """Writes crops one at a time into a set of at most `capacity` crops."""
    def __init__(self, path, capacity):
        os.makedirs(path, exist_ok=True)
        self.path = path
        self.x = np.lib.format.open_memmap(os.path.join(path, 'x.npy'), mode='w+', dtype=np.uint8,
                                           shape=(max(1, capacity),) + SHAPE)
        self.y, self.clip, self.name = [], [], []

    def add(self, crop, y, clip, name):
        self.x[len(self.y)] = crop
        self.y.append(y); self.clip.append(clip); self.name.append(name)

    def close(self):
        self.x.flush()
        del self.x
        np.save(os.path.join(self.path, 'y.npy'), np.array(self.y, np.uint8))
        np.save(os.path.join(self.path, 'clip.npy'), np.array(self.clip, np.int32))
        np.save(os.path.join(self.path, 'name.npy'), np.array(self.name))
        return len(self.y)


def load(path):
    """x (memory-mapped), y, clip, name of a set."""
    y = np.load(os.path.join(path, 'y.npy'))
    x = np.load(os.path.join(path, 'x.npy'), mmap_mode='r')[:len(y)]
    return {'x': x, 'y': y, 'clip': np.load(os.path.join(path, 'clip.npy')), 'name': np.load(os.path.join(path, 'name.npy'))}


class Sets:
    """Several sets as one, rows numbered through them; crops read only when asked for."""
    def __init__(self, paths):
        self.parts = [load(p) for p in paths]
        self.starts = np.cumsum([0] + [len(p['y']) for p in self.parts])
        self.y = np.concatenate([p['y'] for p in self.parts]).astype(np.int64)
        self.clip = np.concatenate([p['clip'] for p in self.parts])
        self.name = np.concatenate([p['name'] for p in self.parts])
        self.source = np.concatenate([np.full(len(p['y']), i) for i, p in enumerate(self.parts)])

    def __len__(self):
        return len(self.y)

    def take(self, rows):
        """The crops of these rows, in this order."""
        rows = np.asarray(rows)
        out = np.empty((len(rows),) + SHAPE, np.uint8)
        part = np.searchsorted(self.starts, rows, side='right') - 1
        for i in np.unique(part):
            at = np.where(part == i)[0]
            local = rows[at] - self.starts[i]
            order = np.argsort(local)              # in file order: memory-mapped reads go forward
            out[at[order]] = self.parts[i]['x'][local[order]]
        return out


class View:
    """Some rows of `Sets`, sliced like an array (x[i:j] reads those crops)."""
    def __init__(self, sets, rows):
        self.sets, self.rows = sets, np.asarray(rows)

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, s):
        return self.sets.take(self.rows[s])
