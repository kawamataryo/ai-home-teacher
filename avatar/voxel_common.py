"""ボクセルのキャラを Blender で組み立てて USDZ に書き出すための共通部品（#124）。

キャラごとのスクリプト（`build_teacher.py` `build_rika.py` `build_boru.py`）が使う。

骨組みはどのキャラも同じで、パーツの名前と原点（関節の位置）は Swift 側（`TeacherPart`）との約束。
    Teacher            足元（ルート）
      LegL / LegR      股関節
      Body             腰
        ArmL / ArmR    肩
        Head           首
          Eyes         目のテクスチャを貼る板
          Mouth        口のテクスチャを貼る板
          Glasses      小物（メガネ、ゴーグル、アンテナ）。癖で少し動く
左右はキャラクターから見た向き（L = キャラの左手側 = Blender の +X）。キャラは Blender の -Y 方向を向く。

リソースは平らにバンドルされるので、ファイルの名前は全キャラで一意にする。
"""

import os
import random
import struct
import tempfile
import zlib

import bpy

# 1 ボクセルの大きさ（メートル）。全体で身長およそ 1.2m
VOXEL = 0.05

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT_DIR = os.path.join(ROOT, "ios", "HomeTeacher", "Resources", "Teacher")

# テクスチャ 1 ボクセルあたりのピクセル数と、書き出し時の拡大率（ぼやけ防止に最近傍で拡大）
PX_PER_VOXEL = 4
PNG_SCALE = 16

# 質感のテクスチャ。1 ボクセルに 2 マス、全体で 32 ボクセルぶん。マスを最近傍で拡大する
GRAIN_CELLS_PER_VOXEL = 2
GRAIN_CELLS = 64
GRAIN_SCALE = 4
GRAIN_VOXELS = GRAIN_CELLS / GRAIN_CELLS_PER_VOXEL


# ---------------------------------------------------------------- 色

