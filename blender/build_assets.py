"""
Canyon Skies - Blender asset builder (Blender 4.x / 5.x).
Run:  blender -b -P build_assets.py
Builds plane.blend, manta.blend, showcase.blend + GLB exports for Godot.
"""
import bpy, bmesh, math, os
from mathutils import Vector, noise

HERE = os.path.dirname(os.path.abspath(__file__))
GLB_DIR = os.path.normpath(os.path.join(HERE, "..", "godot_project", "assets", "models"))
os.makedirs(GLB_DIR, exist_ok=True)

# ----------------------------------------------------------------- helpers
def lin(c):
    def f(v): return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    return (f(c[0]), f(c[1]), f(c[2]))

def smoothstep(a, b, x):
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)

def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))

def clear():
    bpy.ops.wm.read_factory_settings(use_empty=True)

def new_mat(name, base, rough=0.5, metal=0.0, emit=None, emit_strength=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*lin(base), 1.0)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    if emit:
        b.inputs["Emission Color"].default_value = (*lin(emit), 1.0)
        b.inputs["Emission Strength"].default_value = emit_strength
    return m

def finish(name, bm, mat, smooth=True, parent=None, loc=(0, 0, 0)):
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    for f in bm.faces:
        f.smooth = smooth
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    if mat:
        me.materials.append(mat)
    ob.location = loc
    if parent:
        ob.parent = parent
    return ob

def lathe(name, profile, mat, seg=24, squash=(1.0, 1.0), parent=None, loc=(0, 0, 0), smooth=True):
    """Revolve (y, radius) profile around the Y axis. Nose points to +Y."""
    bm = bmesh.new()
    rings = []
    for (y, r) in profile:
        r = max(r, 0.0008)
        rings.append([bm.verts.new((math.cos(2 * math.pi * i / seg) * r * squash[0], y,
                                    math.sin(2 * math.pi * i / seg) * r * squash[1])) for i in range(seg)])
    for k in range(len(rings) - 1):
        for i in range(seg):
            j = (i + 1) % seg
            bm.faces.new((rings[k][i], rings[k][j], rings[k + 1][j], rings[k + 1][i]))
    bm.faces.new(rings[0][::-1])
    bm.faces.new(rings[-1])
    return finish(name, bm, mat, smooth, parent, loc)

def tube(name, pts, radii, mat, seg=12, flat=1.0, parent=None):
    bm = bmesh.new()
    rings = []
    P = [Vector(p) for p in pts]
    for k, p in enumerate(P):
        tan = (P[min(k + 1, len(P) - 1)] - P[max(k - 1, 0)]).normalized()
        side = tan.cross(Vector((0, 0, 1)))
        if side.length < 1e-4:
            side = Vector((1, 0, 0))
        side.normalize()
        up = side.cross(tan).normalized()
        rings.append([bm.verts.new(p + side * math.cos(2 * math.pi * i / seg) * radii[k]
                                   + up * math.sin(2 * math.pi * i / seg) * radii[k] * flat) for i in range(seg)])
    for k in range(len(rings) - 1):
        for i in range(seg):
            j = (i + 1) % seg
            bm.faces.new((rings[k][i], rings[k][j], rings[k + 1][j], rings[k + 1][i]))
    bm.faces.new(rings[0][::-1])
    bm.faces.new(rings[-1])
    return finish(name, bm, mat, True, parent)

def slab(name, pts, thick, plane, mat, parent=None, bevel=0.015, z=0.0):
    bm = bmesh.new()
    top, bot = [], []
    for (a, b) in pts:
        if plane == "XY":
            top.append(bm.verts.new((a, b, z + thick / 2)))
            bot.append(bm.verts.new((a, b, z - thick / 2)))
        else:  # "YZ": a = y, b = z, thickness along X
            top.append(bm.verts.new((thick / 2, a, b)))
            bot.append(bm.verts.new((-thick / 2, a, b)))
    n = len(pts)
    bm.faces.new(top)
    bm.faces.new(bot[::-1])
    for i in range(n):
        bm.faces.new((top[i], bot[i], bot[(i + 1) % n], top[(i + 1) % n]))
    ob = finish(name, bm, mat, smooth=False, parent=parent)
    if bevel:
        md = ob.modifiers.new("Bevel", "BEVEL")
        md.width = bevel
        md.segments = 2
        md.limit_method = "ANGLE"
    return ob

