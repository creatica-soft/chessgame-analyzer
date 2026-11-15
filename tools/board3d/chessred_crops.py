"""Crops of ChessReD2K's photos (a plastic Staunton set on a roll-up board, CC BY-NC-SA: for measuring
only, never for training), for measuring the piece classifier on a set it was not trained on.

The board is cut at the hand-marked corners, so this measures the classifier alone, not the board
finder. The corners are marked as seen (top left, ...); which of them is a1 is settled by the
annotated pieces: the naming that puts each piece's foot (its box's bottom middle) nearest its
square wins.

usage: chessred_crops.py chessred-dir out-set [split]     (split: test, val or train of chessred2k)
"""
import sys, os, json, zipfile
import numpy as np
import cv2
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import locate
import cropset
from crops import crop_square, CLASSES

NAMES = {'white-pawn': 'P', 'white-rook': 'R', 'white-knight': 'N', 'white-bishop': 'B', 'white-queen': 'Q',
         'white-king': 'K', 'black-pawn': 'p', 'black-rook': 'r', 'black-knight': 'n', 'black-bishop': 'b',
         'black-queen': 'q', 'black-king': 'k'}
SOURCE = 1280

if __name__ == '__main__':
    root, out = sys.argv[1], sys.argv[2]
    split = sys.argv[3] if len(sys.argv) > 3 else 'test'
    ann = json.load(open(os.path.join(root, 'annotations.json')))
    images = {im['id']: im for im in ann['images']}
    category = {c['id']: c['name'] for c in ann['categories']}
    wanted = set(ann['splits']['chessred2k'][split]['image_ids'])
    pieces = {}
    for p in ann['annotations']['pieces']:
        if p['image_id'] in wanted:
            pieces.setdefault(p['image_id'], []).append(p)
    z = zipfile.ZipFile(os.path.join(root, 'chessred2k.zip'))
    names_in_zip = set(z.namelist())
    writer = cropset.Writer(out, 64 * len(wanted))
    misfit = []
    for c in ann['annotations']['corners']:
        i = c['image_id']
        im = images[i]
        if i not in wanted or im['path'] not in names_in_zip:
            continue
        seen = [c['corners'][k] for k in ('top_left', 'top_right', 'bottom_right', 'bottom_left')]
        # a1, h1, h8, a8 run the other way round from top left, top right, ... : one of four turns.
        candidates = [np.array([seen[(k - j) % 4] for j in range(4)], np.float32) for k in range(4)]
        board = {}
        feet = []
        for p in pieces.get(i, []):
            sq = p['chessboard_position']
            f, r = 'abcdefgh'.index(sq[0]), int(sq[1]) - 1
            board[(f, r)] = NAMES[category[p['category_id']]]
            x, y, w, h = p['bbox']
            feet.append(((f + 0.5, r + 0.5), (x + w / 2, y + h * 0.92)))
        if not feet:
            continue
        def fit(corners):
            H = locate.board_homography(corners)
            pts = cv2.perspectiveTransform(np.array([[s] for s, _ in feet], np.float32), H).reshape(-1, 2)
            return np.mean(np.linalg.norm(pts - np.array([f for _, f in feet]), axis=1))
        errors = [fit(cand) for cand in candidates]
        best = int(np.argmin(errors))
        side = np.linalg.norm(candidates[best][1] - candidates[best][0]) / 8
        if errors[best] > side * 0.5:
            misfit.append(im['file_name'])
            continue
        img = cv2.imdecode(np.frombuffer(z.read(im['path']), np.uint8), cv2.IMREAD_COLOR)
        k = SOURCE / max(img.shape[:2])
        img = cv2.resize(img, None, fx=k, fy=k, interpolation=cv2.INTER_AREA)
        Hb = locate.board_homography(candidates[best] * k)
        for f in range(8):
            for r in range(8):
                writer.add(cv2.cvtColor(crop_square(img, Hb, f, r), cv2.COLOR_BGR2RGB), CLASSES.index(board.get((f, r), '.')),
                      im['game_id'], f'{im["file_name"]}:{"abcdefgh"[f]}{r + 1}')
    n = writer.close()
    print(f'{n // 64} photos ({len(misfit)} left out: pieces fit no naming of the corners)',
          np.bincount(cropset.load(out)['y'], minlength=13))
