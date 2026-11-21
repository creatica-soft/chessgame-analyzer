"""Renders photos of a Staunton chess set on a tournament board, for training the piece classifier.

Run inside Blender (5.x):

    blender -b -P render.py -- positions.json out-dir first count [seed]

Everything is built here, from no outside models: the pieces are lathe profiles (and the knight a
bevelled silhouette) to FIDE proportions (king 95 mm, the others in the usual ratio, base 40-50%
of the height), varied a little in every render; the board has 50-60 mm squares, green and buff
vinyl or two woods; the materials are plastic (white and black) or wood (boxwood and ebony or
rosewood). Lighting, table, camera height, distance and angle round the board are random.

Writes out-dir/REN_<n>-000.jpg and out-dir/meta.json: per image the position (FEN board part) and
the playing area's corners a1, h1, h8, a8 in the image's pixels, as tools/board3d expects.
"""
import sys, os, json, math, random
import bpy, bmesh
from mathutils import Vector, Matrix, Euler
from bpy_extras.object_utils import world_to_camera_view

# Seeded in main; boards3d.py imports this module and seeds it itself.
rng = random.Random(0)
MM = 0.001


# MARK: - Scene

def clear_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    engine = os.environ.get('RENDER_ENGINE', 'EEVEE')
    scene.view_settings.view_transform = 'Standard'
    if engine == 'EEVEE':
        scene.render.engine = 'BLENDER_EEVEE'
        scene.eevee.taa_render_samples = 16
        scene.render.image_settings.file_format = 'JPEG'
        scene.render.image_settings.quality = 90
        return scene
    scene.render.engine = 'CYCLES'
    try:
        prefs = bpy.context.preferences.addons['cycles'].preferences
        prefs.compute_device_type = 'METAL'
        prefs.get_devices()
        for d in prefs.devices:
            d.use = d.type != 'CPU'
        scene.cycles.device = 'GPU'
    except Exception as e:
        print('GPU not used:', e)
    if os.environ.get('RENDER_DEBUG'):
        print('device', scene.cycles.device, [(d.name, d.type, d.use) for d in prefs.devices])
    scene.cycles.samples = 48
    scene.cycles.use_denoising = True
    scene.render.image_settings.file_format = 'JPEG'
    scene.render.image_settings.quality = 90
    return scene


def material(name, color, roughness, specular=0.5, coat=0.0, wood=None, metallic=0.0):
    """A principled material; `wood`: (darker colour, scale) for a grain of noise between the two."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nodes, links = m.node_tree.nodes, m.node_tree.links
    bsdf = nodes['Principled BSDF']
    bsdf.inputs['Base Color'].default_value = (*color, 1)
    bsdf.inputs['Roughness'].default_value = roughness
    bsdf.inputs['Metallic'].default_value = metallic
    if 'Coat Weight' in bsdf.inputs:
        bsdf.inputs['Coat Weight'].default_value = coat
    if wood:
        dark, scale = wood
        coord = nodes.new('ShaderNodeTexCoord')
        mapping = nodes.new('ShaderNodeMapping')
        mapping.inputs['Scale'].default_value = (scale, scale * 0.15, scale * 0.15)
        noise = nodes.new('ShaderNodeTexNoise')
        noise.inputs['Scale'].default_value = 6
        noise.inputs['Detail'].default_value = 8
        ramp = nodes.new('ShaderNodeValToRGB')
        ramp.color_ramp.elements[0].color = (*dark, 1)
        ramp.color_ramp.elements[1].color = (*color, 1)
        links.new(coord.outputs['Object'], mapping.inputs['Vector'])
        links.new(mapping.outputs['Vector'], noise.inputs['Vector'])
        links.new(noise.outputs['Fac'], ramp.inputs['Fac'])
        links.new(ramp.outputs['Color'], bsdf.inputs['Base Color'])
    return m


def srgb(hex_or_tuple):
    """sRGB colour to linear, as Blender's colour inputs take."""
    if isinstance(hex_or_tuple, str):
        h = hex_or_tuple.lstrip('#')
        c = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    else:
        c = list(hex_or_tuple)
    return tuple(x / 12.92 if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c)


def jitter(c, amount):
    """`c` lighter or darker by up to `amount`, its tint a little changed."""
    k = 1 + rng.uniform(-amount, amount)
    return tuple(min(1, max(0, x * k * (1 + rng.uniform(-0.03, 0.03)))) for x in c)