def sphere(name, r, mat, loc, scale=(1, 1, 1), parent=None):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=16, v_segments=10, radius=r)
    for v in bm.verts:
        v.co.x *= scale[0]; v.co.y *= scale[1]; v.co.z *= scale[2]
    return finish(name, bm, mat, True, parent, loc)

def root_empty(name):
    e = bpy.data.objects.new(name, None)
    bpy.context.collection.objects.link(e)
    return e

def export_glb(name, objs, animations=False, apply_mod=True):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    path = os.path.join(GLB_DIR, name + ".glb")
    kw = dict(filepath=path, export_format="GLB", use_selection=True, export_apply=apply_mod,
              export_animations=animations, export_morph=True, export_yup=True,
              export_vertex_color="ACTIVE")
    while True:
        try:
            bpy.ops.export_scene.gltf(**kw)
            break
        except TypeError as e:
            bad = str(e).split('"')[1] if '"' in str(e) else None
            if bad in kw:
                del kw[bad]
            else:
                raise
    print("exported", path)

# ----------------------------------------------------------------- PLANE
def build_plane():
    hull = new_mat("Plane_Hull", (0.92, 0.93, 0.96), rough=0.32, metal=0.15)
    trim = new_mat("Plane_Trim", (0.16, 0.17, 0.20), rough=0.45, metal=0.5)
    accent = new_mat("Plane_Accent", (0.92, 0.32, 0.14), rough=0.4, metal=0.2)
    glass = new_mat("Plane_Glass", (0.05, 0.09, 0.15), rough=0.05, metal=0.3)
    glow = new_mat("Plane_Exhaust", (1.0, 0.45, 0.12), rough=0.4, emit=(1.0, 0.5, 0.15), emit_strength=10.0)

    root = root_empty("Plane")
    kids = []
    # fuselage (nose to +Y)
    fus = [(-3.1, 0.07), (-2.7, 0.2), (-1.6, 0.3), (0.0, 0.35), (1.2, 0.31), (2.0, 0.2), (2.7, 0.08), (3.1, 0.03)]
    kids.append(lathe("Fuselage", fus, hull, 24, (1.0, 0.9), root))
    kids.append(lathe("NoseSpike", [(3.05, 0.035), (3.6, 0.02), (4.3, 0.004)], trim, 12, parent=root))
    kids.append(lathe("Canopy", [(-0.6, 0.0), (-0.35, 0.14), (0.05, 0.2), (0.45, 0.15), (0.8, 0.0)], glass, 20,
                      (1.0, 0.85), root, loc=(0, 1.0, 0.24)))
    # wings (swept back) + accent stripes + tip tanks
    for s in (1, -1):
        side = "R" if s > 0 else "L"
        w = [(0.25, 0.9), (3.6, -1.1), (3.6, -1.75), (0.25, -1.3)]
        kids.append(slab("Wing_" + side, [(s * a, b) for a, b in w][::s], 0.07, "XY", hull, root, z=-0.03))
        st = [(1.4, 0.05), (3.2, -0.95), (3.2, -1.2), (1.4, -0.45)]
        kids.append(slab("WingStripe_" + side, [(s * a, b) for a, b in st][::s], 0.075, "XY", accent, root, bevel=0.008, z=-0.03))
        kids.append(lathe("TipTank_" + side,
                          [(-1.95, 0.02), (-1.7, 0.1), (-1.1, 0.13), (-0.6, 0.1), (-0.25, 0.02)], trim, 16,
                          parent=root, loc=(s * 3.62, 0, -0.03)))
        tail = [(0.2, -2.4), (1.6, -3.1), (1.6, -3.45), (0.2, -2.95)]
        kids.append(slab("Stabilizer_" + side, [(s * a, b) for a, b in tail][::s], 0.05, "XY", hull, root, z=0.0))
        eng = [(-2.7, 0.16), (-2.55, 0.21), (-1.9, 0.22), (-1.0, 0.2), (-0.55, 0.1), (-0.45, 0.02)]
        kids.append(lathe("Engine_" + side, eng, trim, 20, parent=root, loc=(s * 0.58, 0, -0.05)))
        kids.append(lathe("Exhaust_" + side, [(-2.77, 0.14), (-2.71, 0.14)], glow, 20,
                          parent=root, loc=(s * 0.58, 0, -0.05)))
    fin = [(-1.9, 0.25), (-2.75, 1.4), (-3.3, 1.4), (-3.05, 0.25)]
    kids.append(slab("Fin", fin, 0.06, "YZ", hull, root))
    fin_tip = [(-2.55, 1.05), (-2.75, 1.4), (-3.3, 1.4), (-3.18, 1.05)]
    kids.append(slab("FinStripe", fin_tip, 0.07, "YZ", accent, root, bevel=0.008))
    return root, kids

