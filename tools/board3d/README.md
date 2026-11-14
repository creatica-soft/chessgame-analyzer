# Real board piece classifier

`App/Resources/PieceClassifier.mlpackage` names the piece standing on one square of a photo of a real
board, from a tall crop of that square. `App/Engine/BoardFinder.swift` and `BoardReader.swift` are the
app's side; `grid.py` here is the board finder they were ported from, where it was developed.

The training data is video of one board, filmed while a game was played through: a short clip
after each move, so every frame's position is known from the game's PGN. The clips themselves are
not in git (`tools/training/` is ignored).

1. Frames. `frames.swift` (AVFoundation; no ffmpeg needed) prints a clip's length and saves frames:

       swiftc -O -o frames frames.swift
       for f in ../training/*.MOV; do ./frames $f frames/q4 0.25 1280; done

   The labels: replay the PGN with python-chess. The first clips show the starting position;
   then each clip is the position after the next half-move (see the conversation of 2026-11-14:
   clips 9030-9032 are the start, 9033-9098 the 64 half-moves of `tools/game.pgn`).

2. The board in every frame (`locate.py`, uses `grid.py`): the 9 x 9 grid of square corners from
   the X-corners where four squares meet, the 8 x 8 block that is the board, and its corners named
   a1, h1, h8, a8 (camera on White's side: rank 1 nearest it). Frames where the squares' colours
   disagree with the naming (a1 must be dark) are left out.

       python3 locate.py frames/q4 located.json

   `eval_chessred.py` measures the finder against hand-marked corners of another board (ChessReD2K,
   CC BY-NC-SA; used for measuring only).

3. Crops (`crops.py`): each square as a 48 x 96 RGB crop, as wide as the square and reaching 2.4
   widths of its front edge up the picture, where its piece shows. The constants must match
   `BoardReader` (`wide`, `tall`, `below`, crop size).

       python3 crops.py frames/q4 located.json labels.json crops.npz

   Clips where the board was turned round while filmed (the second set, 9101-9184: a tripod, the
   board turned a full circle in each clip; 9101 the start, then one clip per half-move in number
   order, 9111-9128 and 9142 not taken) go through `locate.py --turning`, which names the
   corners from whichever dark corner suits, and then `orient.py`, which settles the half turn left
   open from the known position with an existing classifier and drops frames read with many squares
   wrong (nearly all grids placed a square off):

       python3 locate.py frames2/f1 located2.json --turning
       python3 crops.py frames2/f1 located2.json labels2.json crops2-raw.npz
       python3 orient.py crops2-raw.npz labels2.json piecenet2.pt crops2.npz

   The finder checks X-corners by four quadrants first and, failing that, by a ring round them
   (`grid.find_board(ring=True)`): the ring finds boards turned near 45 degrees, which the quadrants
   miss, but takes points on the printed border more often.

4. Train (PyTorch, MPS) with every fourth clip held out, and export (several crop files may be
   given, comma separated; 8 GB of memory holds the first set at two frames a second and the
   second at one):

       python3 train3d.py crops.npz,crops2.npz piecenet.pt 12
       python3 export3d.py piecenet.pt ../../App/Resources/PieceClassifier.mlpackage

   The shipped model (piecenet3) was trained 12 epochs on both sets. On the held-out clips' crops:
   97.5% of the turned-board frames with every square right (26% for piecenet2, trained on the
   first set only), and 95.4% of the first set's (96.6% for piecenet2).

   End to end in the app (finder, reader and classifier on held-out frames at one a second, 561 of
   them): 519 read with every square right, 23 with no board found (the corner editor opens), and
   15 with more than one square wrong. A grid whose cells do not alternate light and dark
   (`BoardFinder.checkerScore` under 0.65) is refused rather than read. Photos taken close and
   steeply from the side of the board are still read poorly: not in either set.