def shade(c, lo, hi):
    """`c` darker, the same tint: a wood grain's darker lines."""
    k = rng.uniform(lo, hi)
    return tuple(x * k for x in c)


# MARK: - Pieces

class Profile:
    """A piece's outline: (radius, height) points from the bottom centre round to the top."""
    def __init__(self):
        self.pts = []

    def to(self, r, z):
        self.pts.append((max(0.0, r), z))
        return self

    def arc(self, cr, cz, rx, rz, a0, a1, n=10):
        for i in range(n + 1):
            a = math.radians(a0 + (a1 - a0) * i / n)
            self.pts.append((max(0.0, cr + rx * math.cos(a)), cz + rz * math.sin(a)))
        return self


def lathe(name, profile, segments=48):
    """A solid of revolution about z from a profile starting and ending on the axis."""
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    rings = []
    for r, z in profile.pts:
        if r < 1e-6:
            rings.append([bm.verts.new((0, 0, z * MM))])
        else:
            rings.append([bm.verts.new((r * MM * math.cos(2 * math.pi * k / segments),
                                         r * MM * math.sin(2 * math.pi * k / segments), z * MM))
                          for k in range(segments)])
    for a, b in zip(rings, rings[1:]):
        if len(a) == 1 and len(b) == 1:
            continue
        if len(a) == 1:
            for k in range(segments):
                bm.faces.new((a[0], b[k], b[(k + 1) % segments]))
        elif len(b) == 1:
            for k in range(segments):
                bm.faces.new((a[k], b[0], a[(k + 1) % segments]))
        else:
            for k in range(segments):
                bm.faces.new((a[k], a[(k + 1) % segments], b[(k + 1) % segments], b[k]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    for p in mesh.polygons:
        p.use_smooth = True
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def box(name, size, location):
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1)
    bmesh.ops.scale(bm, vec=size, verts=bm.verts)
    bmesh.ops.translate(bm, vec=location, verts=bm.verts)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def sphere(name, radius, location):
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=24, v_segments=12, radius=radius)
    bmesh.ops.translate(bm, vec=location, verts=bm.verts)
    bm.to_mesh(mesh)
    bm.free()
    for p in mesh.polygons:
        p.use_smooth = True
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def cut(obj, cutter):
    m = obj.modifiers.new('cut', 'BOOLEAN')
    m.operation = 'DIFFERENCE'
    m.object = cutter
    cutter.hide_render = True
    cutter.hide_viewport = True


def join(objs, name):
    """One object of several: modifiers applied first (booleans)."""
    for o in objs:
        bpy.context.view_layer.objects.active = o
        for m in list(o.modifiers):
            bpy.ops.object.modifier_apply(modifier=m.name)
    bpy.ops.object.select_all(action='DESELECT')
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    obj.name = name
    return obj


def base(p, R, h):
    """The foot every piece stands on: a plinth, a ring above it, and a cove up to the stem."""
    p.to(0, 0).to(R, 0).to(R, h * 0.22)
    p.arc(R - h * 0.18, h * 0.40, h * 0.18, h * 0.18, -90, 90, 6)
    p.to(R * 0.86, h * 0.62)
    p.arc(R * 0.86 - h * 0.12, h * 0.74, h * 0.12, h * 0.12, -90, 90, 5)
    p.to(R * 0.62, h * 0.9).to(R * 0.55, h)
    return p


def collar(p, r, z, t):
    p.to(r * 0.75, z).to(r, z + t * 0.3).to(r * 1.02, z + t * 0.5).to(r, z + t * 0.7).to(r * 0.7, z + t)
    return p


def make_pawn(v):
    H, R = 50 * v['h'], 14 * v['w']
    p = base(Profile(), R, 9 * v['h'] * v['base'])
    p.to(R * 0.45, 14 * v['h']).to(R * 0.36, 23 * v['h'])
    collar(p, R * 0.6, 24 * v['h'], 4 * v['h'])
    head = 8.5 * v['w'] * v['head']
    neck = 28 * v['h']
    a0 = -math.degrees(math.acos(min(1, R * 0.3 / head)))
    cz = neck + head * math.sin(math.radians(-a0))
    p.arc(0, cz, head, head, a0, 90, 12)
    return [lathe('pawn', p)]


