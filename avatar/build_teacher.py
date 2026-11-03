"""ボクセル風の先生モデルを組み立てて USDZ に書き出すスクリプト。

使い方（リポジトリのルートで）:
    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python avatar/build_teacher.py

出力:
    ios/HomeTeacher/Resources/Teacher/teacher.usdz   モデル本体（顔テクスチャも同梱）
    ios/HomeTeacher/Resources/Teacher/face_*.png     実行時に差し替える顔テクスチャ

キャラクターはこのプロジェクトのオリジナル（大学生くらいのお兄さん先生）。
頭が大きめの 3 頭身、メガネ、カーディガン、胸ポケットのペン。既存ゲームの見た目は使わない。

パーツの名前と原点（関節の位置）は Swift 側（AvatarView）との約束なので、変えるときは両方直す。
    Teacher            足元（ルート）
      LegL / LegR      股関節
      Body             腰
        ArmL / ArmR    肩
        Head           首
          Eyes         目のテクスチャを貼る板
          Mouth        口のテクスチャを貼る板
          Glasses      メガネ
左右はキャラクターから見た向き（L = キャラの左手側 = Blender の +X）。キャラは Blender の -Y 方向を向く。
"""

import os
import struct
import sys
import zlib

import bpy

# 1 ボクセルの大きさ（メートル）。全体で身長およそ 1.2m
VOXEL = 0.05

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT_DIR = os.path.join(ROOT, "ios", "HomeTeacher", "Resources", "Teacher")
USDZ_PATH = os.path.join(OUT_DIR, "teacher.usdz")

# テクスチャ 1 ボクセルあたりのピクセル数と、書き出し時の拡大率（ぼやけ防止に最近傍で拡大）
PX_PER_VOXEL = 4
PNG_SCALE = 16


# ---------------------------------------------------------------- 色

def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def srgb_to_linear(c):
    c = c / 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


COLORS = {
    "skin": "#F5CDA7",
    "hair": "#4A3226",
    "cardigan": "#7FB28A",
    "pocket": "#6A9A75",
    "shirt": "#FAF7F0",
    "pants": "#3D4A6B",
    "shoes": "#7A5236",
    "glasses": "#4B3B36",
    "button": "#C99A5B",
    "pen": "#D9534F",
}

# 顔テクスチャのパレット
FACE_PALETTE = {
    ".": hex_rgb(COLORS["skin"]),
    "k": hex_rgb("#2B211C"),  # 目・口の線
    "w": hex_rgb("#FFFFFF"),  # 目のハイライト・歯
    "p": hex_rgb("#F4A7A0"),  # ほっぺ
    "l": hex_rgb("#8B4A3C"),  # 閉じた口の線
    "r": hex_rgb("#7A2E2E"),  # 口の中
    "t": hex_rgb("#E98A86"),  # 舌
}


# ---------------------------------------------------------------- 顔テクスチャ（ドット絵）

EYES_W, EYES_H = 32, 12    # 目の板: 8 x 3 ボクセル
MOUTH_W, MOUTH_H = 16, 9   # 口の板: 4 x 2.25 ボクセル
EYE_CENTERS = (8, 24)      # 目の中心の列（メガネのレンズの中心に合わせる）


def blank(w, h):
    return [["."] * w for _ in range(h)]


def put(grid, x, y, c):
    if 0 <= y < len(grid) and 0 <= x < len(grid[0]):
        grid[y][x] = c


def add_blush(grid):
    for y in (9, 10):
        for x in list(range(1, 5)) + list(range(27, 31)):
            put(grid, x, y, "p")


def eyes_open():
    g = blank(EYES_W, EYES_H)
    for cx in EYE_CENTERS:
        # 縦長のまめ型の目 + 左上にハイライト
        for y in range(4, 8):
            put(g, cx - 1, y, "k")
            put(g, cx, y, "k")
        put(g, cx - 1, 4, "w")
    add_blush(g)
    return g


def eyes_closed():
    g = blank(EYES_W, EYES_H)
    for cx in EYE_CENTERS:
        # まばたき: 下向きの弧
        put(g, cx - 2, 5, "k")
        put(g, cx + 1, 5, "k")
        put(g, cx - 1, 6, "k")
        put(g, cx, 6, "k")
    add_blush(g)
    return g


def eyes_happy():
    g = blank(EYES_W, EYES_H)
    for cx in EYE_CENTERS:
        # にっこり: 上向きの弧
        put(g, cx - 1, 5, "k")
        put(g, cx, 5, "k")
        put(g, cx - 2, 6, "k")
        put(g, cx + 1, 6, "k")
    add_blush(g)
    return g