def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def srgb_to_linear(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def linear_rgba(hex_color):
    r, g, b = (srgb_to_linear(c) for c in hex_rgb(hex_color))
    return (r, g, b, 1.0)


# ---------------------------------------------------------------- 画像

def blank(w, h, fill="."):
    return [[fill] * w for _ in range(h)]


def put(grid, x, y, c):
    if 0 <= y < len(grid) and 0 <= x < len(grid[0]):
        grid[y][x] = c


def write_png(path, grid, scale, palette):
    """標準ライブラリだけで RGB の PNG を書く（最近傍で拡大）。"""
    rows = []
    for row in grid:
        line = bytearray()
        for c in row:
            line += bytes(palette[c]) * scale
        for _ in range(scale):
            rows.append(b"\x00" + bytes(line))
    raw = b"".join(rows)
    w, h = len(grid[0]) * scale, len(grid) * scale

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def write_faces(prefix, faces, palette, out_dir=OUT_DIR):
    """顔のテクスチャを書き出す。`faces` は「eyes_open」→ ドット絵の関数。戻り値は名前 → パス"""
    paths = {}
    for name, draw in faces.items():
        path = os.path.join(out_dir, f"{prefix}_{name}.png")
        write_png(path, draw(), PNG_SCALE, palette)
        paths[name] = path
    return paths


def _shade(rgb, k):
    return tuple(max(0, min(255, int(round(c * k)))) for c in rgb)


def grain_png(path, kind, hex_color):
    """布、毛、塗装、金属の違いを出す、ピクセルのむらのあるテクスチャを書く。

    手続き型のシェーダーは USD に出ないので、Python で画像にする。
    """
    rng = random.Random(f"{kind}:{hex_color}")
    base = hex_rgb(hex_color)
    n = GRAIN_CELLS
    columns = [rng.uniform(-1, 1) for _ in range(n)]
    lines = [rng.uniform(-1, 1) for _ in range(n)]
    grid = []
    for y in range(n):
        row = []
        for x in range(n):
            r = rng.uniform(-1, 1)
            if kind == "cloth":      # 綾織りの斜めの線
                k = 1 + (-0.016 if (x + y) % 4 == 0 else 0.004) + 0.008 * r
            elif kind == "hair":     # 毛の流れ（縦のすじ）
                k = 1 + 0.10 * columns[x] + 0.025 * r
            elif kind == "paint":    # 塗装：ほぼ平らで、ときどき小さな傷
                k = 1 + 0.012 * r
                if rng.random() < 0.006:
                    k = 0.82
            elif kind == "metal":    # 金属：横のヘアライン
                k = 1 + 0.055 * lines[y] + 0.02 * r
                if rng.random() < 0.004:
                    k = 1.2
            else:                    # 肌、ゴムなど
                k = 1 + 0.015 * r
            row.append(_shade(base, k))
        grid.append(row)
    write_png(path, grid, GRAIN_SCALE, {c: c for line in grid for c in line})


# ---------------------------------------------------------------- メッシュ

class Part:
    """箱（ボクセルの直方体）を集めて 1 つのメッシュにする。座標はボクセル単位で、原点が関節。

    `surface_uv=True` のパーツは、面ごとに質感のテクスチャの一部を貼る（`grain_png` 用）。
    False なら正面以外は UV の 1 点だけを使う（今の先生）。
    """

    def __init__(self, name, surface_uv=False):
        self.name = name
        self.verts = []
        self.faces = []
        self.face_mats = []
        self.face_uvs = []
        self.materials = []
        self.surface_uv = surface_uv
        self.rng = random.Random(name)

    def _material_index(self, mat):
        if mat not in self.materials:
            self.materials.append(mat)
        return self.materials.index(mat)

    def box(self, x0, x1, y0, y1, z0, z1, mat, front_uv=False, chamfer=0.0):
        """箱を足す。`chamfer` はかどを落とす幅（ボクセル）。金属の縁に光が乗る"""
        if chamfer > 0:
            self._chamfered_box(x0, x1, y0, y1, z0, z1, mat, chamfer)
            return
        mi = self._material_index(mat)
        b = len(self.verts)
        for z in (z0, z1):
            for y in (y0, y1):
                for x in (x0, x1):
                    self.verts.append((x * VOXEL, y * VOXEL, z * VOXEL))
        # 頂点番号: x + 2y + 4z
        quads = [
            ((0, 1, 5, 4), True),    # -Y（正面）
            ((3, 2, 6, 7), False),   # +Y
            ((2, 0, 4, 6), False),   # -X
            ((1, 3, 7, 5), False),   # +X
            ((2, 3, 1, 0), False),   # 下
            ((4, 5, 7, 6), False),   # 上
        ]
        offset = self._grain_offset(x0, x1, y0, y1, z0, z1)
        for q, is_front in quads:
            self.faces.append(tuple(b + i for i in q))
            self.face_mats.append(mi)
            if front_uv and is_front:
                self.face_uvs.append([(0, 0), (1, 0), (1, 1), (0, 1)])
            elif self.surface_uv:
                self.face_uvs.append(self._surface_uvs(q, b, offset))
            else:
                # 正面以外は左下の肌色のピクセルを使う
                self.face_uvs.append([(0.01, 0.01)] * 4)

    def rbox(self, x0, x1, y0, y1, z0, z1, mat, r=0.5, chamfer=0.0):
        """かどを 1 段落とした箱。3 つの箱を十字に重ねて、丸みのある形にする"""
        self.box(x0 + r, x1 - r, y0 + r, y1 - r, z0, z1, mat, chamfer=chamfer)
        self.box(x0, x1, y0 + r, y1 - r, z0 + r, z1 - r, mat, chamfer=chamfer)
        self.box(x0 + r, x1 - r, y0, y1, z0 + r, z1 - r, mat, chamfer=chamfer)

    def _chamfered_box(self, x0, x1, y0, y1, z0, z1, mat, c):
        mi = self._material_index(mat)
        b = len(self.verts)
        xs, ys, zs = (x0, x1), (y0, y1), (z0, z1)
        inset = lambda v, side: v + c if side == 0 else v - c

        def index(ix, iy, iz, axis):
            # 1 つのかどに 3 頂点。axis は「その軸だけ端にある」頂点
            return b + (ix + 2 * iy + 4 * iz) * 3 + axis

        for iz in (0, 1):
            for iy in (0, 1):
                for ix in (0, 1):
                    x, y, z = xs[ix], ys[iy], zs[iz]
                    self.verts.append((x * VOXEL, inset(y, iy) * VOXEL, inset(z, iz) * VOXEL))
                    self.verts.append((inset(x, ix) * VOXEL, y * VOXEL, inset(z, iz) * VOXEL))
                    self.verts.append((inset(x, ix) * VOXEL, inset(y, iy) * VOXEL, z * VOXEL))

        faces = [
            # 6 面
            (index(0, 0, 0, 1), index(1, 0, 0, 1), index(1, 0, 1, 1), index(0, 0, 1, 1)),
            (index(1, 1, 0, 1), index(0, 1, 0, 1), index(0, 1, 1, 1), index(1, 1, 1, 1)),
            (index(0, 1, 0, 0), index(0, 0, 0, 0), index(0, 0, 1, 0), index(0, 1, 1, 0)),
            (index(1, 0, 0, 0), index(1, 1, 0, 0), index(1, 1, 1, 0), index(1, 0, 1, 0)),
            (index(0, 1, 0, 2), index(1, 1, 0, 2), index(1, 0, 0, 2), index(0, 0, 0, 2)),
            (index(0, 0, 1, 2), index(1, 0, 1, 2), index(1, 1, 1, 2), index(0, 1, 1, 2)),
            # x に平行な 4 辺
            (index(0, 0, 0, 2), index(1, 0, 0, 2), index(1, 0, 0, 1), index(0, 0, 0, 1)),
            (index(0, 0, 1, 1), index(1, 0, 1, 1), index(1, 0, 1, 2), index(0, 0, 1, 2)),
            (index(1, 1, 0, 2), index(0, 1, 0, 2), index(0, 1, 0, 1), index(1, 1, 0, 1)),
            (index(1, 1, 1, 1), index(0, 1, 1, 1), index(0, 1, 1, 2), index(1, 1, 1, 2)),
            # y に平行な 4 辺
            (index(0, 1, 0, 2), index(0, 0, 0, 2), index(0, 0, 0, 0), index(0, 1, 0, 0)),
            (index(0, 1, 1, 0), index(0, 0, 1, 0), index(0, 0, 1, 2), index(0, 1, 1, 2)),
            (index(1, 0, 0, 2), index(1, 1, 0, 2), index(1, 1, 0, 0), index(1, 0, 0, 0)),
            (index(1, 0, 1, 0), index(1, 1, 1, 0), index(1, 1, 1, 2), index(1, 0, 1, 2)),
            # z に平行な 4 辺
            (index(0, 0, 0, 0), index(0, 0, 0, 1), index(0, 0, 1, 1), index(0, 0, 1, 0)),
            (index(1, 0, 0, 1), index(1, 0, 0, 0), index(1, 0, 1, 0), index(1, 0, 1, 1)),
            (index(1, 1, 0, 0), index(1, 1, 0, 1), index(1, 1, 1, 1), index(1, 1, 1, 0)),
            (index(0, 1, 0, 1), index(0, 1, 0, 0), index(0, 1, 1, 0), index(0, 1, 1, 1)),
            # 8 つのかど
            (index(0, 0, 0, 0), index(0, 0, 0, 2), index(0, 0, 0, 1)),
            (index(1, 0, 0, 1), index(1, 0, 0, 2), index(1, 0, 0, 0)),
            (index(0, 1, 0, 1), index(0, 1, 0, 2), index(0, 1, 0, 0)),
            (index(1, 1, 0, 0), index(1, 1, 0, 2), index(1, 1, 0, 1)),
            (index(0, 0, 1, 1), index(0, 0, 1, 2), index(0, 0, 1, 0)),
            (index(1, 0, 1, 0), index(1, 0, 1, 2), index(1, 0, 1, 1)),
            (index(0, 1, 1, 0), index(0, 1, 1, 2), index(0, 1, 1, 1)),
            (index(1, 1, 1, 1), index(1, 1, 1, 2), index(1, 1, 1, 0)),
        ]
        offset = self._grain_offset(x0, x1, y0, y1, z0, z1)
        for face in faces:
            self.faces.append(face)
            self.face_mats.append(mi)
            self.face_uvs.append(self._planar_uvs([self.verts[i] for i in face], offset))

    def _grain_offset(self, x0, x1, y0, y1, z0, z1):
        """テクスチャのどこを貼るか。箱ごとに変えて、同じ模様が並ばないようにする"""
        size = max(x1 - x0, y1 - y0, z1 - z0)
        room = max(0.0, GRAIN_VOXELS - size - 1)
        return (self.rng.uniform(0, room), self.rng.uniform(0, room), (x0, y0, z0))

    def _surface_uvs(self, quad, base, offset):
        return self._planar_uvs([self.verts[base + i] for i in quad], offset)

    @staticmethod
    def _planar_uvs(points, offset):
        # 面の向きで投影する軸を決める
        ax, ay, az = points[1][0] - points[0][0], points[1][1] - points[0][1], points[1][2] - points[0][2]
        bx, by, bz = points[-1][0] - points[0][0], points[-1][1] - points[0][1], points[-1][2] - points[0][2]
        normal = (abs(ay * bz - az * by), abs(az * bx - ax * bz), abs(ax * by - ay * bx))
        drop = normal.index(max(normal))
        axes = [a for a in (0, 1, 2) if a != drop]
        off_u, off_v, origin = offset
        uvs = []
        for p in points:
            u = (p[axes[0]] / VOXEL - origin[axes[0]] + off_u) / GRAIN_VOXELS
            v = (p[axes[1]] / VOXEL - origin[axes[1]] + off_v) / GRAIN_VOXELS
            uvs.append((u, v))
        return uvs

    def build(self, mats, location, parent=None):
        mesh = bpy.data.meshes.new(self.name + "Mesh")
        mesh.from_pydata(self.verts, [], self.faces)
        uv = mesh.uv_layers.new(name="st")
        for poly, uvs in zip(mesh.polygons, self.face_uvs):
            poly.material_index = self.face_mats[poly.index]
            poly.use_smooth = False
            for li, loop_index in enumerate(poly.loop_indices):
                uv.data[loop_index].uv = uvs[li]
        for m in self.materials:
            mesh.materials.append(mats[m])
        mesh.update()
        obj = bpy.data.objects.new(self.name, mesh)
        bpy.context.scene.collection.objects.link(obj)
        obj.location = tuple(v * VOXEL for v in location)
        if parent is not None:
            obj.parent = parent
        return obj


def add_root():
    root = bpy.data.objects.new("Teacher", None)
    bpy.context.scene.collection.objects.link(root)
    return root


# ---------------------------------------------------------------- マテリアル

def make_color_material(name, hex_color):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    r, g, b = (srgb_to_linear(c) for c in hex_rgb(hex_color))
    bsdf.inputs["Base Color"].default_value = (r, g, b, 1.0)
    bsdf.inputs["Roughness"].default_value = 0.85
    return mat


def make_texture_material(name, png_path):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    bsdf = nodes.get("Principled BSDF")
    bsdf.inputs["Roughness"].default_value = 0.9
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(png_path)
    tex.interpolation = "Closest"
    mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


class Surfaces:
    """キャラの質感をまとめて作る。質感のテクスチャは usdz と .blend に入るので、作業用の場所に書く"""

    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="voxel_grain_")
        self.mats = {}

    def add(self, name, hex_color, kind="plain", roughness=0.85, metallic=0.0, alpha=1.0, glow=0.0):
        """`kind`：cloth / hair / paint / metal / skin（質感のテクスチャ）か plain（単色）。`glow` は自分で光る強さ"""
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
        nodes = mat.node_tree.nodes
        bsdf = nodes.get("Principled BSDF")
        bsdf.inputs["Base Color"].default_value = linear_rgba(hex_color)
        bsdf.inputs["Roughness"].default_value = roughness
        bsdf.inputs["Metallic"].default_value = metallic
        if alpha < 1:
            # 透明は、値を入れただけでは USD に出ない（opacity = 1 になる）。アルファのある画像をつなぐ
            path = os.path.join(self.dir, f"{name}.png")
            image = bpy.data.images.new(name, 4, 4, alpha=True)
            image.pixels = [*linear_rgba(hex_color)[:3], alpha] * 16
            image.filepath_raw = path
            image.file_format = "PNG"
            image.save()
            tex = nodes.new("ShaderNodeTexImage")
            tex.image = image
            mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
            mat.node_tree.links.new(tex.outputs["Alpha"], bsdf.inputs["Alpha"])
        if glow > 0:
            bsdf.inputs["Emission Color"].default_value = linear_rgba(hex_color)
            bsdf.inputs["Emission Strength"].default_value = glow
        if kind != "plain":
            path = os.path.join(self.dir, f"{name}.png")
            grain_png(path, kind, hex_color)
            tex = nodes.new("ShaderNodeTexImage")
            tex.image = bpy.data.images.load(path)
            tex.interpolation = "Closest"
            tex.extension = "CLIP"
            mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        self.mats[name] = mat
        return mat

    def add_face(self, name, png_path, roughness=0.9, glow=0.0):
        mat = make_texture_material(name, png_path)
        bsdf = mat.node_tree.nodes.get("Principled BSDF")
        bsdf.inputs["Roughness"].default_value = roughness
        if glow > 0:
            tex = next(n for n in mat.node_tree.nodes if n.type == "TEX_IMAGE")
            mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Emission Color"])
            bsdf.inputs["Emission Strength"].default_value = glow
        self.mats[name] = mat
        return mat