def make_rook(v):
    R = 18 * v['w']
    p = base(Profile(), R, 10 * v['h'] * v['base'])
    # A tower: barely narrowing up to a collar, then the turret, wider than the body.
    p.to(R * 0.72, 11 * v['h']).to(R * 0.66, 40 * v['h'])
    collar(p, R * 0.74, 41 * v['h'], 3 * v['h'])
    top, rim = 57 * v['h'], R * 0.8
    p.to(rim, 45 * v['h']).to(rim, top).to(rim * 0.7, top).to(rim * 0.7, top - 4).to(0, top - 4)
    body = lathe('rook', p)
    # Battlements: two or three cuts across the turret make four or six.
    n = rng.choice([2, 3])
    slot = rim * rng.uniform(0.3, 0.42)
    for k in range(n):
        c = box('crenel', (rim * 2.4 * MM, slot * MM, 8 * MM), (0, 0, top * MM))
        c.rotation_euler = (0, 0, math.pi * k / n + rng.uniform(0, math.pi))
        cut(body, c)
    return [body]


def make_knight(v):
    R = 17 * v['w']
    p = base(Profile(), R, 11 * v['h'] * v['base'])
    p.to(R * 0.58, 13 * v['h']).to(0, 13 * v['h'])
    foot = lathe('knight-foot', p)
    # The head, facing +x, from the side: neck, mane, ear, forehead, muzzle, jaw, throat.
    s = v['h']
    outline = [(-10, 12), (-11, 22), (-10.5, 32), (-8.5, 41), (-5, 48), (-2.5, 53), (-1.5, 58), (0.5, 61),
               (2.5, 57), (6, 55), (10, 51.5), (14, 45.5), (16.5, 39.5), (17, 35.5), (15.5, 32.5), (11, 32.5),
               (7.5, 34), (5, 31), (6, 25.5), (8.5, 19), (10, 12)]
    outline = [(x * (v['muzzle'] if x > 4 else 1) * v['w'] * MM, z * s * MM) for x, z in outline]
    thick = 17 * v['w'] * v['head'] * MM
    mesh = bpy.data.meshes.new('knight-head')
    bm = bmesh.new()
    verts = [bm.verts.new((x, -thick / 2, z)) for x, z in outline]
    face = bm.faces.new(verts)
    ext = bmesh.ops.extrude_face_region(bm, geom=[face])
    bmesh.ops.translate(bm, vec=(0, thick, 0), verts=[e for e in ext['geom'] if isinstance(e, bmesh.types.BMVert)])
    xs = [vt.co.x for vt in bm.verts]; zs = [vt.co.z for vt in bm.verts]
    for vt in bm.verts:
        fx = (vt.co.x - min(xs)) / (max(xs) - min(xs))
        fz = (vt.co.z - min(zs)) / (max(zs) - min(zs))
        vt.co.y *= 1.15 - 0.45 * fx - 0.2 * fz
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(mesh)
    bm.free()
    head = bpy.data.objects.new('knight-head', mesh)
    bpy.context.collection.objects.link(head)
    bevel = head.modifiers.new('bevel', 'BEVEL')
    bevel.width = thick * 0.3
    bevel.segments = 4
    bevel.limit_method = 'ANGLE'
    for poly in mesh.polygons:
        poly.use_smooth = True
    return [foot, head]


def make_bishop(v):
    R = 16 * v['w']
    p = base(Profile(), R, 10 * v['h'] * v['base'])
    p.to(R * 0.55, 12 * v['h']).to(R * 0.34, 37 * v['h'])
    collar(p, R * 0.64, 38 * v['h'], 5 * v['h'])
    rx, rz, cz = 9.5 * v['w'] * v['head'], 11 * v['h'], 54 * v['h']
    p.arc(0, cz, rx, rz, -60, 78, 14)
    finial = 2.6 * v['w']
    p.arc(0, cz + rz * 0.98 + finial * 0.9, finial, finial, -60, 90, 6)
    mitre = lathe('bishop', p)
    slit = box('slit', (1.6 * MM, rx * 2.4 * MM, 7 * MM), (rx * 0.55 * MM, 0, (cz + rz * 0.35) * MM))
    slit.rotation_euler = (0, math.radians(35), 0)
    cut(mitre, slit)
    return [mitre]


