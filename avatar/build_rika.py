"""理系のお姉さん先生「リカ」のモデルを書き出すスクリプト（#124）。

使い方（リポジトリのルートで）:
    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python avatar/build_rika.py

出力:
    ios/HomeTeacher/Resources/Teacher/rika.usdz        モデル本体
    ios/HomeTeacher/Resources/Teacher/rika_*.png       実行時に差し替える顔テクスチャ
    avatar/rika.blend                                  元データ

キャラクターはこのプロジェクトのオリジナル。すそが広がった白衣、おでこに上げた大きな実験ゴーグル（Glasses パーツ）、
大きく結んだ横の髪、ポケットの試験管とフラスコ。髪にさしたまま探しているペン。
"""

import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

import voxel_common as vc
from voxel_common import OUT_DIR, ROOT, Part, blank, hex_rgb, put

PREFIX = "rika"
SKIN = "#F8D5B5"

FACE_PALETTE = {
    ".": hex_rgb(SKIN),
    "k": hex_rgb("#2A2238"),  # 目の線、まつげ
    "i": hex_rgb("#2F8C8C"),  # ひとみ（ゴーグルのレンズと同じ系統の色）
    "d": hex_rgb("#1F4F5C"),  # ひとみの上の暗いところ
    "w": hex_rgb("#FFFFFF"),  # 目の光
    "p": hex_rgb("#F6A9A0"),  # ほっぺ
    "b": hex_rgb("#4A3B6B"),  # まゆ（髪の色）
    "l": hex_rgb("#A8483F"),  # 口の線
    "r": hex_rgb("#7E2A35"),  # 口の中
    "t": hex_rgb("#EE8C88"),  # 舌
}

# 目の板は 9 x 3.5 ボクセル、口の板は 4 x 2.25 ボクセル（1 ボクセル 4 ピクセル）
EYES_W, EYES_H = 36, 14
MOUTH_W, MOUTH_H = 16, 9
EYE_CENTERS = (9, 26)


def add_blush(g):
    for y in (11, 12):
        for x in list(range(1, 6)) + list(range(30, 35)):
            put(g, x, y, "p")


def add_brows(g):
    for cx in EYE_CENTERS:
        for x in range(cx - 2, cx + 3):
            put(g, x, 0, "b")


def eyes_open():
    # 大きな目に光を 2 つ。ふしぎなことに目を輝かせる
    g = blank(EYES_W, EYES_H)
    add_brows(g)
    for cx in EYE_CENTERS:
        for x in range(cx - 3, cx + 4):      # まつげ
            put(g, x, 2, "k")
        outer = cx - 4 if cx < 18 else cx + 4
        put(g, outer, 3, "k")
        for y in range(3, 10):
            for x in range(cx - 2, cx + 3):
                put(g, x, y, "d" if y < 5 else "i")
        for x in range(cx - 1, cx + 2):      # 下の丸み
            put(g, x, 10, "k")
        put(g, cx - 3, 4, "k")
        put(g, cx + 3, 4, "k")
        put(g, cx - 1, 4, "w")
        put(g, cx - 2, 4, "w")
        put(g, cx - 1, 5, "w")
        put(g, cx - 2, 5, "w")
        put(g, cx + 1, 8, "w")
    add_blush(g)
    return g


def eyes_closed():
    g = blank(EYES_W, EYES_H)
    add_brows(g)
    for cx in EYE_CENTERS:
        for x in range(cx - 3, cx + 4):
            put(g, x, 7, "k")
        put(g, cx - 4, 6, "k")
        put(g, cx + 4, 6, "k")
        outer = cx - 5 if cx < 18 else cx + 5
        put(g, outer, 5, "k")
    add_blush(g)
    return g


def eyes_happy():
    g = blank(EYES_W, EYES_H)
    add_brows(g)
    for cx in EYE_CENTERS:
        for x in range(cx - 2, cx + 3):
            put(g, x, 5, "k")
            put(g, x, 4, "k")
        put(g, cx - 3, 6, "k")
        put(g, cx + 3, 6, "k")
        put(g, cx - 4, 7, "k")
        put(g, cx + 4, 7, "k")
    add_blush(g)
    return g


def open_mouth(x0, x1, y0, y1, teeth=False, tongue=False):
    g = blank(MOUTH_W, MOUTH_H)
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if x in (x0, x1) and y in (y0, y1):
                continue
            put(g, x, y, "k" if x in (x0, x1) or y in (y0, y1) else "r")
    if teeth:
        for x in range(x0 + 1, x1):
            put(g, x, y0 + 1, "w")
    if tongue and y1 - y0 >= 4:
        for x in range(x0 + 2, x1 - 1):
            put(g, x, y1 - 1, "t")
    return g