# ----------------------------------------------------------------- MANTA
L, WH, T0 = 10.0, 8.0, 0.9

def manta_planform(u, v):
    au = abs(u)
    yl = 0.5 * L - 0.66 * L * au ** 1.55
    yt = -0.5 * L + 0.34 * L * au ** 1.25
    return u * WH, yl + (yt - yl) * v

def manta_thick(u, v):
    au = abs(u)
    body = math.exp(-(u / 0.22) ** 2)
    t = T0 * (0.12 + 0.88 * body) * max(0.0, 1 - au ** 1.3)
    return t * math.sin(math.pi * v) ** 0.55

def manta_droop(u):
    return 0.10 * WH * abs(u) ** 2.2

BROWN_A = (0.31, 0.22, 0.21)
BROWN_B = (0.20, 0.15, 0.17)
PINK = (0.95, 0.50, 0.55)
PINK_HI = (1.00, 0.74, 0.70)
BELLY = (0.88, 0.76, 0.74)
BELLY_EDGE = (0.60, 0.43, 0.47)

def top_color(x, y):
    u = x / WH
    au = abs(u)
    yl = 0.5 * L - 0.66 * L * au ** 1.55
    d = yl - y
    n1 = noise.noise(Vector((x * 0.30, y * 0.30, 3.1))) * 0.5 + 0.5
    n2 = noise.noise(Vector((x * 0.9, y * 0.9, 7.7))) * 0.5 + 0.5
    n3 = noise.noise(Vector((x * 2.6, y * 2.6, 1.3))) * 0.5 + 0.5
    edge = (1 - smoothstep(0.0, 1.8, d)) * smoothstep(0.12, 0.4, au)
    tip = smoothstep(0.6, 0.95, au)
    m = max(edge, tip * 0.95) * (0.55 + 0.75 * n1)
    patch = smoothstep(0.58, 0.72, n2) * smoothstep(0.12, 0.5, au) * 0.9
    m = max(m, patch)
    base = mix(BROWN_A, BROWN_B, smoothstep(0.35, 0.65, n1))
    base = mix(base, (base[0] * 0.8, base[1] * 0.8, base[2] * 0.85), n3 * 0.5)
    pink = mix(PINK, PINK_HI, smoothstep(0.55, 0.9, n3))
    return lin(mix(base, pink, smoothstep(0.30, 0.72, m)))

def belly_color(x, y):
    au = abs(x / WH)
    n = noise.noise(Vector((x * 0.5, y * 0.5, 9.2))) * 0.5 + 0.5
    return lin(mix(mix(BELLY, BELLY_EDGE, smoothstep(0.35, 1.0, au)), (0.7, 0.55, 0.58), n * 0.25))

