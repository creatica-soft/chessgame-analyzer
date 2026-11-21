"""Renders chess boards for training a board finder: many kinds of board, on many surfaces, from
any side and height, with the playing area's corners and its 81 square corners as labels.

Run inside Blender (5.x):

    blender -b -P boards3d.py -- positions.json out-dir first count [seed]

The finder must find the 8 x 8 playing area, whatever the board looks like and whatever is round
it, so what varies here is everything but that: square size (18-65 mm) and colours; vinyl,
magnetic travel, wooden and printed boards, with or without a margin, a frame, an inlay line,
printed coordinates and a fold seam; tables of planks with dark seams, wood, cloth, a checked
cloth or square tiles (things that look like a board and are not); a wall, clutter; pieces in
random positions (render.py's Staunton sets), which hide parts of the board as in real use;
lighting; and the camera, from any side and from low to straight above, held a little crooked,
sometimes with a corner out of the picture.

For the piece classifier, RENDER_SCALE=2 RENDER_PIECES=1 RENDER_NEAR=1 makes the pictures twice
as big (1280 long, as the app's crops are cut from), with pieces on every board and the camera
nearer; render.py's sets vary in
proportions and material (plastic, wood, gold against silver, coloured pairs).

Writes out-dir/BRD_<n>.jpg and out-dir/meta.json: per image the board's style, the playing area's
corners a1, h1, h8, a8 and its 9 x 9 square corners (file-major from a1's corner) in the image's
pixels, which may lie outside the picture.
"""
import sys, os, json, math, random
import bpy
from mathutils import Vector, Matrix
from bpy_extras.object_utils import world_to_camera_view

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render as R  # noqa: E402  (pieces, materials and lights)

rng = R.rng
MM = R.MM

PAIRS = [
    # (light, dark) squares
    ('#EEEED2', '#769656'), ('#E9E6D0', '#6E8B5A'), ('#EDEAD8', '#587A4C'),       # green and buff
    ('#F0D9B5', '#B58863'), ('#E3C9A0', '#7A5535'), ('#D9BC8C', '#5E3F27'),       # browns
    ('#E8E8E0', '#1C1C1C'), ('#D8D8D2', '#303030'), ('#F5F0E6', '#3C3C3C'),       # black and white
    ('#DEE3E6', '#8CA2AD'), ('#E6EBF0', '#4B6A88'),                                # blue
    ('#F2E6D8', '#8B2E2E'), ('#F4F2EC', '#5A3A30'), ('#EFE3C8', '#A0522D'),       # red, brown
]


def random_pair():
    """A light and a dark square colour: a known pair, or any hue at two lightnesses."""
    if rng.random() < 0.75:
        light, dark = rng.choice(PAIRS)
        return R.jitter(R.srgb(light), 0.06), R.jitter(R.srgb(dark), 0.12)
    import colorsys
    h = rng.random()
    light = colorsys.hls_to_rgb(h, rng.uniform(0.72, 0.93), rng.uniform(0.05, 0.4))
    dark = colorsys.hls_to_rgb((h + rng.uniform(-0.08, 0.08)) % 1, rng.uniform(0.12, 0.5), rng.uniform(0.1, 0.6))
    return R.srgb(light), R.srgb(dark)


def strip(name, x0, y0, x1, y1, z, mat, height=0.0004):
    """A thin flat box from (x0, y0) to (x1, y1), its top at z + height: lines, seams."""
    obj = R.box(name, (abs(x1 - x0), abs(y1 - y0), height), ((x0 + x1) / 2, (y0 + y1) / 2, z + height / 2))
    obj.data.materials.append(mat)
    return obj


def text(body, x, y, z, size, angle, mat):
    curve = bpy.data.curves.new('coord', 'FONT')
    curve.body = body
    curve.size = size
    curve.align_x, curve.align_y = 'CENTER', 'CENTER'
    obj = bpy.data.objects.new('coord', curve)
    obj.location = (x, y, z + 0.0002)
    obj.rotation_euler = (0, 0, angle)
    obj.data.materials.append(mat)
    bpy.context.collection.objects.link(obj)
    return obj