def open_mouth(x0, x1, y0, y1, teeth, tongue):
    """角を丸めた開いた口。外周を線、中を口の中の色で塗る。"""
    g = blank(MOUTH_W, MOUTH_H)
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            corner = (x in (x0, x1)) and (y in (y0, y1))
            if corner:
                continue
            edge = x in (x0, x1) or y in (y0, y1)
            put(g, x, y, "k" if edge else "r")
    if teeth:
        for x in range(x0 + 1, x1):
            put(g, x, y0 + 1, "w")
    if tongue and y1 - y0 >= 4:
        for x in range(x0 + 2, x1 - 1):
            put(g, x, y1 - 1, "t")
    return g


def mouth_closed():
    # ふだんの口: ゆるい笑顔
    g = blank(MOUTH_W, MOUTH_H)
    put(g, 4, 3, "l")
    put(g, 11, 3, "l")
    for x in range(5, 11):
        put(g, x, 4, "l")
    return g


def mouth_n():
    # 「ん」: きゅっと結んだ短い口
    g = blank(MOUTH_W, MOUTH_H)
    for x in range(6, 10):
        put(g, x, 4, "l")
    return g


FACES = {
    "face_eyes_open": eyes_open,
    "face_eyes_closed": eyes_closed,
    "face_eyes_happy": eyes_happy,
    "face_mouth_closed": mouth_closed,
    "face_mouth_n": mouth_n,
    "face_mouth_a": lambda: open_mouth(4, 11, 2, 7, teeth=True, tongue=True),
    "face_mouth_i": lambda: open_mouth(3, 12, 3, 5, teeth=True, tongue=False),
    "face_mouth_u": lambda: open_mouth(6, 9, 3, 6, teeth=False, tongue=False),
    "face_mouth_e": lambda: open_mouth(4, 11, 3, 6, teeth=True, tongue=False),
    "face_mouth_o": lambda: open_mouth(5, 10, 2, 7, teeth=False, tongue=True),
}


def write_png(path, grid, scale):
    """標準ライブラリだけで RGB の PNG を書く（最近傍で拡大）。"""
    rows = []
    for row in grid:
        line = bytearray()
        for c in row:
            line += bytes(FACE_PALETTE[c]) * scale
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


# ---------------------------------------------------------------- メッシュ

class Part:
    """箱（ボクセルの直方体）を集めて 1 つのメッシュにする。座標はボクセル単位で、原点が関節。"""

    def __init__(self, name):
        self.name = name
        self.verts = []
        self.faces = []
        self.face_mats = []
        self.face_uvs = []
        self.materials = []

    def box(self, x0, x1, y0, y1, z0, z1, mat, front_uv=False):
        if mat not in self.materials:
            self.materials.append(mat)
        mi = self.materials.index(mat)
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
        for q, is_front in quads:
            self.faces.append(tuple(b + i for i in q))
            self.face_mats.append(mi)
            if front_uv and is_front:
                self.face_uvs.append([(0, 0), (1, 0), (1, 1), (0, 1)])
            else:
                # 正面以外は左下の肌色のピクセルを使う
                self.face_uvs.append([(0.01, 0.01)] * 4)

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


# ---------------------------------------------------------------- 組み立て