def mouth_closed():
    # 少しだけ片方の口角が上がった、おもしろがっている口
    g = blank(MOUTH_W, MOUTH_H)
    for x in range(5, 11):
        put(g, x, 5, "l")
    put(g, 4, 4, "l")
    put(g, 11, 4, "l")
    put(g, 12, 3, "l")
    return g


def mouth_n():
    g = blank(MOUTH_W, MOUTH_H)
    for x in range(6, 10):
        put(g, x, 5, "l")
    return g


FACES = {
    "eyes_open": eyes_open,
    "eyes_closed": eyes_closed,
    "eyes_happy": eyes_happy,
    "mouth_closed": mouth_closed,
    "mouth_n": mouth_n,
    "mouth_a": lambda: open_mouth(4, 11, 2, 7, teeth=True, tongue=True),
    "mouth_i": lambda: open_mouth(3, 12, 3, 5, teeth=True),
    "mouth_u": lambda: open_mouth(6, 9, 3, 6),
    "mouth_e": lambda: open_mouth(4, 11, 3, 6, teeth=True),
    "mouth_o": lambda: open_mouth(5, 10, 2, 7, tongue=True),
}


def build_surfaces(faces):
    s = vc.Surfaces()
    s.add("skin", SKIN, roughness=0.9)
    s.add("hair", "#463A6E", "hair", roughness=0.55)
    s.add("hair_light", "#6A5BA0", "hair", roughness=0.45)
    s.add("hair_dark", "#2F2650", "hair", roughness=0.65)
    s.add("ribbon", "#F2913C", "cloth", roughness=0.7)
    s.add("coat", "#EEF2F3", "cloth", roughness=0.8)
    s.add("coat_shadow", "#BFCBD2", "cloth", roughness=0.85)
    s.add("cuff", "#2F8C8C", "cloth", roughness=0.8)
    s.add("knit", "#2E6F78", "cloth", roughness=0.9)
    s.add("skirt", "#34405F", "cloth", roughness=0.85)
    s.add("tights", "#2C2F48", "cloth", roughness=0.75)
    s.add("sneaker", "#F2B23C", "cloth", roughness=0.7)
    s.add("sole", "#F7F4EC", "paint", roughness=0.6)
    s.add("button", "#7D8CA0", "metal", roughness=0.4, metallic=0.8)
    s.add("badge", "#F2913C", "paint", roughness=0.45)
    s.add("badge_white", "#FBFBF7", "paint", roughness=0.45)
    s.add("glass", "#D6F0F2", roughness=0.15, alpha=0.75)
    s.add("cork", "#C49A6C", "paint", roughness=0.8)
    s.add("liquid_pink", "#F0609A", roughness=0.25, glow=0.25)
    s.add("liquid_green", "#5CCB6F", roughness=0.25, glow=0.25)
    s.add("liquid_yellow", "#F4CF3C", roughness=0.25, glow=0.25)
    s.add("pen", "#D9534F", "paint", roughness=0.4)
    s.add("goggle", "#C8743A", "metal", roughness=0.35, metallic=0.9)
    s.add("goggle_dark", "#3B3347", "paint", roughness=0.6)
    s.add("strap", "#32303F", "cloth", roughness=0.8)
    s.add("lens", "#6CD6D6", roughness=0.1, alpha=0.42)
    s.add("shine", "#FFFFFF", roughness=0.2)
    s.add_face("face_eyes", faces["eyes_open"])
    s.add_face("face_mouth", faces["mouth_closed"])
    return s.mats


def tube(part, x, liquid, top):
    """ポケットの試験管"""
    part.box(x - 0.26, x + 0.26, -2.98, -2.46, 3.8, top - 0.5, liquid)
    part.box(x - 0.32, x + 0.32, -3.04, -2.4, top - 0.5, top, "glass")
    part.box(x - 0.3, x + 0.3, -3.02, -2.42, top, top + 0.3, "cork")