def make_board():
    """A board, its playing area centred on the origin, a1's corner at (-4, -4) squares. Returns
    (square, height of the playing surface, style)."""
    style = rng.choices(['vinyl', 'travel', 'wood', 'printed'], [0.3, 0.25, 0.3, 0.15])[0]
    if style == 'travel':
        square = rng.uniform(18, 32) * MM
        if rng.random() < 0.6:
            light, dark = R.jitter(R.srgb(rng.choice(['#D8D8D2', '#E8E8E0', '#C8C8C0'])), 0.05), R.jitter(R.srgb('#1C1C1C'), 0.3)
        else:
            light, dark = random_pair()
        thick = rng.uniform(8, 15) * MM
        margin = square * rng.uniform(0.35, 0.8)
        border = R.jitter(R.srgb(rng.choice(['#141414', '#1E1E1E', '#3A2A20'])), 0.3)
        gloss = rng.uniform(0.1, 0.4)
    elif style == 'wood':
        square = rng.uniform(35, 62) * MM
        light, dark = R.jitter(R.srgb(rng.choice(['#E8CFA0', '#EBD5AA', '#DDBF8A'])), 0.06), \
            R.jitter(R.srgb(rng.choice(['#7A3F22', '#5E3420', '#8A4A2A', '#4A2C1E'])), 0.12)
        thick = rng.uniform(10, 22) * MM
        margin = square * rng.uniform(0.2, 0.9)
        border = R.jitter(R.srgb(rng.choice(['#8A4A2A', '#6E3A22', '#A0603A', '#5A3A28'])), 0.12)
        gloss = rng.uniform(0.15, 0.5)
    elif style == 'printed':
        square = rng.uniform(25, 50) * MM
        light, dark = random_pair()
        thick = rng.uniform(0.3, 2) * MM
        margin = square * rng.choice([0, rng.uniform(0.2, 1.5)])
        border = light if rng.random() < 0.6 else R.jitter(R.srgb('#F5F5F0'), 0.05)
        gloss = rng.uniform(0.3, 0.9)
    else:
        square = rng.uniform(45, 65) * MM
        light, dark = random_pair()
        thick = rng.uniform(1, 3) * MM
        margin = square * rng.uniform(0.25, 1.0)
        border = light if rng.random() < 0.7 else R.jitter(R.srgb('#F2F0EA'), 0.05)
        gloss = rng.uniform(0.25, 0.85)
    grain = style == 'wood'
    light_mat = R.material('light', light, gloss, wood=(R.shade(light, 0.75, 0.92), 30) if grain else None)
    dark_mat = R.material('dark', dark, gloss, wood=(R.shade(dark, 0.6, 0.85), 30) if grain else None)
    border_mat = R.material('border', border, gloss, wood=(R.shade(border, 0.6, 0.85), 20) if grain else None)
    ink = R.material('ink', R.jitter(R.srgb('#101010') if sum(border) > 0.6 else R.srgb('#E8E8E0'), 0.2), 0.6)

    # The squares.
    import bmesh
    mesh = bpy.data.meshes.new('squares')
    bm = bmesh.new()
    for f in range(8):
        for r in range(8):
            x0, y0 = (f - 4) * square, (r - 4) * square
            vs = [bm.verts.new((x0 + dx, y0 + dy, thick)) for dx, dy in ((0, 0), (square, 0), (square, square), (0, square))]
            bm.faces.new(vs).material_index = 0 if (f + r) % 2 == 0 else 1     # a1 dark
    bm.to_mesh(mesh)
    bm.free()
    squares = bpy.data.objects.new('squares', mesh)
    squares.data.materials.append(dark_mat)
    squares.data.materials.append(light_mat)
    bpy.context.collection.objects.link(squares)
    half = 4 * square + margin
    if margin > 0:
        base = R.box('board', (2 * half, 2 * half, thick * 0.999), (0, 0, thick / 2 - 0.0001))
        base.data.materials.append(border_mat)

    # A frame standing round the margin.
    if style in ('wood', 'travel') and rng.random() < 0.85:
        width = (square * rng.uniform(0.25, 0.7)) if style == 'wood' else rng.uniform(3, 8) * MM
        rise = rng.uniform(0, 5) * MM if style == 'wood' else rng.uniform(0.5, 3) * MM
        frame_mat = border_mat if rng.random() < 0.7 else R.material('frame', R.jitter(border, 0.2), gloss)
        for sx, sy, w, h in ((0, 1, 2 * (half + width), width), (0, -1, 2 * (half + width), width),
                             (1, 0, width, 2 * half), (-1, 0, width, 2 * half)):
            part = R.box('frame', (w, h, thick + rise), (sx * (half + width / 2), sy * (half + width / 2), (thick + rise) / 2))
            part.data.materials.append(frame_mat)
            if style == 'wood':
                bevel = part.modifiers.new('bevel', 'BEVEL')
                bevel.width = min(width, thick) * rng.uniform(0.15, 0.4)
                bevel.segments = 3
        half += width

    # An inlay line round the playing area.
    if margin > 2 * MM and rng.random() < (0.7 if style == 'wood' else 0.35):
        d = min(margin * 0.6, rng.uniform(0.0, 0.25) * square + 0.5 * MM)
        w = rng.uniform(0.6, 3) * MM
        e = 4 * square + d
        for x0, y0, x1, y1 in ((-e - w, -e - w, e + w, -e), (-e - w, e, e + w, e + w), (-e - w, -e, -e, e), (e, -e, e + w, e)):
            strip('inlay', x0, y0, x1, y1, thick, ink)

    # Coordinates printed in the margin.
    if margin > 0.3 * square and rng.random() < (0.85 if style == 'travel' else 0.45):
        size = min(margin * 0.7, square * rng.uniform(0.2, 0.4))
        m = 4 * square + margin / 2
        for k in range(8):
            c = (k - 3.5) * square
            text('abcdefgh'[k], c, -m, thick, size, 0, ink)
            text('12345678'[k], -m, c, thick, size, 0, ink)
            if rng.random() < 0.5 or k == 0:
                pass
        if rng.random() < 0.5:
            for k in range(8):
                c = (k - 3.5) * square
                text('abcdefgh'[k], c, m, thick, size, math.pi, ink)
                text('12345678'[k], m, c, thick, size, math.pi, ink)

    # The fold of a folding board: a dark line across the middle, through the margin and frame.
    if style in ('travel', 'wood', 'printed') and rng.random() < 0.6:
        w = rng.uniform(0.4, 2) * MM
        seam = R.material('seam', R.jitter(R.srgb('#0A0A0A'), 0.3), 0.8)
        if rng.random() < 0.5:
            strip('seam', -w / 2, -half, w / 2, half, thick + 6 * MM, seam, height=0.0002).location.z = thick + 0.0002
        else:
            strip('seam', -half, -w / 2, half, w / 2, thick + 6 * MM, seam, height=0.0002).location.z = thick + 0.0002
    return square, thick, style, half


