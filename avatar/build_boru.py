"""少しずつ感情を覚えるロボ「ボル」のモデルを書き出すスクリプト（#124）。

使い方（リポジトリのルートで）:
    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python avatar/build_boru.py

出力:
    ios/HomeTeacher/Resources/Teacher/boru.usdz        モデル本体
    ios/HomeTeacher/Resources/Teacher/boru_*.png       実行時に差し替える顔テクスチャ（LED）
    avatar/boru.blend                                  元データ

キャラクターはこのプロジェクトのオリジナル。横長の箱の頭の前が暗い画面で、LED の目と口が出る。
アンテナ（Glasses パーツ）、横のつまみ、細いパイプの腕と大きな手、広い足、胸のハートのランプ、背中のねじ。
"""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

import voxel_common as vc
from voxel_common import OUT_DIR, ROOT, Part, blank, hex_rgb, put

PREFIX = "boru"

FACE_PALETTE = {
    ".": hex_rgb("#101C28"),  # 画面
    ",": hex_rgb("#0C1620"),  # 走査線
    "g": hex_rgb("#22384A"),  # 画面の映り込み
    "c": hex_rgb("#A8FFF2"),  # LED
    "C": hex_rgb("#FFFFFF"),  # LED の明るいところ
    "m": hex_rgb("#5FDCCB"),  # LED の暗いところ
    "p": hex_rgb("#FFB0C8"),  # ほっぺの LED（うれしいときだけ）
}

# 画面の上半分が目の板（10 x 4 ボクセル）、下半分が口の板（10 x 2.75 ボクセル）
EYES_W, EYES_H = 40, 16
MOUTH_W, MOUTH_H = 40, 11
EYE_CENTERS = (11, 29)


def screen(w, h):
    g = blank(w, h)
    for y in range(0, h, 2):
        for x in range(w):
            g[y][x] = ","
    return g


def eyes_screen():
    g = screen(EYES_W, EYES_H)
    # 左上の映り込み
    for i in range(5):
        put(g, 1 + i, 4 - i, "g")
        put(g, 2 + i, 4 - i, "g")
    return g


def eyes_open():
    # 角を落とした四角の目。上の角に明るいドット
    g = eyes_screen()
    for cx in EYE_CENTERS:
        for y in range(3, 13):
            for x in range(cx - 3, cx + 3):
                if (y in (3, 12)) and x in (cx - 3, cx + 2):
                    continue
                put(g, x, y, "m" if y % 3 == 0 else "c")
        for y in (4, 5):
            for x in (cx - 2, cx - 1):
                put(g, x, y, "C")
    return g


def eyes_closed():
    g = eyes_screen()
    for cx in EYE_CENTERS:
        for x in range(cx - 4, cx + 4):
            put(g, x, 8, "c")
            put(g, x, 9, "m")
    return g


def eyes_happy():
    # 山の形の目と、ほっぺの LED
    g = eyes_screen()
    for cx in EYE_CENTERS:
        for i in range(4):
            for t in (0, 1):
                put(g, cx - 4 + i, 9 - i + t, "c")
                put(g, cx + 3 - i, 9 - i + t, "c")
        for x in range(cx - 7, cx - 4) if cx < 20 else range(cx + 5, cx + 8):
            put(g, x, 13, "p")
            put(g, x, 14, "p")
    return g


def mouth_rect(x0, x1, y0, y1, inner="m"):
    g = screen(MOUTH_W, MOUTH_H)
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if x in (x0, x1) and y in (y0, y1):
                continue
            edge = x in (x0, x1) or y in (y0, y1)
            put(g, x, y, "c" if edge else inner)
    return g


def mouth_closed():
    # 階段のような、がんばって作った笑顔
    g = screen(MOUTH_W, MOUTH_H)
    for x in range(14, 26):
        put(g, x, 6, "c")
        put(g, x, 7, "c")
    for x, y in ((12, 5), (13, 5), (26, 5), (27, 5), (10, 4), (11, 4), (28, 4), (29, 4)):
        put(g, x, y, "c")
        put(g, x, y - 1, "c")
    return g


def mouth_n():
    g = screen(MOUTH_W, MOUTH_H)
    for x in range(16, 24):
        put(g, x, 5, "c")
        put(g, x, 6, "c")
    return g


