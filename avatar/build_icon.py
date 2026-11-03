"""先生モデルからアプリアイコン（1024×1024 PNG）をレンダリングするスクリプト。

使い方（リポジトリのルートで）:
    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python avatar/build_icon.py

出力（ios/HomeTeacher/Resources/Assets.xcassets/AppIcon.appiconset/）:
    AppIcon.png          ふつうのアイコン（クリーム〜オレンジのグラデーション）
    AppIcon-Dark.png     ダークモード用（夜空の紺色の背景）
    AppIcon-Tinted.png   ティント用（黒地に白黒の先生。色は iOS がつける）

モデルは build_teacher.py と同じ組み立て（build_character）をそのまま使うので、
teacher.usdz と同じ先生になる。アイコンでは「にっこり目」と口を開けた笑顔にして、
頭を少しかしげる。透過なし・角丸なし（角丸は iOS がつける）。
"""

import os
import sys
import tempfile

import bpy
import numpy as np

sys.dont_write_bytecode = True  # avatar/__pycache__ を作らない
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_teacher as bt  # noqa: E402

SIZE = 1024
# 画面の高さに対する頭の大きさと、上の余白（iOS の角丸に削られないように）
HEAD_FRACTION = 0.6
TOP_MARGIN = 0.10
# 斜めに向ける角度（度）
TURN_DEG = -18.0
ICON_DIR = os.path.join(bt.ROOT, "ios", "HomeTeacher", "Resources", "Assets.xcassets", "AppIcon.appiconset")

# 背景のグラデーション（上 → 下）と、頭のうしろの明るい光
BACKGROUNDS = {
    "AppIcon": {"top": "#FFF4DC", "bottom": "#FFB36B", "glow": "#FFFBF0", "glow_strength": 0.75},
    "AppIcon-Dark": {"top": "#2C3A63", "bottom": "#141B33", "glow": "#4A5C94", "glow_strength": 0.6},
}


def rgb01(h):
    return np.array(bt.hex_rgb(h), dtype=np.float32) / 255.0


# ---------------------------------------------------------------- 顔（アイコン用）
# 小さく表示しても表情が分かるよう、build_teacher.py の顔より太く大きく描く。
# 板の大きさとパレットは同じ。

def icon_eyes():
    g = bt.blank(bt.EYES_W, bt.EYES_H)
    for cx in bt.EYE_CENTERS:
        # 太い「^」のにっこり目
        for dx, y in ((-1, 4), (0, 4),
                      (-2, 5), (-1, 5), (0, 5), (1, 5),
                      (-3, 6), (-2, 6), (1, 6), (2, 6),
                      (-3, 7), (2, 7)):
            bt.put(g, cx + dx, y, "k")
    bt.add_blush(g)
    return g


def icon_mouth():
    # 口を大きく開けた「D」の形の笑顔
    g = bt.blank(bt.MOUTH_W, bt.MOUTH_H)
    rows = {
        2: "kkkkkkkkkk",
        3: "kwwwwwwwwk",
        4: "krrrrrrrrk",
        5: ".krrttrrk.",
        6: "..kkkkkk..",
    }
    for y, line in rows.items():
        for i, c in enumerate(line):
            if c != ".":
                bt.put(g, 3 + i, y, c)
    return g


# ---------------------------------------------------------------- シーン