def make_table():
    """The surface the board stands on, and sometimes a wall behind."""
    kind = rng.choices(['planks', 'wood', 'cloth', 'checked', 'tiles', 'plain'], [0.3, 0.2, 0.15, 0.08, 0.1, 0.17])[0]
    m = bpy.data.materials.new('table')
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    bsdf = nodes['Principled BSDF']
    bsdf.inputs['Roughness'].default_value = rng.uniform(0.3, 0.9)
    base = R.jitter(R.srgb(rng.choice(['#8B6B4A', '#6E5A48', '#C9A27E', '#5A4636', '#D8D8D8', '#F0F0F0', '#3A3A3A',
                                       '#7F8C8D', '#A0522D', '#2E4A3A', '#3A4A6A', '#8A2A2A'])), 0.25)
    coord = nodes.new('ShaderNodeTexCoord')
    mapping = nodes.new('ShaderNodeMapping')
    mapping.inputs['Rotation'].default_value = (0, 0, rng.uniform(0, math.pi))
    links.new(coord.outputs['Object'], mapping.inputs['Vector'])
    if kind in ('planks', 'tiles'):
        tex = nodes.new('ShaderNodeTexBrick')
        tex.inputs['Color1'].default_value = (*base, 1)
        tex.inputs['Color2'].default_value = (*R.jitter(base, 0.15), 1)
        tex.inputs['Mortar'].default_value = (*R.jitter(R.srgb('#151515'), 0.4), 1)
        tex.inputs['Scale'].default_value = 1
        if kind == 'planks':
            plank = rng.uniform(0.04, 0.15)
            tex.inputs['Brick Width'].default_value = rng.uniform(0.8, 2.5)
            tex.inputs['Row Height'].default_value = plank
            tex.inputs['Mortar Size'].default_value = rng.uniform(0.002, 0.008)
            tex.offset = rng.uniform(0.2, 0.7)
        else:
            tile = rng.uniform(0.08, 0.3)
            tex.inputs['Brick Width'].default_value = tile
            tex.inputs['Row Height'].default_value = tile
            tex.inputs['Mortar Size'].default_value = rng.uniform(0.002, 0.01)
            tex.offset = 0
        links.new(mapping.outputs['Vector'], tex.inputs['Vector'])
        links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
    elif kind == 'checked':
        tex = nodes.new('ShaderNodeTexChecker')
        tex.inputs['Color1'].default_value = (*base, 1)
        tex.inputs['Color2'].default_value = (*R.jitter(R.srgb('#F2F0EA'), 0.1), 1)
        tex.inputs['Scale'].default_value = 2 / rng.uniform(0.03, 0.12)     # checks of 3-12 cm
        links.new(mapping.outputs['Vector'], tex.inputs['Vector'])
        links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
    elif kind in ('wood', 'cloth'):
        noise = nodes.new('ShaderNodeTexNoise')
        noise.inputs['Scale'].default_value = rng.uniform(4, 40) if kind == 'wood' else rng.uniform(50, 400)
        noise.inputs['Detail'].default_value = 8
        if kind == 'wood':
            mapping.inputs['Scale'].default_value = (8, 1, 1)
        ramp = nodes.new('ShaderNodeValToRGB')
        ramp.color_ramp.elements[0].color = (*R.shade(base, 0.55, 0.85), 1)
        ramp.color_ramp.elements[1].color = (*base, 1)
        links.new(mapping.outputs['Vector'], noise.inputs['Vector'])
        links.new(noise.outputs['Fac'], ramp.inputs['Fac'])
        links.new(ramp.outputs['Color'], bsdf.inputs['Base Color'])
    else:
        bsdf.inputs['Base Color'].default_value = (*base, 1)
    table = R.box('table', (4, 4, 0.02), (0, 0, -0.01))
    table.data.materials.append(m)
    if rng.random() < 0.6:
        wall = R.box('wall', (6, 0.05, 3), (0, rng.choice([-1, 1]) * rng.uniform(0.5, 1.6), 1.5))
        wall.rotation_euler = (0, 0, rng.uniform(-0.6, 0.6))
        wall.data.materials.append(R.material('wall', R.jitter(R.srgb(rng.choice(['#F0EEE8', '#D8D0C0', '#B0B8C0', '#E8E0D0', '#606060'])), 0.15), 0.8))
        return kind, wall
    return kind, None