# ---------------------------------------------------------------- 書き出し

def reset_scene():
    """既定シーンを空にする"""
    bpy.ops.wm.read_factory_settings(use_empty=True)


def export_usdz(path):
    bpy.ops.wm.usd_export(
        filepath=path,
        export_animation=False,
        export_materials=True,
        export_uvmaps=True,
        generate_preview_surface=True,
        export_textures_mode="NEW",
        overwrite_textures=True,
        convert_orientation=True,
        export_global_forward_selection="NEGATIVE_Z",
        export_global_up_selection="Y",
        export_lights=False,
        export_cameras=False,
        root_prim_path="",
    )
    print("書き出し:", path)


def save_blend(path):
    """元データを保存する。テクスチャも中に入れるので、この 1 つで開ける"""
    bpy.ops.file.pack_all()
    bpy.ops.file.pack_all()  # 画像も .blend に入れる（textures はコミットしないので、clone 直後でも質感が欠けないように）
    bpy.ops.wm.save_as_mainfile(filepath=path, compress=True)
    print("保存:", path)


def report(root_name="Teacher"):
    """面数を出す（PR に書く）"""
    triangles = 0
    for obj in bpy.data.objects:
        if obj.type == "MESH":
            obj.data.calc_loop_triangles()
            triangles += len(obj.data.loop_triangles)
    print("三角形:", triangles)