def build_character(mats):
    root = vc.add_root()

    # 脚（原点は股関節。足元から 5 ボクセル）。細めで、明るいスニーカー
    for name, sx in (("LegL", 1), ("LegR", -1)):
        leg = Part(name, surface_uv=True)
        leg.box(-1.15, 1.15, -1.2, 1.2, -3.9, 0.0, "tights")
        leg.box(-1.4, 1.4, -2.2, 1.45, -4.5, -3.5, "sneaker")
        leg.box(-1.3, 1.3, -2.0, 1.2, -3.9, -3.3, "sneaker")
        leg.box(-1.5, 1.5, -2.4, 1.55, -5.0, -4.5, "sole")
        leg.box(-0.7, 0.7, -2.25, -1.6, -4.2, -3.75, "sole")   # くつひも
        leg.build(mats, (1.55 * sx, 0, 5.0), root)

    # 胴体（原点は腰）。白衣はすそへ段々に広がる
    body = Part("Body", surface_uv=True)
    body.box(-3.4, 3.4, -2.2, 2.2, 1.5, 7.0, "coat")
    # 前は開いていて、中のスカートが見える。すそに行くほど広く開く
    for z0, z1, wx, wy, opening in ((0.5, 1.6, 3.7, 2.3, 1.0), (-0.5, 0.5, 4.2, 2.45, 1.15), (-1.5, -0.5, 4.8, 2.6, 1.35), (-2.6, -1.5, 5.5, 2.75, 1.6)):
        body.box(-wx, wx, -2.1, wy, z0, z1, "coat")
        for sx in (-1, 1):
            xa, xb = sorted((opening * sx, wx * sx))
            body.box(xa, xb, -wy, -2.1, z0, z1, "coat")
            xa, xb = sorted((opening * sx, (opening + 0.16) * sx))
            body.box(xa, xb, -wy - 0.06, -2.1, z0, z1, "coat_shadow")
    # すそのふちの影
    for sx in (-1, 1):
        xa, xb = sorted((1.6 * sx, 5.55 * sx))
        body.box(xa, xb, -2.8, 2.8, -2.75, -2.6, "coat_shadow")
    body.box(-1.6, 1.6, 2.0, 2.8, -2.75, -2.6, "coat_shadow")
    # 中のニットとスカート
    body.box(-1.0, 1.0, -2.35, -2.2, 3.0, 7.0, "knit")
    body.box(-1.0, 1.0, -2.3, -2.2, 1.6, 3.0, "knit")
    body.box(-1.7, 1.7, -2.25, 1.6, -2.45, 1.6, "skirt")
    body.box(-1.7, 1.7, -2.3, -2.25, 1.0, 1.6, "tights")      # ベルト
    # 白衣のふち（合わせの線）
    for sx in (-1, 1):
        xa, xb = sorted((1.0 * sx, 1.2 * sx))
        body.box(xa, xb, -2.4, -2.2, 1.6, 6.9, "coat_shadow")
        # えり：V の字に段を付ける
        for i, z in enumerate((6.3, 5.6, 4.9)):
            xa, xb = sorted(((1.05 + 0.35 * (2 - i)) * sx, (2.3 + 0.2 * (2 - i)) * sx))
            body.box(xa, xb, -2.55, -2.2, z, z + 0.75, "coat")
        xa, xb = sorted((0.2 * sx, 1.35 * sx))
        body.box(xa, xb, -2.75, -2.3, 6.5, 7.15, "knit")
    # 右胸のネームカード
    body.box(-3.0, -1.5, -2.32, -2.2, 3.7, 4.7, "badge_white")
    body.box(-3.0, -1.5, -2.36, -2.3, 4.45, 4.7, "badge")
    # 左胸のポケットと試験管（3 本）
    body.box(1.45, 3.15, -2.5, -2.2, 3.4, 4.8, "coat")
    body.box(1.45, 3.15, -2.55, -2.45, 4.65, 4.8, "coat_shadow")
    tube(body, 1.8, "liquid_pink", 6.0)
    tube(body, 2.35, "liquid_green", 6.3)
    tube(body, 2.9, "liquid_yellow", 5.7)
    # 腰のポケット。右にふたつ折りのメモ、左にフラスコ
    for sx in (-1, 1):
        xa, xb = sorted((2.1 * sx, 4.4 * sx))
        body.box(xa, xb, -2.85, -2.6, -1.4, 0.0, "coat")
        body.box(xa, xb, -2.9, -2.8, -0.15, 0.0, "coat_shadow")
    # フラスコ：段々に細くなる
    for z0, z1, w in ((-0.1, 0.25, 0.85), (0.25, 0.6, 0.6), (0.6, 0.9, 0.34)):
        body.box(3.25 - w, 3.25 + w, -2.8 - w * 0.5, -2.6 + w * 0.3, z0, z1, "liquid_pink" if z0 < 0.2 else "glass")
    body.box(3.25 - 0.26, 3.25 + 0.26, -2.9, -2.55, 0.9, 1.5, "glass")
    body.box(3.25 - 0.3, 3.25 + 0.3, -2.94, -2.5, 1.5, 1.72, "cork")
    # ボタン
    for z in (2.0, 3.6):
        body.box(1.25, 1.65, -2.45, -2.2, z, z + 0.4, "button")
    # 後ろ：ベルトと真ん中の切れ込み
    body.box(-2.3, 2.3, 2.2, 2.45, 1.5, 2.2, "coat")
    for sx in (-1, 1):
        xa, xb = sorted((1.7 * sx, 2.05 * sx))
        body.box(xa, xb, 2.45, 2.55, 1.65, 2.0, "button")
    body.box(-0.12, 0.12, 2.75, 2.85, -2.6, -0.6, "coat_shadow")
    body_obj = body.build(mats, (0, 0, 5.0), root)

    # 腕（原点は肩）。折り返したそでから、ニットの色がのぞく
    for name, sx in (("ArmL", 1), ("ArmR", -1)):
        arm = Part(name, surface_uv=True)
        arm.box(-1.15, 1.15, -1.2, 1.2, -4.6, 0.45, "coat")
        arm.box(-1.25, 1.25, -1.3, 1.3, -5.3, -4.5, "cuff")
        arm.box(-0.95, 0.95, -1.0, 1.0, -6.3, -5.3, "skin")
        arm.build(mats, (4.55 * sx, 0, 6.5), body_obj)

    # 頭（原点は首）
    head = Part("Head", surface_uv=True)
    head.box(-1.3, 1.3, -1.3, 1.3, 0.0, 0.8, "skin")           # 首
    head.box(-4.7, 4.7, -4.3, 4.3, 0.2, 1.0, "skin")           # あご（細く）
    head.box(-5.4, 5.4, -4.8, 4.8, 1.0, 10.5, "skin")          # 頭
    # 髪：上は段を付けて丸く
    head.box(-5.8, 5.8, -5.2, 5.7, 8.4, 11.0, "hair")
    head.box(-5.0, 5.0, -4.4, 5.0, 11.0, 11.7, "hair")
    head.box(-3.4, 3.4, -3.0, 3.6, 11.7, 12.1, "hair")
    # 後ろ髪（うなじまで）と、顔の横の毛束
    head.box(-5.8, 5.8, 2.6, 5.7, 1.4, 8.4, "hair")
    head.box(-5.0, 5.0, 3.6, 5.2, 0.4, 1.4, "hair_dark")
    for sx in (-1, 1):
        xa, xb = sorted((4.65 * sx, 5.9 * sx))
        head.box(xa, xb, -5.05, 2.6, 3.0, 8.4, "hair")
        xa, xb = sorted((4.7 * sx, 5.7 * sx))
        head.box(xa, xb, -5.0, -2.8, 1.3, 3.0, "hair")          # もみあげは長めに
        xa, xb = sorted((5.0 * sx, 5.9 * sx))
        head.box(xa, xb, -3.6, -2.0, 0.8, 1.3, "hair_dark")
    # 前髪：長さをそろえず、流す
    for x0, x1, z0, m in ((-5.4, -3.6, 6.9, "hair"), (-3.6, -2.0, 7.3, "hair"), (-2.0, -0.6, 7.6, "hair_dark"), (-0.6, 1.0, 7.3, "hair"), (1.0, 2.8, 7.0, "hair"), (2.8, 4.2, 7.4, "hair_dark"), (4.2, 5.4, 6.8, "hair")):
        head.box(x0, x1, -5.45, -4.8, z0, 8.4, m)
    # つやの筋
    head.box(-4.8, -1.0, -5.25, -5.15, 10.3, 10.9, "hair_light")
    head.box(-5.85, -5.75, -3.8, -0.4, 9.2, 9.7, "hair_light")
    head.box(1.0, 3.6, -3.0, -1.0, 11.65, 11.75, "hair_light")
    # 大きく結んだ横の髪（キャラの左）。ひと目でわかるところ
    head.box(5.6, 7.3, 0.4, 3.6, 7.4, 10.8, "ribbon")          # 結び目
    head.box(6.2, 8.3, -0.6, 0.6, 9.2, 10.8, "ribbon")         # リボンの羽
    head.box(6.2, 8.3, 3.4, 4.6, 9.2, 10.8, "ribbon")
    head.rbox(7.2, 10.8, -0.1, 4.1, 5.2, 10.6, "hair")
    head.rbox(7.8, 11.5, 0.3, 3.7, 1.4, 5.6, "hair")
    head.rbox(8.2, 11.3, 0.8, 3.3, -1.6, 1.6, "hair_dark")
    head.box(9.0, 10.8, 1.2, 2.9, -3.2, -1.5, "hair")
    head.box(10.5, 11.7, 1.3, 2.8, -3.6, -2.4, "hair")          # 毛先ははねる
    head.box(7.3, 7.5, 0.5, 3.5, 2.5, 10.0, "hair_light")
    head.box(10.82, 10.92, 1.0, 3.2, 6.0, 9.8, "hair_light")
    head.box(11.52, 11.6, 1.2, 2.8, 2.2, 5.0, "hair_light")
    # 探しているペン（髪にさしたまま）
    head.box(-6.2, -5.75, -0.8, -0.3, 7.6, 10.6, "pen")
    head.box(-6.2, -5.75, -0.8, -0.3, 10.6, 10.9, "badge_white")
    head_obj = head.build(mats, (0, 0, 7.0), body_obj)

    # 顔の板（テクスチャを差し替える）
    eyes = Part("Eyes")
    eyes.box(-4.5, 4.5, -4.83, -4.8, 3.3, 6.8, "face_eyes", front_uv=True)
    eyes.build(mats, (0, 0, 0), head_obj)

    mouth = Part("Mouth")
    mouth.box(-2.0, 2.0, -4.83, -4.8, 1.05, 3.3, "face_mouth", front_uv=True)
    mouth.build(mats, (0, 0, 0), head_obj)

    # ゴーグル（Glasses）：おでこに上げている。下ろすと目にかかる
    goggles = Part("Glasses", surface_uv=True)
    y0, y1 = -6.5, -5.4
    z_mid = 9.0
    for cx in (-2.75, 2.75):
        hw, hh = 2.4, 1.9
        # 八角形のふち
        goggles.box(cx - hw + 0.6, cx + hw - 0.6, y0, y1, z_mid + hh - 0.5, z_mid + hh, "goggle")
        goggles.box(cx - hw + 0.6, cx + hw - 0.6, y0, y1, z_mid - hh, z_mid - hh + 0.5, "goggle")
        goggles.box(cx - hw, cx - hw + 0.5, y0, y1, z_mid - hh + 0.6, z_mid + hh - 0.6, "goggle")
        goggles.box(cx + hw - 0.5, cx + hw, y0, y1, z_mid - hh + 0.6, z_mid + hh - 0.6, "goggle")
        for ax, az in ((-1, -1), (-1, 1), (1, -1), (1, 1)):
            bx, bz = cx + ax * (hw - 0.55), z_mid + az * (hh - 0.55)
            goggles.box(bx - 0.4, bx + 0.4, y0 + 0.02, y1 - 0.02, bz - 0.4, bz + 0.4, "goggle")
        # 内側の黒いふち（顔に当たるところ）とレンズ
        goggles.box(cx - hw + 0.3, cx + hw - 0.3, y0 + 0.8, y1, z_mid + hh - 0.75, z_mid + hh - 0.3, "goggle_dark")
        goggles.box(cx - hw + 0.3, cx + hw - 0.3, y0 + 0.8, y1, z_mid - hh + 0.3, z_mid - hh + 0.75, "goggle_dark")
        goggles.box(cx - hw + 0.5, cx + hw - 0.5, y0 + 0.3, y0 + 0.4, z_mid - hh + 0.5, z_mid + hh - 0.5, "lens")
        goggles.box(cx - 1.3, cx - 0.5, y0 + 0.2, y0 + 0.28, z_mid + 0.4, z_mid + 1.0, "shine")
        goggles.box(cx - 0.4, cx - 0.1, y0 + 0.2, y0 + 0.28, z_mid + 0.7, z_mid + 1.0, "shine")
    goggles.box(-0.5, 0.5, y0 + 0.1, y1, z_mid - 0.5, z_mid + 0.7, "goggle")     # ブリッジ
    # ベルト（頭のまわり）
    for sx in (-1, 1):
        xa, xb = sorted((5.1 * sx, 6.05 * sx))
        goggles.box(xa, xb, y1 + 0.0, y1 + 0.6, z_mid - 0.7, z_mid + 0.7, "goggle")
        xa, xb = sorted((5.9 * sx, 6.05 * sx))
        goggles.box(xa, xb, -5.0, 5.95, z_mid - 0.55, z_mid + 0.55, "strap")
    goggles.box(-6.05, 6.05, 5.75, 5.95, z_mid - 0.55, z_mid + 0.55, "strap")
    goggles.build(mats, (0, 0, 0), head_obj)

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