def manta_skin_material():
    m = bpy.data.materials.new("Manta_Skin")
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    b.inputs["Roughness"].default_value = 0.58
    try:
        b.inputs["Subsurface Weight"].default_value = 0.12
    except KeyError:
        pass
    col = nt.nodes.new("ShaderNodeVertexColor")
    col.layer_name = "Col"
    nt.links.new(col.outputs["Color"], b.inputs["Base Color"])
    noi = nt.nodes.new("ShaderNodeTexNoise")
    noi.inputs["Scale"].default_value = 38.0
    noi.inputs["Detail"].default_value = 6.0
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.18
    nt.links.new(noi.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], b.inputs["Normal"])
    return m

def build_manta():
    skin = manta_skin_material()
    fin_mat = new_mat("Manta_Fin", (0.86, 0.42, 0.48), rough=0.55)
    tail_mat = new_mat("Manta_Tail", (0.22, 0.16, 0.17), rough=0.6)
    eye_mat = new_mat("Manta_Eye", (0.02, 0.02, 0.03), rough=0.15)
    mouth_mat = new_mat("Manta_Mouth", (0.08, 0.04, 0.05), rough=0.7)

    nu, nv = 129, 65
    bm = bmesh.new()
    top = [[None] * nv for _ in range(nu)]
    bot = [[None] * nv for _ in range(nu)]
    for i in range(nu):
        u = -1 + 2 * i / (nu - 1)
        for j in range(nv):
            v = j / (nv - 1)
            if i in (0, nu - 1):  # wing tips collapse to one vertex
                if j == 0:
                    x, y = manta_planform(u, 0)
                    tip = bm.verts.new((x, y, manta_droop(u)))
                top[i][j] = bot[i][j] = tip
                continue
            x, y = manta_planform(u, v)
            t = manta_thick(u, v) if 0 < j < nv - 1 else 0.0
            dz = manta_droop(u)
            tv = bm.verts.new((x, y, dz + t))
            top[i][j] = tv
            bot[i][j] = tv if t == 0.0 else bm.verts.new((x, y, dz - t * 0.45))
    bm.verts.index_update()
    flags = {}

    def quad(vs, tag):
        seen, clean = set(), []
        for v in vs:
            if v.index in seen:
                continue
            seen.add(v.index)
            clean.append(v)
        if len(clean) < 3:
            return
        try:
            f = bm.faces.new(clean)
            flags[f] = tag
        except ValueError:
            pass

    for i in range(nu - 1):
        for j in range(nv - 1):
            quad([top[i][j], top[i + 1][j], top[i + 1][j + 1], top[i][j + 1]], "top")
            quad([bot[i][j + 1], bot[i + 1][j + 1], bot[i + 1][j], bot[i][j]], "bot")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
    layer = bm.loops.layers.float_color.new("Col")
    for f, tag in flags.items():
        if not f.is_valid:
            continue
        for l in f.loops:
            c = top_color(l.vert.co.x, l.vert.co.y) if tag == "top" else belly_color(l.vert.co.x, l.vert.co.y)
            l[layer] = (*c, 1.0)
    body = finish("MantaBody", bm, skin, True)
    ca = body.data.color_attributes
    ca.active_color = ca["Col"]
    ca.render_color_index = ca.active_color_index

    kids = [body]
    # tail
    pts, rad = [], []
    for k in range(28):
        t = k / 27
        pts.append((0.9 * math.sin(t * 4.5) * t, -4.4 - t * 15.0, -0.15 - 0.5 * t + 0.35 * math.sin(t * 3)))
        rad.append(0.34 * (1 - t) ** 1.3 + 0.025)
    kids.append(tube("Tail", pts, rad, tail_mat, 10, 0.8, body))
    # cephalic fins, eyes, mouth
    for s in (1, -1):
        side = "R" if s > 0 else "L"
        p = [(s * (0.9 - 0.25 * t), 4.5 + 2.4 * t, 0.05 + 0.6 * t * t) for t in [k / 9 for k in range(10)]]
        r = [0.46 * (1 - k / 9) ** 0.8 + 0.04 for k in range(10)]
        kids.append(tube("HeadFin_" + side, p, r, fin_mat, 10, 0.3, body))
        kids.append(sphere("Eye_" + side, 0.2, eye_mat, (s * 1.75, 4.15, 0.12), parent=body))
    kids.append(sphere("Mouth", 0.55, mouth_mat, (0, 4.55, -0.12), (1.5, 0.45, 0.14), parent=body))

    # flap shape keys + loop animation
    body.shape_key_add(name="Basis")
    for name, amt in (("FlapUp", 0.55), ("FlapDown", -0.42)):
        k = body.shape_key_add(name=name, from_mix=False)
        for d in k.data:
            u = d.co.x / WH
            d.co.z += amt * WH * abs(u) ** 2.0 * (1 - 0.15 * abs(u))
            d.co.y += -abs(amt) * 0.35 * abs(u) ** 2 * WH * 0.25
    sk = body.data.shape_keys
    for frame, up, down in [(1, 0, 0), (19, 1, 0), (37, 0, 0), (55, 0, 1), (73, 0, 0)]:
        sk.key_blocks["FlapUp"].value = up
        sk.key_blocks["FlapUp"].keyframe_insert("value", frame=frame)
        sk.key_blocks["FlapDown"].value = down
        sk.key_blocks["FlapDown"].keyframe_insert("value", frame=frame)
    sk.animation_data.action.name = "MantaFlap"
    sk.key_blocks["FlapUp"].value = 0
    sk.key_blocks["FlapDown"].value = 0
    bpy.context.scene.frame_start, bpy.context.scene.frame_end = 1, 73
    bpy.context.scene.render.fps = 24
    return body, kids

