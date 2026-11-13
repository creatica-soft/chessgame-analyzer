"""Cuts diagram fonts into square tiles: each piece on a light and on a dark square, and the empty
dark square. The empty dark square '+' fills its whole cell, so its box is the square for all."""
import os, sys
from PIL import Image, ImageDraw, ImageFont

MERIDA = dict(wK='k', wQ='q', wR='r', wB='b', wN='n', wP='p', bK='l', bQ='w', bR='t', bB='v', bN='m', bP='o')
ALPHA = dict(MERIDA, wN='h', bB='n', bN='j')
FONTS = {f: MERIDA for f in ['aventurer', 'case', 'chess7', 'kingdom', 'leipzig', 'lucefont', 'mark',
                             'marroquin', 'maya', 'merida', 'millendk', 'motif', 'usual']}
FONTS.update({f: ALPHA for f in ['alpha', 'berlin', 'cheq']})

src, dst = sys.argv[1], sys.argv[2]
F, OUT = 200, 96
for name, mapping in FONTS.items():
    path = next(p for p in os.listdir(src) if p.lower().startswith(name + '.'))
    font = ImageFont.truetype(f'{src}/{path}', F)
    def draw(ch):
        im = Image.new('L', (3 * F, 3 * F), 255)
        ImageDraw.Draw(im).text((F, F), ch, font=font, fill=0)
        return im
    box = Image.eval(draw('+'), lambda v: 255 - v).getbbox()
    w, h = box[2] - box[0], box[3] - box[1]
    if not box or abs(w - h) > 0.08 * max(w, h):
        print('skip', name, box); continue
    os.makedirs(f'{dst}/font-{name}', exist_ok=True)
    draw('+').crop(box).resize((OUT, OUT), Image.LANCZOS).save(f'{dst}/font-{name}/empty_d.png')
    for piece, ch in mapping.items():
        draw(ch).crop(box).resize((OUT, OUT), Image.LANCZOS).save(f'{dst}/font-{name}/{piece}_l.png')
        draw(ch.upper()).crop(box).resize((OUT, OUT), Image.LANCZOS).save(f'{dst}/font-{name}/{piece}_d.png')
    print('ok', name)