def make_queen(v):
    R = 19 * v['w']
    p = base(Profile(), R, 12 * v['h'] * v['base'])
    p.to(R * 0.55, 14 * v['h']).to(R * 0.33, 48 * v['h'])
    collar(p, R * 0.62, 49 * v['h'], 5 * v['h'])
    crown = 12.5 * v['w'] * v['head']
    p.to(R * 0.36, 56 * v['h']).to(crown, 72 * v['h']).to(crown * 0.94, 74 * v['h']).to(crown * 0.6, 74 * v['h'])
    p.arc(0, 74 * v['h'], crown * 0.6, 5 * v['h'], 0, 90, 6)
    ball = 3.2 * v['w']
    p.arc(0, 79 * v['h'] + ball * 0.9, ball, ball, -60, 90, 6)
    parts = [lathe('queen', p)]
    n = rng.choice([8, 9, 10])
    for k in range(n):
        a = 2 * math.pi * k / n
        parts.append(sphere('point', 1.9 * v['w'] * MM, (crown * 0.95 * math.cos(a) * MM, crown * 0.95 * math.sin(a) * MM,
                                                          75 * v['h'] * MM)))
    return parts


def make_king(v):
    R = 20 * v['w']
    p = base(Profile(), R, 13 * v['h'] * v['base'])
    p.to(R * 0.55, 15 * v['h']).to(R * 0.34, 55 * v['h'])
    collar(p, R * 0.62, 56 * v['h'], 6 * v['h'])
    crown = 12 * v['w'] * v['head']
    p.to(R * 0.38, 63 * v['h']).to(crown, 78 * v['h']).to(crown * 0.95, 80 * v['h'])
    p.arc(0, 80 * v['h'], crown * 0.95, 5 * v['h'], 0, 90, 8)
    body = lathe('king', p)
    top = 85 * v['h']
    arm = 2.2 * v['w']
    if v['king'] == 'ball':
        return [body, sphere('finial', 4.5 * v['w'] * MM, (0, 0, (top + 3.5) * MM))]
    upright = box('cross', (arm * 2 * MM, arm * 2 * MM, 11 * v['h'] * MM), (0, 0, (top + 5) * MM))
    bar = box('bar', (arm * 4.5 * MM, arm * 2 * MM, arm * 2 * MM), (0, 0, (top + 6.5) * MM))
    return [body, upright, bar]


MAKERS = {'p': make_pawn, 'r': make_rook, 'n': make_knight, 'b': make_bishop, 'q': make_queen, 'k': make_king}


def piece_set(white_mat, black_mat, scale):
    """One prototype per piece and colour, hidden; the board's pieces are linked copies."""
    # Proportions vary from set to set: a little taller or stouter, bigger heads, higher bases, a
    # longer muzzle, a cross or a ball on the king.
    v = {'h': scale * rng.uniform(0.92, 1.08), 'w': scale * rng.uniform(0.9, 1.1), 'head': rng.uniform(0.88, 1.12),
         'base': rng.uniform(0.8, 1.35), 'muzzle': rng.uniform(0.85, 1.2), 'king': rng.choice(['cross', 'cross', 'ball'])}
    protos = {}
    for kind, make in MAKERS.items():
        parts = make(v)
        obj = join(parts, kind) if len(parts) > 1 or parts[0].modifiers else parts[0]
        for colour, mat in (('w', white_mat), ('b', black_mat)):
            copy = obj.copy()
            copy.data = obj.data.copy()
            copy.data.materials.clear()
            copy.data.materials.append(mat)
            bpy.context.collection.objects.link(copy)
            copy.hide_render = True
            copy.hide_viewport = True
            protos[(colour, kind)] = copy
        bpy.data.objects.remove(obj)
    return protos


# MARK: - Board, table, light, camera

BOARDS = [
    # (light, dark, border): vinyl tournament boards, and wooden ones.
    ('#E9E6D0', '#6E8B5A', '#E9E6D0'),
    ('#EDEAD8', '#587A4C', '#EDEAD8'),
    ('#E3C9A0', '#7A5535', '#7A5230'),
    ('#D9BC8C', '#5E3F27', '#5C3A1E'),
    ('#F2F0EA', '#4A2E26', '#F2F0EA'),
    ('#F4F2EC', '#5A3A30', '#F4F2EC'),
    ('#F5F0E6', '#3C3C3C', '#F5F0E6'),
]