def wall_between(wall, cam):
    """Whether the wall stands between the camera and the board (the camera behind it)."""
    normal = wall.matrix_world.to_3x3() @ Vector((0, 1, 0))
    side = lambda p: (p - wall.location).dot(normal)
    return side(cam.location) * side(Vector((0, 0, 0))) < 0


def make_clutter(half):
    """Some things on the table round the board: books, cups, a phone."""
    for _ in range(rng.choice([0, 0, 1, 2, 3, 4])):
        a = rng.uniform(0, 2 * math.pi)
        d = half * math.sqrt(2) + rng.uniform(0.04, 0.3)
        size = rng.uniform(0.03, 0.25)
        col = R.material('thing', R.jitter(R.srgb((rng.random(), rng.random(), rng.random())), 0.2), rng.uniform(0.2, 0.9))
        if rng.random() < 0.5:
            obj = R.box('thing', (size, size * rng.uniform(0.5, 1.5), size * rng.uniform(0.05, 0.6)), (d * math.cos(a), d * math.sin(a), 0))
            obj.location.z = obj.dimensions.z / 2
            obj.rotation_euler = (0, 0, rng.uniform(0, math.pi))
        else:
            bpy.ops.mesh.primitive_cylinder_add(radius=size / 3, depth=size * rng.uniform(0.6, 1.4),
                                                location=(d * math.cos(a), d * math.sin(a), 0))
            obj = bpy.context.object
            obj.location.z = obj.dimensions.z / 2
        obj.data.materials.append(col)