def mouth_i():
    # 歯のように縦の線が入る、横に長い口
    g = mouth_rect(10, 29, 3, 7)
    for x in range(13, 28, 3):
        for y in range(4, 7):
            put(g, x, y, "C")
    return g


def mouth_a():
    g = mouth_rect(13, 26, 1, 9)
    for x in range(15, 25):
        put(g, x, 3, "C")
    return g


FACES = {
    "eyes_open": eyes_open,
    "eyes_closed": eyes_closed,
    "eyes_happy": eyes_happy,
    "mouth_closed": mouth_closed,
    "mouth_n": mouth_n,
    "mouth_a": mouth_a,
    "mouth_i": mouth_i,
    "mouth_u": lambda: mouth_rect(17, 22, 2, 8),
    "mouth_e": lambda: mouth_rect(12, 27, 2, 8),
    "mouth_o": lambda: mouth_rect(15, 24, 1, 9),
}


def build_surfaces(faces):
    s = vc.Surfaces()
    s.add("paint", "#E8733F", "paint", roughness=0.32, metallic=0.1)
    s.add("paint_dark", "#B9532A", "paint", roughness=0.4, metallic=0.1)
    s.add("cream", "#F4E7CC", "paint", roughness=0.42)
    s.add("steel", "#B4BDC4", "metal", roughness=0.32, metallic=1.0)
    s.add("gun", "#47525E", "metal", roughness=0.42, metallic=0.95)
    s.add("rubber", "#262B33", "skin", roughness=0.9)
    s.add("bolt", "#D6DCE0", "metal", roughness=0.28, metallic=1.0)
    s.add("seam", "#1E2228", roughness=0.9)
    s.add("cap", "#F4C542", "paint", roughness=0.35)
    s.add("heart", "#FF5F8F", roughness=0.25, glow=1.2)
    s.add("ball", "#FFD65C", roughness=0.25, glow=0.8)
    s.add("vent", "#2B323B", "metal", roughness=0.6, metallic=0.6)
    s.add_face("face_eyes", faces["eyes_open"], roughness=0.3, glow=1.0)   # アプリでは UnlitMaterial で見せる
    s.add_face("face_mouth", faces["mouth_closed"], roughness=0.3, glow=1.0)
    return s.mats


def bolts(part, points, y, mat="bolt", size=0.26):
    """正面のボルト。y は面の位置（前に少し出す）"""
    for x, z in points:
        part.box(x - size, x + size, y - 0.14, y, z - size, z + size, mat, chamfer=0.05)