def make_board(square):
    i = rng.randrange(len(BOARDS))
    light, dark, border = BOARDS[i]
    wood = i in (2, 3)
    light_mat = material('light', jitter(srgb(light), 0.08), rng.uniform(0.3, 0.8),
                         wood=(shade(srgb(light), 0.7, 0.9), 30) if wood else None)
    dark_mat = material('dark', jitter(srgb(dark), 0.06), rng.uniform(0.3, 0.8),
                        wood=(shade(srgb(dark), 0.6, 0.85), 30) if wood else None)
    border_mat = material('border', jitter(srgb(border), 0.1), rng.uniform(0.3, 0.8))
    thick = (rng.uniform(1, 3) if not wood else rng.uniform(10, 20)) * MM
    mesh = bpy.data.meshes.new('squares')
    bm = bmesh.new()
    for f in range(8):
        for r in range(8):
            x0, y0 = (f - 4) * square, (r - 4) * square
            vs = [bm.verts.new((x0 + dx, y0 + dy, thick)) for dx, dy in ((0, 0), (square, 0), (square, square), (0, square))]
            face = bm.faces.new(vs)
            face.material_index = 0 if (f + r) % 2 == 0 else 1     # a1 dark
    bm.to_mesh(mesh)
    bm.free()
    squares = bpy.data.objects.new('squares', mesh)
    squares.data.materials.append(dark_mat)
    squares.data.materials.append(light_mat)
    bpy.context.collection.objects.link(squares)
    margin = square * rng.uniform(0.35, 0.9)
    side = 8 * square + 2 * margin
    frame = box('board', (side, side, thick * 0.999), (0, 0, thick / 2 - 0.0001))
    frame.data.materials.append(border_mat)
    return thick


def make_table():
    colour = rng.choice(['#8B6B4A', '#C9A27E', '#5A4636', '#D8D8D8', '#F0F0F0', '#3A3A3A', '#7F8C8D', '#A0522D'])
    mat = material('table', jitter(srgb(colour), 0.2), rng.uniform(0.2, 0.9),
                   wood=(shade(srgb(colour), 0.55, 0.85), 8) if rng.random() < 0.6 else None)
    table = box('table', (3, 3, 0.02), (0, 0, -0.01))
    table.data.materials.append(mat)


def make_lights():
    """The world's light and a sun and some lamps: the objects made, to remove for the next render.
    The world is made once per scene and only its values change (no new shader to compile)."""
    scene = bpy.context.scene
    if scene.world is None:
        scene.world = bpy.data.worlds.new('world')
        scene.world.use_nodes = True
    bg = scene.world.node_tree.nodes['Background']
    bg.inputs['Color'].default_value = (*jitter(srgb((0.8, 0.8, 0.82)), 0.15), 1)
    bg.inputs['Strength'].default_value = rng.uniform(0.1, 0.5)
    made = []
    sun = bpy.data.lights.new('sun', 'SUN')
    sun.energy = rng.uniform(0.5, 3.0)
    sun.angle = math.radians(rng.uniform(2, 20))
    sun_obj = bpy.data.objects.new('sun', sun)
    bpy.context.collection.objects.link(sun_obj)
    sun_obj.rotation_euler = (math.radians(rng.uniform(5, 50)), 0, rng.uniform(0, 2 * math.pi))
    made.append(sun_obj)
    for _ in range(rng.randint(1, 3)):
        data = bpy.data.lights.new('light', 'AREA')
        data.size = rng.uniform(0.3, 2.0)
        data.energy = rng.uniform(15, 90)
        warmth = rng.uniform(-0.25, 0.12)          # warm (indoor bulbs) to cool (daylight)
        colour = (1.0, 1.0 + warmth * 0.45, 1.0 + warmth)
        data.color = tuple(c / max(colour) for c in colour)
        light = bpy.data.objects.new('light', data)
        bpy.context.collection.objects.link(light)
        a, d = rng.uniform(0, 2 * math.pi), rng.uniform(0.3, 1.6)
        light.location = (d * math.cos(a), d * math.sin(a), rng.uniform(0.9, 2.2))
        direction = Vector((0, 0, 0)) - light.location
        light.rotation_euler = direction.to_track_quat('-Z', 'Y').to_euler()
        made.append(light)
    return made


