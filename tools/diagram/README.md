# Diagram square classifier

`App/Resources/SquareClassifier.mlpackage` classifies one square of a straightened chess diagram:
empty, or one of the twelve pieces. It is trained only on synthetic diagrams made here.

1. Piece images: the lichess piece sets (https://github.com/lichess-org/lila/tree/master/public/piece,
   each under its own licence; used only as training data, not shipped), plus the chess symbols of
   four macOS fonts. Download the SVGs into `pieces-svg/<set>/{wK,…,bP}.svg`, then

       swiftc -O -o rasterize rasterize.swift && ./rasterize pieces-svg pieces

   And the classic freeware diagram fonts (Alpha, Merida, Leipzig, Cases, … from
   https://github.com/mcroitor/chess-fonts, `ttf/`), cut into square tiles, each piece on a light
   and on a hatched dark square in the font's own hatching:

       python3 fontglyphs.py fonts-ttf fontglyphs

2. Squares: `gen.py` draws boards typeset in the diagram fonts, and from the piece images in book
   styles (hatched, dotted or grey dark squares, frames) and screen styles (with last-move highlights), degrades them like a print or photo (blur, noise,
   JPEG, uneven light, ink spread; moiré and glare as in photos of a screen), warps
   them from slightly wrong corners as the app would, and cuts the 64 squares. The geometry
   constants must match `DiagramReader.Geometry`.

       TILES=fontglyphs python3 gen.py pieces train.npz 8000 leipzig,font-leipzig,font-kingdom,maestro,kosal,font-Menlo

   The listed styles are held out of training, to measure accuracy on styles never seen;
   `eval_boards.py squarenet.pt <style> 150` reports whole boards in one style. The shipped model
   is then trained with nothing held out (pass a style that does not exist).

3. Train (PyTorch, MPS) and export to Core ML:

       python3 train.py train.npz squarenet.pt 8
       python3 train.py more.npz squarenet2.pt 4 --init=squarenet.pt   # fine-tune on new damage
       python3 export.py squarenet.pt ../../App/Resources/SquareClassifier.mlpackage
