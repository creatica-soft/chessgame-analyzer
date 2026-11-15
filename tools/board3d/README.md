# Real board piece classifier

`App/Resources/PieceClassifier.mlpackage` names the piece standing on one square of a photo of a real
board, from a tall crop of that square. `App/Engine/BoardFinder.swift` and `BoardReader.swift` are the
app's side; `grid.py` here is the board finder they were ported from, where it was developed.

The training data is video of real boards, filmed while a game was played through (a short clip
after each move, so every frame's position is known from the game's PGN), and renders of a Staunton
set (`tools/render3d`). The clips are not in git (`tools/training/` and `tools/training3/` are
ignored).

The classifier reads lightness only (the conversion is inside the network; the app passes RGB), and
is trained with pieces stretched taller and shorter: Staunton sets share their shapes and differ in
scale, colour and material, and a colour model learns one set's colours (piecenet4 read a third of
the white pawns of another set as black).

**Where things go.** All working data (frames, crops, models, renders, downloaded datasets, the
OpenCV venv) lives in `tools/work/`, which git ignores. Never in `/tmp`: a restart wipes it. The
commands below run from `tools/work/`, with OpenCV in `./venv` (`python3 -m venv venv;
venv/bin/pip install opencv-python-headless numpy`) and PyTorch, coremltools and python-chess in the
system Python.

**Memory.** The Mac has 8 GB. A crop set is a folder of `.npy` files (`cropset.py`), written crop by
crop and memory-mapped when read, so no step holds a whole set in memory; training reads each
batch's crops from disk. Run one heavy job at a time.

1. Frames. `frames.swift` (AVFoundation; no ffmpeg needed) prints a clip's length and saves frames:

       swiftc -O -o bin/frames ../board3d/frames.swift
       for f in ../training/IMG_90*.MOV; do bin/frames $f frames1 0.5 1280; done
       for f in ../training/IMG_91*.MOV; do bin/frames $f frames2 1 1280; done

   The labels, replaying `tools/game.pgn` with python-chess: the first set, 9030-9098 (filmed from
   White's side), is three clips of the start (9030 from White's side, 9031 from the side, 9032 from
   Black's) and then one clip per half-move in number order (9034 and 9061 not taken). The second,
   9101-9184 (a tripod, the board turned a full circle in each clip), is 9101 the start and then one
   clip per half-move (9111-9128 and 9142 not taken). Written as `labels1.json`, `labels2.json`:
   clip name to the board part of the FEN.

2. The board in every frame (`locate.py`, uses `grid.py`): the 9 x 9 grid of square corners from
   the X-corners where four squares meet, the 8 x 8 block that is the board, and its corners named
   a1, h1, h8, a8 (camera on White's side: rank 1 nearest it). Frames where the squares' colours
   disagree with the naming (a1 must be dark) are left out. The X-corners are checked by four
   quadrants first and, failing that, by a ring round them (`grid.find_board(ring=True)`): the ring
   finds boards turned near 45 degrees, which the quadrants miss, but takes points on the printed
   border more often.

       venv/bin/python ../board3d/locate.py frames1 located1.json
       venv/bin/python ../board3d/locate.py frames2 located2.json --turning

   With `--turning` (the board turned while filmed) the corners are named from whichever dark
   corner suits, which leaves a half turn open; `orient.py` settles it below.

3. Crops (`crops.py`): each square as a 48 x 96 RGB crop, as wide as the square and reaching 2.4
   widths of its front edge up the picture, where its piece shows. The constants must match
   `BoardReader` (`wide`, `tall`, `below`, crop size).

       venv/bin/python ../board3d/crops.py frames1 located1.json labels1.json set1
       venv/bin/python ../board3d/crops.py frames2 located2.json labels2.json set2-raw
       python3 ../board3d/orient.py set2-raw labels2.json ../../App/Resources/PieceClassifier.mlpackage set2

   `orient.py` reads each turned frame both ways round with an existing classifier (a PieceNet `.pt`
   or the app's `.mlpackage`), keeps the way that fits the known position, and drops frames read
   with many squares wrong either way (nearly all grids placed a square off).

   The third set, 9187-9252 (a wooden Staunton set on a folding board, the board turned while
   filmed; `labels3.json` from the lichess game in `tools/training3`): 9187 the start, then one
   clip per full move, 9188-9217 moves 1-30 and 9220-9229 moves 31-40; then a portrait clip and
   two stills (DNG, converted with `sips -s format jpeg -Z 1280`) after Black's moves 40, 30, 25,
   20, 15, 10 and 5. No classifier read this set well enough to settle each frame's half turn, so
   `track.py` names the corners alike through each clip (the board turns little in a second), and
   `orient.py --colour --per-clip` settles one half turn per clip from all its frames' readings
   (white, black or empty only). A first model trained on that (piecenet6a) then orients and
   filters frame by frame, as for the second set:

       venv/bin/python ../board3d/locate.py frames3 located3.json --turning
       python3 ../board3d/track.py located3.json tracked3.json
       venv/bin/python ../board3d/crops.py frames3 tracked3.json labels3.json set3-raw
       python3 ../board3d/orient.py set3-raw labels3.json piecenet4.pt set3-clip 20 64 --colour --per-clip
       python3 ../board3d/train3d.py set1,set2,set-renders2,set3-clip piecenet6a.pt 6
       python3 ../board3d/orient.py set3-raw labels3.json piecenet6a.pt set3 5 6

4. Train (PyTorch, MPS) with every fourth clip held out, and export; several crop sets may be given,
   comma separated:

       python3 ../board3d/train3d.py set1,set2,set-renders2,set3 piecenet.pt 10
       python3 ../board3d/export3d.py piecenet.pt ../../App/Resources/PieceClassifier.mlpackage

5. Measure on a set the classifier was not trained on. ChessReD2K (a plastic Staunton set on a
   roll-up board; CC BY-NC-SA 4.0, so for measuring only, never for training) from 4TU.ResearchData,
   doi:10.4121/99b5c721-280b-450b-b058-b2900b69a90f, `annotations.json` and `chessred2k.zip` in
   `chessred/`. Its test games, cut at the hand-marked corners:

       venv/bin/python ../board3d/chessred_crops.py chessred chessred-test test
       python3 ../board3d/measure.py piecenet.pt chessred-test set1 set2

   The zip (4.4 GB) is not needed once `chessred-test` is cut, and was deleted for disk space:
   download it again to cut another split.

   `eval_chessred.py` measures the board finder against the same corners.

Results so far. piecenet3 (shipped 2026-11-14, trained 12 epochs on both sets of clips): on the
held-out clips' crops, 97.5% of the turned-board frames with every square right (26% for piecenet2,
trained on the first set only), and 95.4% of the first set's. End to end in the app (finder, reader
and classifier on 561 held-out frames): 519 read with every square right, 23 with no board found
(the corner editor opens), 15 with more than one square wrong. On ChessReD's Staunton set it reads
a third of the squares wrong and no photo fully right: it has only seen one, quite different, set.

piecenet6 (shipped 2026-11-15; greyscale, scale augmented; 10 epochs on both travel-set clip sets,
the wooden set and 2,000 renders): held-out frames with every square right 96.2% (first set), 96.9%
(turned), 79.8% (wooden set; its commonest mistake black pawns on dark squares read as empty).
On ChessReD 4.5% of squares wrong and 7.8% of photos fully right, against 16.0% and none for the
colour model piecenet4. The board finder judges the lattice's basis on cells with all four corners
found, and rejects blocks with a row that does not alternate (the wooden set's frame): on a sample
of the old frames, 301 read fully right against 294 before.