made_camera = []


def place_camera(scene, square, size):
    """A phone's camera somewhere round the board, the whole playing area in the picture."""
    cam_data = bpy.data.cameras.new('camera')
    cam_data.sensor_width = 36
    cam_data.lens = rng.uniform(24, 30)              # a phone's main camera, as 35 mm
    cam = bpy.data.objects.new('camera', cam_data)
    bpy.context.collection.objects.link(cam)
    scene.camera = cam
    made_camera.append(cam)
    w, h = size
    scene.render.resolution_x, scene.render.resolution_y = w, h
    corners = [Vector((x * 4 * square, y * 4 * square, 0)) for x, y in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    for _ in range(200):
        azimuth = rng.uniform(0, 2 * math.pi)        # 0: from White's side
        elevation = math.radians(rng.triangular(20, 75, 38))
        distance = rng.uniform(0.35, 0.8)
        if os.environ.get('RENDER_CLOSE'):            # a close look, for checking the pieces
            azimuth, elevation, distance = rng.uniform(-0.3, 0.3), math.radians(35), 0.8
        target = Vector((rng.uniform(-0.6, 0.6) * square, rng.uniform(-0.6, 0.6) * square, 0))
        cam.location = target + distance * Vector((math.sin(azimuth) * math.cos(elevation),
                                                   -math.cos(azimuth) * math.cos(elevation), math.sin(elevation)))
        look = (target - cam.location).to_track_quat('-Z', 'Y')
        roll = Matrix.Rotation(math.radians(rng.gauss(0, 3)), 4, 'Z')
        cam.rotation_euler = (look.to_matrix().to_4x4() @ roll).to_euler()
        bpy.context.view_layer.update()
        pts = [world_to_camera_view(scene, cam, c) for c in corners]
        if all(0.04 < p.x < 0.96 and 0.04 < p.y < 0.96 and p.z > 0 for p in pts):
            area = abs(sum((pts[i].x * pts[(i + 1) % 4].y - pts[(i + 1) % 4].x * pts[i].y) for i in range(4))) / 2
            if area > 0.25:
                return [(p.x * w, (1 - p.y) * h) for p in pts]
    return None


# MARK: - A render

def piece_materials():
    """White's and Black's materials. Sets differ most in colour and material, which the
    classifier must not lean on: plastic, wood, metal (gold against silver, either way round,
    alike in lightness), and coloured pairs."""
    kind = rng.random()
    if kind < 0.2:               # metal
        silver = material('silver', jitter(srgb(rng.choice(['#C9CCCF', '#B8BBBE', '#D8D8D8', '#A9ACB0'])), 0.05), rng.uniform(0.15, 0.5),
                          metallic=rng.uniform(0.7, 1.0))
        gold = material('gold', jitter(srgb(rng.choice(['#D4AF37', '#C9A23F', '#B5A642', '#A8803A', '#8C6A3B', '#CFA85A'])), 0.06),
                        rng.uniform(0.15, 0.5), metallic=rng.uniform(0.7, 1.0))
        return (silver, gold) if rng.random() < 0.75 else (gold, silver)
    if kind < 0.35:              # coloured: a light side against a red, brown or green one
        white = material('white', jitter(srgb(rng.choice(['#F2EFE6', '#EDE0C0', '#E9D8A6', '#F5F1E8'])), 0.05), rng.uniform(0.15, 0.45),
                         coat=rng.uniform(0, 0.5))
        black = material('black', jitter(srgb(rng.choice(['#8B1A1A', '#A02C22', '#6E2B1A', '#7A3B14', '#2F4F2F', '#5C1F1F'])), 0.1),
                         rng.uniform(0.15, 0.45), coat=rng.uniform(0, 0.5),
                         wood=(shade(srgb('#4A1410'), 0.7, 1.0), 60) if rng.random() < 0.5 else None)
        return white, black
    if kind < 0.6:               # plastic
        white = material('white', jitter(srgb(rng.choice(['#F2EFE6', '#EDE6D2', '#FAFAF5', '#E9DDB8', '#EADFC0', '#E5D3A8', '#F0E4C4'])), 0.04), rng.uniform(0.15, 0.45), coat=rng.uniform(0, 0.4))
        black = material('black', jitter(srgb(rng.choice(['#141414', '#1E1A18', '#202020'])), 0.3), rng.uniform(0.12, 0.4), coat=rng.uniform(0, 0.5))
    else:                        # wood
        white = material('white', jitter(srgb(rng.choice(['#E6C892', '#EFD7A8', '#DDBB85'])), 0.06), rng.uniform(0.25, 0.5),
                         coat=rng.uniform(0.2, 0.7), wood=(shade(srgb('#C9A26A'), 0.85, 1.0), 60))
        black = material('black', jitter(srgb(rng.choice(['#2A1A12', '#3B2116', '#1A1210', '#5A2E1E', '#6B3420', '#4E2A1A'])), 0.2), rng.uniform(0.2, 0.45),
                         coat=rng.uniform(0.2, 0.7), wood=(shade(srgb('#120B08'), 0.8, 1.0), 60))
    return white, black


def build_set():
    """A scene: board, table, piece set and materials, kept for several renders (EEVEE compiles a
    material's shader once)."""
    scene = clear_scene()
    square = rng.uniform(50, 60) * MM
    thick = make_board(square)
    make_table()
    white, black = piece_materials()
    # Pieces in proportion to the squares: the king's base about three quarters of a square.
    protos = piece_set(white, black, square / (55 * MM) * rng.uniform(1.0, 1.2))
    return {'scene': scene, 'square': square, 'thick': thick, 'protos': protos, 'temp': []}


def render_position(ctx, n, fen):
    scene, square, thick, protos = ctx['scene'], ctx['square'], ctx['thick'], ctx['protos']
    # What the last render placed: pieces, lights, camera.
    for obj in ctx['temp'] + made_camera:
        bpy.data.objects.remove(obj, do_unlink=True)
    made_camera.clear()
    ctx['temp'] = make_lights()
    rows = fen.split('/')
    for r in range(8):
        f = 0
        for ch in rows[7 - r]:
            if ch.isdigit():
                f += int(ch)
                continue
            proto = protos[('w' if ch.isupper() else 'b', ch.lower())]
            obj = proto.copy()
            obj.hide_render = False
            obj.hide_viewport = False
            bpy.context.collection.objects.link(obj)
            ctx['temp'].append(obj)
            off = 0.12 * square
            obj.location = ((f - 3.5) * square + rng.uniform(-off, off), (r - 3.5) * square + rng.uniform(-off, off), thick)
            # Knights look forward, give or take; other pieces at any turn.
            if ch.lower() == 'n':
                facing = math.pi / 2 if ch.isupper() else -math.pi / 2
                obj.rotation_euler = (0, 0, facing + math.radians(rng.gauss(0, 35)))
            else:
                obj.rotation_euler = (0, 0, rng.uniform(0, 2 * math.pi))
            f += 1
    size = rng.choice([(1280, 720), (1280, 960), (720, 1280), (960, 1280)])
    corners = place_camera(scene, square, size)
    if corners is None:
        return None
    scene.view_settings.exposure = rng.uniform(-0.5, 0.4)
    name = f'REN_{n}-000.jpg'
    scene.render.filepath = os.path.join(out_dir, name)
    bpy.ops.render.render(write_still=True)
    return name, {'fen': fen, 'corners': corners}


# Renders per scene: a new set, board and table after this many.
PER_SET = int(os.environ.get('RENDER_PER_SET', 10))

if __name__ == '__main__':
    import time
    argv = sys.argv[sys.argv.index('--') + 1:]
    positions_path, out_dir, first, count = argv[0], argv[1], int(argv[2]), int(argv[3])
    rng.seed(int(argv[4]) if len(argv) > 4 else first)
    fens = json.load(open(positions_path))
    os.makedirs(out_dir, exist_ok=True)
    meta_path = os.path.join(out_dir, 'meta.json')
    meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}
    ctx = None
    for i, n in enumerate(range(first, first + count)):
        if f'REN_{n}-000.jpg' in meta:
            continue
        t0 = time.time()
        if ctx is None or i % PER_SET == 0:
            made_camera.clear()
            ctx = build_set()
        result = render_position(ctx, n, fens[n % len(fens)])
        if result:
            meta[result[0]] = result[1]
            json.dump(meta, open(meta_path, 'w'))
        print(f'rendered {n} ({time.time() - t0:.1f}s)', flush=True)