def build_character(mats):
    root = vc.add_root()
    C = 0.07  # 金属と塗装のかどを落とす幅

    # 脚（原点は股関節）：蛇腹の細い足に、広くて重い足
    for name, sx in (("LegL", 1), ("LegR", -1)):
        leg = Part(name, surface_uv=True)
        leg.box(-0.65, 0.65, -0.65, 0.65, -2.8, 0.0, "steel", chamfer=C)
        for z in (-0.5, -1.2, -1.9):
            leg.box(-1.05, 1.05, -1.05, 1.05, z - 0.3, z, "rubber")
        leg.box(-1.4, 1.4, -1.4, 1.4, -2.9, -2.4, "gun", chamfer=C)
        # 足：段々に広がる
        leg.box(-2.1, 2.1, -3.0, 1.9, -3.8, -2.9, "paint", chamfer=C)
        leg.box(-2.4, 2.4, -3.7, 2.2, -4.5, -3.75, "paint", chamfer=C)
        leg.box(-2.5, 2.5, -3.8, 2.3, -5.0, -4.5, "gun", chamfer=C)
        for x in (-1.4, 1.4):
            leg.box(x - 0.26, x + 0.26, -3.86, -3.68, -4.35, -3.9, "bolt", chamfer=0.05)
        leg.build(mats, (2.6 * sx, 0, 5.0), root)

    # 胴（原点は腰）：まるみのある樽形で、前に明るいパネル
    body = Part("Body", surface_uv=True)
    body.box(-1.8, 1.8, -1.6, 1.6, -0.6, 0.6, "gun", chamfer=C)                 # 腰のつなぎ
    body.box(-3.3, 3.3, -2.2, 2.2, 0.0, 0.9, "paint_dark", chamfer=C)
    body.box(-4.3, 4.3, -2.9, 2.9, 0.8, 4.9, "paint", chamfer=C)
    body.box(-3.5, 3.5, -2.3, 2.3, 4.8, 5.7, "paint_dark", chamfer=C)
    body.box(-1.6, 1.6, -1.6, 1.6, 5.6, 6.0, "gun", chamfer=C)                  # 首のつけね
    # 継ぎ目
    body.box(-4.35, 4.35, -2.95, 2.95, 2.75, 2.87, "seam")
    # 前のパネル
    body.box(-3.1, 3.1, -3.05, -2.9, 1.1, 4.6, "cream", chamfer=0.05)
    bolts(body, [(-2.75, 1.45), (2.75, 1.45), (-2.75, 4.25), (2.75, 4.25)], -3.05)
    # 胸のハートのランプ（ふち + ハート）
    body.box(-1.35, 1.35, -3.12, -3.0, 2.3, 4.45, "gun")
    for x0, x1, z0, z1 in ((-0.9, 0.9, 3.0, 3.6), (-0.6, 0.6, 2.7, 3.0), (-0.3, 0.3, 2.45, 2.7), (-0.95, -0.15, 3.6, 4.05), (0.15, 0.95, 3.6, 4.05)):
        body.box(x0, x1, -3.24, -3.1, z0, z1, "heart")
    # 通風のすじ
    for z in (1.35, 1.75):
        body.box(-1.3, 1.3, -3.13, -3.03, z, z + 0.2, "vent")
    # 右の小さなボタン、左のメーター
    for i, m in enumerate(("cap", "heart", "steel")):
        body.box(-2.55, -1.85, -3.14, -3.03, 3.65 - i * 0.65, 4.15 - i * 0.65, m, chamfer=0.04)
    body.box(1.65, 2.6, -3.12, -3.03, 2.6, 4.1, "gun")
    for i, m in enumerate(("cap", "cap", "paint")):
        body.box(1.8, 2.45, -3.16, -3.1, 2.75 + i * 0.42, 3.0 + i * 0.42, m)
    # 横のボルト
    for sx in (-1, 1):
        for z in (1.3, 4.4):
            for y in (-2.1, 2.1):
                xa, xb = sorted((4.3 * sx, 4.44 * sx))
                body.box(xa, xb, y - 0.26, y + 0.26, z - 0.26, z + 0.26, "bolt", chamfer=0.05)
    # 背中：ふたと、ねじ
    body.box(-2.6, 2.6, 2.9, 3.05, 1.2, 4.5, "cream", chamfer=0.05)
    body.box(-0.45, 0.45, 3.0, 4.3, 2.5, 3.4, "steel", chamfer=C)
    body.box(-1.7, 1.7, 4.2, 4.7, 2.55, 3.35, "steel", chamfer=C)
    for sx in (-1, 1):
        xa, xb = sorted((1.0 * sx, 2.1 * sx))
        body.box(xa, xb, 4.2, 4.7, 2.2, 3.7, "steel", chamfer=C)
    body_obj = body.build(mats, (0, 0, 5.0), root)

    # 腕（原点は肩）：丸い肩、細いパイプ、大きな手
    for name, sx in (("ArmL", 1), ("ArmR", -1)):
        arm = Part(name, surface_uv=True)
        arm.rbox(-1.25, 1.25, -1.25, 1.25, -1.25, 1.25, "gun", r=0.35, chamfer=0.04)
        side = 1.25 * sx
        xa, xb = sorted((side, side + 0.15 * sx))
        arm.box(xa, xb, -0.5, 0.5, -0.5, 0.5, "bolt", chamfer=0.04)
        arm.box(-0.5, 0.5, -0.5, 0.5, -4.2, -1.1, "steel", chamfer=0.05)
        for z in (-1.9, -3.0):
            arm.box(-0.72, 0.72, -0.72, 0.72, z - 0.25, z, "gun", chamfer=0.04)
        arm.box(-1.05, 1.05, -1.05, 1.05, -4.5, -4.0, "gun", chamfer=C)         # 手首
        # 手：ミトンの形に、親指
        arm.rbox(-1.65, 1.65, -1.45, 1.45, -6.7, -4.4, "paint", r=0.35, chamfer=0.04)
        thumb = -1.65 * sx
        xa, xb = sorted((thumb, thumb - 0.7 * sx))
        arm.box(xa, xb, -0.65, 0.65, -5.9, -4.8, "paint_dark", chamfer=C)
        arm.box(-1.3, 1.3, -1.5, 1.5, -5.05, -4.92, "seam")
        arm.build(mats, (5.45 * sx, 0, 4.4), body_obj)

    # 頭（原点は首）：横長の箱。頭の方が体より大きい
    head = Part("Head", surface_uv=True)
    head.box(-1.0, 1.0, -1.0, 1.0, 0.0, 0.8, "steel", chamfer=C)
    head.box(-1.5, 1.5, -1.5, 1.5, 0.35, 0.65, "rubber")
    head.box(-6.7, 6.7, -4.0, 4.0, 1.4, 8.8, "paint", chamfer=C)
    head.box(-6.0, 6.0, -4.5, 4.5, 0.6, 9.5, "paint", chamfer=C)
    head.box(-6.0, 6.0, -4.5, 4.5, 0.6, 1.5, "paint_dark", chamfer=C)
    # 画面のふち
    head.box(-5.65, 5.65, -4.68, -4.45, 1.0, 9.05, "gun", chamfer=0.05)
    head.box(-5.25, 5.25, -4.74, -4.66, 1.45, 8.65, "seam")
    bolts(head, [(-5.3, 1.25), (5.3, 1.25), (-5.3, 8.82), (5.3, 8.82)], -4.68, size=0.2)
    # 頭の上のふた
    head.box(-3.6, 3.6, -2.6, 2.6, 9.5, 9.75, "paint_dark", chamfer=0.05)
    head.box(-6.0, 6.0, -0.1, 0.1, 9.45, 9.55, "seam")
    # 横のつまみ（耳のかわり）
    for sx in (-1, 1):
        for a, b, wy, wz, mat in ((6.7, 7.3, 1.75, 1.75, "gun"), (7.3, 8.05, 1.25, 1.25, "steel"), (8.05, 8.35, 0.8, 0.8, "cap")):
            xa, xb = sorted((a * sx, b * sx))
            head.box(xa, xb, -wy, wy, 5.0 - wz, 5.0 + wz, mat, chamfer=0.06)
        # 頭の横のボルト
        xa, xb = sorted((6.7 * sx, 6.82 * sx))
        for y in (-3.0, 3.0):
            for z in (2.4, 7.8):
                head.box(xa, xb, y - 0.24, y + 0.24, z - 0.24, z + 0.24, "bolt", chamfer=0.05)
    # 後ろ：放熱のすじ
    for z in (3.2, 4.2, 5.2, 6.2):
        head.box(-3.4, 3.4, 4.45, 4.62, z, z + 0.5, "vent")
    head_obj = head.build(mats, (0, 0, 6.0), body_obj)

    # 画面（テクスチャを差し替える）
    eyes = Part("Eyes")
    eyes.box(-5.0, 5.0, -4.78, -4.75, 4.4, 8.4, "face_eyes", front_uv=True)
    eyes.build(mats, (0, 0, 0), head_obj)

    mouth = Part("Mouth")
    mouth.box(-5.0, 5.0, -4.78, -4.75, 1.65, 4.4, "face_mouth", front_uv=True)
    mouth.build(mats, (0, 0, 0), head_obj)

    # アンテナ（Glasses）：根元、少し曲がった棒、光る玉
    antenna = Part("Glasses", surface_uv=True)
    antenna.box(-1.1, 1.1, -1.1, 1.1, 9.7, 10.2, "gun", chamfer=0.06)
    antenna.box(-0.3, 0.3, -0.3, 0.3, 10.2, 11.5, "steel", chamfer=0.05)
    antenna.box(-0.3, 0.9, -0.3, 0.3, 11.3, 11.85, "steel", chamfer=0.05)
    antenna.box(0.35, 0.9, -0.3, 0.3, 11.5, 12.8, "steel", chamfer=0.05)
    antenna.rbox(-0.3, 1.55, -0.92, 0.92, 12.7, 14.5, "ball", r=0.3)
    antenna.build(mats, (0, 0, 0), head_obj)

    return root


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    vc.reset_scene()
    faces = vc.write_faces(PREFIX, FACES, FACE_PALETTE)
    build_character(build_surfaces(faces))
    vc.report()
    vc.save_blend(os.path.join(ROOT, "avatar", f"{PREFIX}.blend"))
    vc.export_usdz(os.path.join(OUT_DIR, f"{PREFIX}.usdz"))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        traceback.print_exc()
        sys.exit(1)