# ----------------------------------------------------------------- SCENE / RENDER
def setup_showcase_scene():
    sc = bpy.context.scene
    w = bpy.data.worlds.new("Dusk")
    w.use_nodes = True
    bg = w.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (*lin((0.95, 0.62, 0.45)), 1)
    bg.inputs["Strength"].default_value = 1.1
    sc.world = w
    sun = bpy.data.lights.new("Sun", "SUN")
    sun.energy = 4.5
    sun.color = (1.0, 0.82, 0.65)
    so = bpy.data.objects.new("Sun", sun)
    bpy.context.collection.objects.link(so)
    so.rotation_euler = (math.radians(55), math.radians(10), math.radians(-35))
    cam = bpy.data.cameras.new("Cam")
    cam.lens = 38
    co = bpy.data.objects.new("Camera", cam)
    bpy.context.collection.objects.link(co)
    co.location = (16, -30, 12)
    co.rotation_euler = (Vector((0, -3, 0)) - co.location).to_track_quat("-Z", "Y").to_euler()
    sc.camera = co

def render_preview(path):
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    sc.cycles.device = "CPU"
    sc.cycles.samples = 40
    try:
        sc.cycles.use_denoising = True
    except Exception:
        pass
    sc.render.resolution_x, sc.render.resolution_y = 1100, 650
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)

def main():
    clear()
    root, kids = build_plane()
    export_glb("plane", [root] + kids, animations=False, apply_mod=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, "plane.blend"))

    clear()
    body, kids = build_manta()
    export_glb("manta", kids, animations=True, apply_mod=False)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, "manta.blend"))

    clear()
    body, _ = build_manta()
    root, pk = build_plane()
    root.location = (-9.5, -6.5, -5.5)
    root.rotation_euler = (math.radians(-12), math.radians(8), math.radians(-28))
    root.scale = (1.4, 1.4, 1.4)
    setup_showcase_scene()
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(HERE, "showcase.blend"))
    render_preview(os.path.join(HERE, "preview.png"))

main()
