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

共通の部品は voxel_common.py。ほかのボクセルのキャラは build_rika.py と build_boru.py。
"""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

import voxel_common as vc
from voxel_common import OUT_DIR, PNG_SCALE, Part, blank, hex_rgb, make_color_material, make_texture_material, put

USDZ_PATH = os.path.join(OUT_DIR, "teacher.usdz")


# ---------------------------------------------------------------- 色

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


# ---------------------------------------------------------------- 組み立て

def build_character(mats):
    root = vc.add_root()

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
    vc.reset_scene()

    png_paths = {}
    for name, draw in FACES.items():
        path = os.path.join(OUT_DIR, name + ".png")
        vc.write_png(path, draw(), PNG_SCALE, FACE_PALETTE)
        png_paths[name] = path

    mats = {name: make_color_material(name, color) for name, color in COLORS.items()}
    mats["face_eyes_open"] = make_texture_material("face_eyes", png_paths["face_eyes_open"])
    mats["face_mouth_closed"] = make_texture_material("face_mouth", png_paths["face_mouth_closed"])

    build_character(mats)

    vc.export_usdz(USDZ_PATH)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        traceback.print_exc()
        sys.exit(1)