def place_pieces(ctx, fen):
    """The position's pieces on the board, loosely placed; returns them, to remove later."""
    square, thick, protos = ctx['square'], ctx['thick'], ctx['protos']
    made = []
    rows = fen.split('/')
    for r in range(8):
        f = 0
        for ch in rows[7 - r]:
            if ch.isdigit():
                f += int(ch)
                continue
            obj = protos[('w' if ch.isupper() else 'b', ch.lower())].copy()
            obj.hide_render = obj.hide_viewport = False
            bpy.context.collection.objects.link(obj)
            off = 0.15 * square
            obj.location = ((f - 3.5) * square + rng.uniform(-off, off), (r - 3.5) * square + rng.uniform(-off, off), thick)
            # Knights look forward, give or take; other pieces at any turn.
            if ch.lower() == 'n':
                facing = math.pi / 2 if ch.isupper() else -math.pi / 2
                obj.rotation_euler = (0, 0, facing + math.radians(rng.gauss(0, 35)))
            else:
                obj.rotation_euler = (0, 0, rng.uniform(0, 2 * math.pi))
            made.append(obj)
            f += 1
    return made


def place_camera(scene, square, thick, size):
    """A phone's camera anywhere round the board. Returns the playing area's corners and square
    corners in pixels, or None if no view fits."""
    cam_data = bpy.data.cameras.new('camera')
    cam_data.sensor_width = 36
    tele = rng.random() < 0.15
    cam_data.lens = rng.uniform(48, 77) if tele else rng.uniform(24, 30)
    cam = bpy.data.objects.new('camera', cam_data)
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    w, h = size
    scene.render.resolution_x, scene.render.resolution_y = w, h
    lattice = [Vector(((f - 4) * square, (r - 4) * square, thick)) for f in range(9) for r in range(9)]
    corners = [lattice[i] for i in (0, 72, 80, 8)]                   # a1, h1, h8, a8
    # A corner out of the picture, for the finder; the piece classifier's renders keep all
    # squares in view, as the app needs them (RENDER_NEAR).
    cut_corner = rng.random() < (0 if NEAR_CAMERA else 0.12)
    for _ in range(300):
        azimuth = rng.uniform(0, 2 * math.pi)
        elevation = math.radians(rng.triangular(12, 89, 40))
        distance = 8 * square * rng.uniform(*NEAR) * (2.2 if tele else 1)
        target = Vector((rng.uniform(-1.5, 1.5) * square, rng.uniform(-1.5, 1.5) * square, thick))
        cam.location = target + distance * Vector((math.sin(azimuth) * math.cos(elevation),
                                                   -math.cos(azimuth) * math.cos(elevation), math.sin(elevation)))
        look = (target - cam.location).to_track_quat('-Z', 'Y')
        roll = Matrix.Rotation(math.radians(rng.gauss(0, 7)), 4, 'Z')
        cam.rotation_euler = (look.to_matrix().to_4x4() @ roll).to_euler()
        bpy.context.view_layer.update()
        pts = [world_to_camera_view(scene, cam, c) for c in corners]
        if any(p.z <= 0 for p in pts):
            continue
        inside = sum(0.0 < p.x < 1.0 and 0.0 < p.y < 1.0 for p in pts)
        if inside < (3 if cut_corner else 4) or (cut_corner and inside == 4):
            continue
        xs = [min(max(p.x, 0), 1) for p in pts]
        ys = [min(max(p.y, 0), 1) for p in pts]
        area = abs(sum(xs[i] * ys[(i + 1) % 4] - xs[(i + 1) % 4] * ys[i] for i in range(4))) / 2
        if area < 0.05:
            continue
        project = lambda v: (lambda p: (p.x * w, (1 - p.y) * h))(world_to_camera_view(scene, cam, v))
        return cam, [project(c) for c in corners], [project(v) for v in lattice]
    bpy.data.objects.remove(cam, do_unlink=True)
    return None