def build_character(mats):
    root = bpy.data.objects.new("Teacher", None)
    bpy.context.scene.collection.objects.link(root)

    # 脚（原点は股関節。足元から 5 ボクセル）
    for name, sx in (("LegL", 1), ("LegR", -1)):
        leg = Part(name)
        leg.box(-1.6, 1.6, -1.7, 1.7, -4.0, 0.0, "pants")
        leg.box(-1.7, 1.7, -2.3, 1.7, -5.0, -4.0, "shoes")
        leg.build(mats, (1.8 * sx, 0, 5.0), root)

    # 胴体（原点は腰）
    body = Part("Body")
    body.box(-4.0, 4.0, -2.5, 2.5, 0.0, 7.0, "cardigan")
    # 前を開けたカーディガンからのぞくシャツと襟
    body.box(-1.2, 1.2, -2.65, -2.5, 3.4, 7.0, "shirt")
    body.box(-1.9, -0.2, -2.8, -2.5, 6.3, 7.0, "shirt")
    body.box(0.2, 1.9, -2.8, -2.5, 6.3, 7.0, "shirt")
    # ボタン
    for z in (1.0, 2.3):
        body.box(-0.3, 0.3, -2.7, -2.5, z, z + 0.6, "button")
    # 胸ポケットとペン（先生らしさ）
    body.box(1.6, 3.3, -2.65, -2.5, 3.8, 5.1, "pocket")
    body.box(2.0, 2.35, -2.8, -2.6, 4.6, 5.8, "pen")
    body_obj = body.build(mats, (0, 0, 5.0), root)

    # 腕（原点は肩）
    for name, sx in (("ArmL", 1), ("ArmR", -1)):
        arm = Part(name)
        arm.box(-1.4, 1.4, -1.4, 1.4, -5.0, 0.4, "cardigan")
        arm.box(-1.2, 1.2, -1.2, 1.2, -6.3, -5.0, "skin")
        arm.build(mats, (5.45 * sx, 0, 6.6), body_obj)

    # 頭（原点は首）。体より大きい頭でやわらかい印象に
    head = Part("Head")
    head.box(-1.5, 1.5, -1.5, 1.5, 0.0, 0.6, "skin")          # 首
    head.box(-5.5, 5.5, -5.0, 5.0, 0.5, 10.5, "skin")         # 頭
    head.box(-6.0, -5.5, -0.8, 0.8, 3.8, 5.6, "skin")         # 耳
    head.box(5.5, 6.0, -0.8, 0.8, 3.8, 5.6, "skin")
    # 髪: 上・後ろ・横
    head.box(-5.8, 5.8, -5.3, 5.8, 8.6, 11.2, "hair")
    head.box(-5.8, 5.8, 3.6, 5.8, 3.0, 8.6, "hair")
    head.box(-5.8, -5.5, 1.0, 3.6, 5.6, 8.6, "hair")
    head.box(5.5, 5.8, 1.0, 3.6, 5.6, 8.6, "hair")
    # 前髪（左右非対称に流す）
    head.box(-5.8, -1.4, -5.4, -5.0, 7.2, 8.6, "hair")
    head.box(-1.4, 1.2, -5.4, -5.0, 7.7, 8.6, "hair")
    head.box(3.4, 5.8, -5.4, -5.0, 7.4, 8.6, "hair")
    # アホ毛
    head.box(0.2, 1.2, -1.0, 0.0, 11.2, 12.3, "hair")
    head.box(1.0, 1.9, -1.0, 0.0, 12.0, 12.8, "hair")
    head_obj = head.build(mats, (0, 0, 7.0), body_obj)

    # 顔の板（テクスチャを差し替える）。頭の正面より少しだけ前に出す
    eyes = Part("Eyes")
    eyes.box(-4.0, 4.0, -5.03, -5.0, 3.6, 6.6, "face_eyes_open", front_uv=True)
    eyes.build(mats, (0, 0, 0), head_obj)

    mouth = Part("Mouth")
    mouth.box(-2.0, 2.0, -5.03, -5.0, 1.4, 3.65, "face_mouth_closed", front_uv=True)
    mouth.build(mats, (0, 0, 0), head_obj)

    # メガネ（レンズの枠 + ブリッジ + つる）
    glasses = Part("Glasses")
    t = 0.3
    y0, y1 = -5.5, -5.2
    for cx in (-2.0, 2.0):
        x0, x1, z0, z1 = cx - 1.7, cx + 1.7, 3.75, 6.45
        glasses.box(x0, x1, y0, y1, z1 - t, z1, "glasses")
        glasses.box(x0, x1, y0, y1, z0, z0 + t, "glasses")
        glasses.box(x0, x0 + t, y0, y1, z0, z1, "glasses")
        glasses.box(x1 - t, x1, y0, y1, z0, z1, "glasses")
    glasses.box(-0.3, 0.3, y0, y1, 5.6, 5.9, "glasses")
    for sx in (-1, 1):
        xa, xb = sorted((3.7 * sx, 5.75 * sx))
        glasses.box(xa, xb, y0, y1, 5.85, 6.15, "glasses")
        xa, xb = sorted((5.5 * sx, 5.75 * sx))
        glasses.box(xa, xb, y0, 1.0, 5.85, 6.15, "glasses")
    glasses.build(mats, (0, 0, 0), head_obj)

    return root


def main():
    os.makedirs(OUT_DIR, exist_ok=True)

    # 既定シーンを空にする
    bpy.ops.wm.read_factory_settings(use_empty=True)

    png_paths = {}
    for name, draw in FACES.items():
        path = os.path.join(OUT_DIR, name + ".png")
        write_png(path, draw(), PNG_SCALE)
        png_paths[name] = path

    mats = {name: make_color_material(name, color) for name, color in COLORS.items()}
    mats["face_eyes_open"] = make_texture_material("face_eyes", png_paths["face_eyes_open"])
    mats["face_mouth_closed"] = make_texture_material("face_mouth", png_paths["face_mouth_closed"])

    build_character(mats)

    bpy.ops.wm.usd_export(
        filepath=USDZ_PATH,
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
    print("書き出し:", USDZ_PATH)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        traceback.print_exc()
        sys.exit(1)