def build_scene(face_dir):
    bpy.ops.wm.read_factory_settings(use_empty=True)

    eyes_png = os.path.join(face_dir, "icon_eyes.png")
    mouth_png = os.path.join(face_dir, "icon_mouth.png")
    bt.write_png(eyes_png, icon_eyes(), bt.PNG_SCALE)
    bt.write_png(mouth_png, icon_mouth(), bt.PNG_SCALE)

    mats = {name: bt.make_color_material(name, color) for name, color in bt.COLORS.items()}
    # build_character は face_eyes_open / face_mouth_closed の名前で顔の板を貼るので、中身だけ差し替える
    mats["face_eyes_open"] = bt.make_texture_material("face_eyes", eyes_png)
    mats["face_mouth_closed"] = bt.make_texture_material("face_mouth", mouth_png)

    root = bt.build_character(mats)
    # 頭をほんの少しかしげて親しみやすく
    bpy.data.objects["Head"].rotation_euler = (0.0, np.radians(-4.0), 0.0)

    # 少し斜め（キャラから見て左側）を向かせる。カメラは正面から
    root.rotation_euler = (0.0, 0.0, np.radians(TURN_DEG))

    scene = bpy.context.scene

    # カメラ（正射影でボクセルの面をくっきり見せる）
    cam_data = bpy.data.cameras.new("IconCam")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("IconCam", cam_data)
    scene.collection.objects.link(cam)
    cam.rotation_euler = (np.radians(90.0), 0.0, 0.0)  # 真横から水平に（+Y 向き）
    frame_head(cam, bpy.data.objects["Head"])
    scene.camera = cam

    # ライト: 左上からのキー、右からの弱い補助、うしろからの縁取り
    def sun(name, energy, rot, color=(1.0, 1.0, 1.0)):
        d = bpy.data.lights.new(name, "SUN")
        d.energy = energy
        d.color = color
        d.angle = np.radians(8.0)
        o = bpy.data.objects.new(name, d)
        o.rotation_euler = tuple(np.radians(r) for r in rot)
        scene.collection.objects.link(o)

    sun("Key", 2.2, (50.0, 0.0, -35.0), (1.0, 0.97, 0.92))
    sun("Fill", 0.6, (70.0, 0.0, 50.0), (0.92, 0.96, 1.0))
    sun("Rim", 1.5, (-60.0, 0.0, 160.0), (1.0, 0.95, 0.85))

    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs["Color"].default_value = (1.0, 0.97, 0.92, 1.0)
    bg.inputs["Strength"].default_value = 0.35
    scene.world = world

    scene.render.engine = "BLENDER_EEVEE"
    scene.eevee.taa_render_samples = 32
    scene.render.resolution_x = SIZE
    scene.render.resolution_y = SIZE
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.view_settings.view_transform = "Standard"
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"


def frame_head(cam, head):
    """頭（髪・メガネ・顔の板を含む）が上寄りの中央に大きく入るようにカメラを置く。"""
    bpy.context.view_layer.update()
    pts = []
    for o in [head] + list(head.children_recursive):
        mw = o.matrix_world
        pts += [mw @ v.co for v in o.data.vertices]
    xs = [p.x for p in pts]
    zs = [p.z for p in pts]
    height = max(zs) - min(zs)
    scale = height / HEAD_FRACTION
    cam.data.ortho_scale = scale
    cam.location = ((min(xs) + max(xs)) / 2, -5.0, max(zs) + TOP_MARGIN * scale - 0.5 * scale)


def render_rgba(path):
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    img = bpy.data.images.load(path)
    px = np.array(img.pixels[:], dtype=np.float32).reshape(SIZE, SIZE, 4)
    bpy.data.images.remove(img)
    return px  # 下の行から上へ。色は sRGB、アルファはストレート


# ---------------------------------------------------------------- 合成

def background(spec):
    # pixels は下の行から並ぶので、y=0 が下
    y = np.linspace(0.0, 1.0, SIZE, dtype=np.float32)[:, None, None]
    grad = rgb01(spec["bottom"]) * (1.0 - y) + rgb01(spec["top"]) * y
    grad = np.broadcast_to(grad, (SIZE, SIZE, 3)).copy()
    # 頭のうしろに丸い光
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    cx, cy, r = SIZE * 0.5, SIZE * 0.6, SIZE * 0.42
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / r
    glow = np.clip(1.0 - d, 0.0, 1.0) ** 1.6 * spec["glow_strength"]
    return grad * (1.0 - glow[..., None]) + rgb01(spec["glow"]) * glow[..., None]


def save_rgb(path, rgb):
    img = bpy.data.images.new("out", SIZE, SIZE, alpha=False)
    rgba = np.concatenate([np.clip(rgb, 0.0, 1.0), np.ones((SIZE, SIZE, 1), np.float32)], axis=2)
    img.pixels[:] = rgba.ravel()
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)
    print("書き出し:", path)


def main():
    os.makedirs(ICON_DIR, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        build_scene(tmp)
        fg = render_rgba(os.path.join(tmp, "teacher_rgba.png"))

    color, alpha = fg[..., :3], fg[..., 3:4]

    for name, spec in BACKGROUNDS.items():
        out = color * alpha + background(spec) * (1.0 - alpha)
        save_rgb(os.path.join(ICON_DIR, name + ".png"), out)

    # ティント用: 明るさだけの先生を黒地に置く
    lum = (color @ np.array([0.2126, 0.7152, 0.0722], np.float32))[..., None]
    lum = 0.2 + 0.8 * lum  # 暗い髪やメガネも見えるように持ち上げる
    tinted = np.repeat(lum, 3, axis=2) * alpha
    save_rgb(os.path.join(ICON_DIR, "AppIcon-Tinted.png"), tinted)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        traceback.print_exc()
        sys.exit(1)