def build_scene():
    scene = R.clear_scene()
    square, thick, style, half = make_board()
    table, wall = make_table()
    make_clutter(half)
    white, black = R.piece_materials()
    protos = R.piece_set(white, black, square / (55 * MM) * rng.uniform(0.95, 1.2))
    return {'scene': scene, 'square': square, 'thick': thick, 'style': style, 'table': table, 'wall': wall,
            'protos': protos, 'temp': []}


PER_SCENE = int(os.environ.get('RENDER_PER_SET', 8))
# For the piece classifier's crops: bigger pictures (its crops are cut from frames 1280 pixels
# long), and pieces on every board.
SCALE = float(os.environ.get('RENDER_SCALE', 1))
WITH_PIECES = float(os.environ.get('RENDER_PIECES', 0.85))
# Camera distance, in board widths: the piece classifier's crops want the board big in the
# picture, as in live use (RENDER_NEAR=1).
NEAR_CAMERA = os.environ.get('RENDER_NEAR') == '1'
NEAR = (0.8, 1.8) if NEAR_CAMERA else (0.9, 3.2)


def save_meta(meta, path):
    json.dump(meta, open(path + '.part', 'w'))
    os.replace(path + '.part', path)

if __name__ == '__main__':
    import time
    argv = sys.argv[sys.argv.index('--') + 1:]
    positions_path, out_dir, first, count = argv[0], argv[1], int(argv[2]), int(argv[3])
    rng.seed(int(argv[4]) if len(argv) > 4 else first + 7919)
    fens = json.load(open(positions_path))
    os.makedirs(out_dir, exist_ok=True)
    meta_path = os.path.join(out_dir, 'meta.json')
    meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
    ctx = None
    for i, n in enumerate(range(first, first + count)):
        name = f'BRD_{n}.jpg'
        if name in meta:
            continue
        t0 = time.time()
        if ctx is None or i % PER_SCENE == 0:
            ctx = build_scene()
        for obj in ctx['temp']:
            bpy.data.objects.remove(obj, do_unlink=True)
        ctx['temp'] = R.make_lights()
        fen = rng.choice(fens) if rng.random() < WITH_PIECES else '8/8/8/8/8/8/8/8'
        ctx['temp'] += place_pieces(ctx, fen)
        size = tuple(int(v * SCALE) for v in rng.choice([(640, 480), (480, 640), (640, 360), (360, 640)]))
        placed = place_camera(ctx['scene'], ctx['square'], ctx['thick'], size)
        if placed is None:
            continue
        cam, corners, lattice = placed
        ctx['temp'].append(cam)
        if ctx['wall'] is not None:
            ctx['wall'].hide_render = wall_between(ctx['wall'], cam)
        ctx['scene'].view_settings.exposure = rng.uniform(-0.6, 0.5)
        ctx['scene'].render.filepath = os.path.join(out_dir, name)
        bpy.ops.render.render(write_still=True)
        meta[name] = {'style': ctx['style'], 'table': ctx['table'], 'square_mm': round(ctx['square'] / MM, 1),
                      'fen': fen, 'corners': corners, 'lattice': lattice}
        # Every image's labels, rewritten whole: often enough to lose little to a stop, seldom enough
        # that the rewriting (tens of MB by the end) does not slow the renders; replaced by a rename
        # so a stop mid-write never leaves a broken file.
        if len(meta) % 200 == 0:
            save_meta(meta, meta_path)
        print(f'rendered {n} {ctx["style"]} on {ctx["table"]} ({time.time() - t0:.1f}s)', flush=True)
    save_meta(meta, meta_path)
