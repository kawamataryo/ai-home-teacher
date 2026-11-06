"""まるい動物のキャラ：子犬「ポン」とネコ「ノア」（#132）。ムニ（#131）と同じ作り方で、毛の質感と耳としっぽを足す。

使い方（リポジトリのルートで）:
    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python avatar/build_animals.py -- --animal pon
    ... -- --animal noa --render <出力先のフォルダ>
出力:
    ios/HomeTeacher/Resources/Characters/<pon|noa>.usdz
    avatar/<pon|noa>/<pon|noa>.blend（元データ）

毛はシェーダーで生やさず、色のむらと、毛の流れの法線と粗さを画像に焼いて表す（iPad でも動くように）。
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy
import numpy as np
import rig_common as rig
import round_face


def rgb(hex_color):
    """#RRGGBB を線形の色にする"""
    h = hex_color.lstrip("#")
    values = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    return np.array([v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in values])


def soft(distance, near, far):
    """near で 1、far で 0"""
    return float(rig.smoothstep((far - distance) / (far - near)))


def paint(skin, fn):
    """頂点の色を塗る。fn(p) -> 色（線形）"""
    attr = skin.data.color_attributes.new(name="Coat", type="FLOAT_COLOR", domain="POINT")
    for i, v in enumerate(skin.data.vertices):
        c = fn(np.array(v.co))
        attr.data[i].color = (c[0], c[1], c[2], 1)
    return attr


def fur_material(name, roughness=(0.62, 0.86), strand=0.32, bump=0.45):
    """塗った色に、毛のむらと流れを重ねる手続き型のマテリアル。bake_pbr で画像に焼く"""
    mat, nt, bsdf = rig.new_material(f"{name}_source")
    coat = nt.nodes.new("ShaderNodeVertexColor")
    coat.layer_name = "Coat"
    coord = nt.nodes.new("ShaderNodeTexCoord")
    # 毛は上から下へ流れる：Z を伸ばしたノイズで筋にする
    mapping = nt.nodes.new("ShaderNodeMapping")
    mapping.inputs["Scale"].default_value = (1.0, 1.0, 0.16)
    nt.links.new(coord.outputs["Object"], mapping.inputs["Vector"])
    hair = nt.nodes.new("ShaderNodeTexNoise")
    hair.inputs["Scale"].default_value = 150
    hair.inputs["Detail"].default_value = 6
    hair.inputs["Roughness"].default_value = 0.6
    nt.links.new(mapping.outputs[0], hair.inputs["Vector"])
    tuft = nt.nodes.new("ShaderNodeTexNoise")
    tuft.inputs["Scale"].default_value = 26
    tuft.inputs["Detail"].default_value = 4
    nt.links.new(coord.outputs["Object"], tuft.inputs["Vector"])

    # 色のむら（毛の根元は少し暗い）
    shade = nt.nodes.new("ShaderNodeMapRange")
    shade.inputs["From Min"].default_value = 0.3
    shade.inputs["From Max"].default_value = 0.7
    shade.inputs["To Min"].default_value = 1 - strand
    shade.inputs["To Max"].default_value = 1 + strand * 0.35
    nt.links.new(hair.outputs["Fac"], shade.inputs["Value"])
    mult = nt.nodes.new("ShaderNodeVectorMath")
    mult.operation = "SCALE"
    nt.links.new(coat.outputs["Color"], mult.inputs[0])
    nt.links.new(shade.outputs["Result"], mult.inputs["Scale"])
    nt.links.new(mult.outputs[0], bsdf.inputs["Base Color"])

    rough = nt.nodes.new("ShaderNodeMapRange")
    rough.inputs["To Min"].default_value = roughness[0]
    rough.inputs["To Max"].default_value = roughness[1]
    nt.links.new(hair.outputs["Fac"], rough.inputs["Value"])
    nt.links.new(rough.outputs["Result"], bsdf.inputs["Roughness"])

    # 毛の流れの起伏と、ふさの起伏
    height = nt.nodes.new("ShaderNodeMath")
    height.operation = "MULTIPLY_ADD"
    nt.links.new(hair.outputs["Fac"], height.inputs[0])
    height.inputs[1].default_value = 0.7
    nt.links.new(tuft.outputs["Fac"], height.inputs[2])
    bump_node = nt.nodes.new("ShaderNodeBump")
    bump_node.inputs["Strength"].default_value = bump
    bump_node.inputs["Distance"].default_value = 0.03
    nt.links.new(height.outputs[0], bump_node.inputs["Height"])
    nt.links.new(bump_node.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


def nose(prefix, center, radii, color, surface, shine=True):
    """鼻：マズルの先に貼りつく、ふくらんだ小さな部品"""
    mat = rig.flat_material(f"{prefix}_nose", color, 0.22)
    obj = rig.ellipsoid((center[0], 0, center[1]), (radii[0], radii[2], radii[1]), segments=24, rings=16, name="Nose")
    for v in obj.data.vertices:
        p = np.array(v.co)
        v.co = (p[0], surface.front_y(p[0], p[2]) + p[1] - 0.002, p[2])
    obj.data.update()
    obj.data.materials.append(mat)
    rig.mark_part(obj, "nose")
    return obj


# ---------------------------------------------------------------- 子犬

def build_pon():
    """ふわふわのカラメル色の子犬。垂れた大きな耳、片目のまわりのぶち、短く立ったしっぽ"""
    caramel, cream, dark, patch = rgb("#D88F45"), rgb("#FBEBD0"), rgb("#8A4E25"), rgb("#B4692E")

    shapes = [
        # 頭と体がひとつづきの、下ぶくれの形
        rig.ellipsoid((0, 0, 0.42), (0.52, 0.48, 0.42)),
        rig.ellipsoid((0, -0.02, 0.76), (0.56, 0.50, 0.42)),
        # マズル
        rig.ellipsoid((0, -0.43, 0.62), (0.205, 0.17, 0.145)),
        # 足
        rig.ellipsoid((0.22, -0.12, 0.08), (0.145, 0.19, 0.09), segments=32, rings=20),
        rig.ellipsoid((-0.22, -0.12, 0.08), (0.145, 0.19, 0.09), segments=32, rings=20),
    ]
    # 手
    shapes += rig.capsule_blob((0.46, -0.10, 0.44), (0.54, -0.20, 0.30), 0.105, 0.095)
    shapes += rig.capsule_blob((-0.46, -0.10, 0.44), (-0.54, -0.20, 0.30), 0.105, 0.095)
    # 垂れた耳（大きいのがチャームポイント）
    shapes += rig.capsule_blob((0.44, 0.0, 1.03), (0.69, -0.04, 0.68), 0.115, 0.15)
    shapes += rig.capsule_blob((-0.44, 0.0, 1.03), (-0.69, -0.04, 0.68), 0.115, 0.15)
    # しっぽ（短く立つ）
    shapes += rig.capsule_blob((0, 0.42, 0.34), (0, 0.66, 0.60), 0.095, 0.075)

    skin = rig.sculpt_body(shapes, voxel_size=0.0125, smooth_iterations=30)
    rig.decimate_to(skin, 14000)
    rig.smart_uv(skin)

    def coat(p):
        c = caramel.copy()
        # おなかと胸
        belly = soft(np.linalg.norm((p - np.array([0, -0.4, 0.3])) * np.array([1.05, 0.9, 1.0])), 0.26, 0.40)
        c = c + (cream - c) * belly
        # マズルと口のまわり
        muzzle = soft(np.linalg.norm((p - np.array([0, -0.5, 0.60])) * np.array([1, 0.85, 1.05])), 0.17, 0.27)
        c = c + (cream - c) * muzzle
        # 手足の先
        paws = max(soft(p[2], 0.08, 0.18), soft(np.linalg.norm(p - np.array([np.sign(p[0]) * 0.54, -0.2, 0.3])), 0.09, 0.15))
        c = c + (cream - c) * paws
        # 耳は濃い色
        ear = soft(np.linalg.norm((p - np.array([np.sign(p[0]) * 0.62, -0.02, 0.80]))), 0.27, 0.33)
        c = c + (dark - c) * ear
        # 片目のまわりのぶち（キャラの左目）
        spot = soft(np.linalg.norm((p - np.array([0.26, -0.47, 0.82])) * np.array([1, 1, 0.95])), 0.13, 0.18)
        c = c + (patch - c) * spot
        # しっぽの先
        tail = soft(np.linalg.norm(p - np.array([0, 0.66, 0.60])), 0.08, 0.14)
        c = c + (cream - c) * tail
        return c

    paint(skin, coat)
    surface = round_face.Surface(skin)
    rig.bake_pbr(skin, fur_material("pon"), "pon", 1024, os.path.join(rig.ROOT, "avatar", "pon", "textures"))

    nose_part = nose("pon", (0, 0.665), (0.056, 0.042, 0.03), (0.03, 0.022, 0.02), surface)
    spec = round_face.FaceSpec(prefix="pon", eye_x=0.245, eye_z=0.82, mouth_z=0.565, eye_rx=0.058, eye_rz=0.072, mouth_rx=0.066, mouth_bend=0.012)
    round_face.add_face(skin, surface, spec, extra_parts=[nose_part])

    arm = rig.add_armature(skin, {
        "root": {"head": (0, 0, 0), "tail": (0, 0, 0.1), "deform": False},
        "body": {"head": (0, 0, 0.1), "tail": (0, 0, 0.55), "parent": "root", "reach": 0.7},
        "head": {"head": (0, 0, 0.55), "tail": (0, 0, 1.15), "parent": "body", "reach": 0.68},
        "armL": {"head": (0.42, -0.08, 0.48), "tail": (0.56, -0.21, 0.27), "parent": "body", "reach": 0.22},
        "armR": {"head": (-0.42, -0.08, 0.48), "tail": (-0.56, -0.21, 0.27), "parent": "body", "reach": 0.22},
        "legL": {"head": (0.22, -0.05, 0.2), "tail": (0.22, -0.26, 0.03), "parent": "root", "reach": 0.17},
        "legR": {"head": (-0.22, -0.05, 0.2), "tail": (-0.22, -0.26, 0.03), "parent": "root", "reach": 0.17},
        "earL": {"head": (0.42, 0.0, 1.05), "tail": (0.72, -0.05, 0.6), "parent": "head", "reach": 0.23},
        "earR": {"head": (-0.42, 0.0, 1.05), "tail": (-0.72, -0.05, 0.6), "parent": "head", "reach": 0.23},
        "tail": {"head": (0, 0.36, 0.28), "tail": (0, 0.70, 0.64), "parent": "body", "reach": 0.2},
    })
    return skin, arm


# ---------------------------------------------------------------- ネコ

def build_noa():
    """三毛のネコ。三角の耳、細く長いしっぽ、ひげ"""
    white, orange, black = rgb("#F7F3EC"), rgb("#E28A36"), rgb("#2E2A2C")

    shapes = [
        rig.ellipsoid((0, 0, 0.40), (0.46, 0.42, 0.40)),
        rig.ellipsoid((0, -0.02, 0.78), (0.53, 0.46, 0.38)),
        # 頬のふくらみ
        rig.ellipsoid((0.34, -0.16, 0.68), (0.2, 0.2, 0.15)),
        rig.ellipsoid((-0.34, -0.16, 0.68), (0.2, 0.2, 0.15)),
        rig.ellipsoid((0, -0.43, 0.65), (0.13, 0.08, 0.09)),
        rig.ellipsoid((0.19, -0.1, 0.07), (0.125, 0.18, 0.08), segments=32, rings=20),
        rig.ellipsoid((-0.19, -0.1, 0.07), (0.125, 0.18, 0.08), segments=32, rings=20),
    ]
    shapes += rig.capsule_blob((0.38, -0.12, 0.42), (0.44, -0.24, 0.24), 0.09, 0.08)
    shapes += rig.capsule_blob((-0.38, -0.12, 0.42), (-0.44, -0.24, 0.24), 0.09, 0.08)
    # とがった耳
    shapes += rig.capsule_blob((0.34, 0.0, 1.03), (0.42, 0.0, 1.34), 0.15, 0.022, steps=10)
    shapes += rig.capsule_blob((-0.34, 0.0, 1.03), (-0.42, 0.0, 1.34), 0.15, 0.022, steps=10)
    # 長いしっぽ（横から上へカーブ）
    path = [(0.14, 0.36, 0.14), (0.34, 0.40, 0.14), (0.52, 0.40, 0.22), (0.63, 0.37, 0.40), (0.66, 0.33, 0.62), (0.60, 0.29, 0.84)]
    for a, b, r0, r1 in zip(path, path[1:], (0.062, 0.06, 0.057, 0.054, 0.05), (0.06, 0.057, 0.054, 0.05, 0.044)):
        shapes += rig.capsule_blob(a, b, r0, r1, steps=6)

    skin = rig.sculpt_body(shapes, voxel_size=0.0115, smooth_iterations=24)
    rig.decimate_to(skin, 14000)
    rig.smart_uv(skin)

    def coat(p):
        c = white.copy()
        # 三毛のぶち（左の耳のまわりと背中がオレンジ、右の耳と腰が黒）
        o1 = soft(np.linalg.norm((p - np.array([0.33, -0.1, 1.05])) * np.array([0.9, 1, 1])), 0.30, 0.36)
        o2 = soft(np.linalg.norm((p - np.array([-0.32, 0.25, 0.34]))), 0.25, 0.31)
        k1 = soft(np.linalg.norm((p - np.array([-0.35, -0.08, 1.06])) * np.array([0.9, 1, 1])), 0.30, 0.36)
        k2 = soft(np.linalg.norm((p - np.array([0.36, 0.22, 0.50]))), 0.2, 0.26)
        c = c + (orange - c) * max(o1, o2)
        c = c + (black - c) * max(k1, k2)
        # 顔の真ん中とおなかは白いまま
        blaze = soft(np.linalg.norm((p - np.array([0, -0.47, 0.72])) * np.array([1.2, 0.6, 0.9])), 0.16, 0.2)
        c = c + (white - c) * blaze
        # しっぽはしま
        if p[0] > 0.12 and p[1] > 0.2:
            c = black if int((p[2] + p[0]) * 11) % 2 == 0 else orange
        # 耳の内側
        inner = soft(np.linalg.norm((p - np.array([np.sign(p[0]) * 0.38, -0.12, 1.14])) * np.array([1.4, 1, 0.8])), 0.07, 0.11)
        c = c + (rgb("#F2B7B3") - c) * inner
        return c

    paint(skin, coat)
    surface = round_face.Surface(skin)
    rig.bake_pbr(skin, fur_material("noa", roughness=(0.55, 0.8), strand=0.2, bump=0.3), "noa", 1024, os.path.join(rig.ROOT, "avatar", "noa", "textures"))

    # ひげ（細い部品。左右 2 本ずつ）
    whisker_mat = rig.flat_material("noa_whisker", (0.15, 0.13, 0.13), 0.5)
    whiskers = []
    for side in (1, -1):
        for dz, tilt in ((0.03, 0.03), (-0.025, -0.035)):
            start = (side * 0.2, 0.0, 0.645 + dz)
            end = (side * 0.5, 0.0, 0.645 + dz + tilt)
            bpy.ops.mesh.primitive_cylinder_add(vertices=6, radius=0.0042, depth=1.0, location=(0, 0, 0))
            w = bpy.context.active_object
            w.name = "Whisker"
            root_y = surface.front_y(start[0], start[2]) - 0.006
            # X 方向に伸ばす
            for v in w.data.vertices:
                t = v.co.z + 0.5
                x = start[0] + (end[0] - start[0]) * t
                z = start[2] + (end[2] - start[2]) * t + v.co.y
                # 根元の肌の前から、まっすぐ外へ伸ばす（肌に沿わせると腕まで回りこむ）
                v.co = (x, root_y - 0.03 * t + v.co.x, z)
            w.data.update()
            w.data.materials.append(whisker_mat)
            rig.mark_part(w, "whisker")
            whiskers.append(w)

    nose_part = nose("noa", (0, 0.665), (0.03, 0.02, 0.018), (0.86, 0.45, 0.48), surface)
    spec = round_face.FaceSpec(prefix="noa", eye_x=0.215, eye_z=0.80, mouth_z=0.60, eye_rx=0.05, eye_rz=0.07, mouth_rx=0.05, mouth_bend=0.012, eye_color=(0.03, 0.05, 0.03))
    round_face.add_face(skin, surface, spec, extra_parts=[nose_part] + whiskers)

    arm = rig.add_armature(skin, {
        "root": {"head": (0, 0, 0), "tail": (0, 0, 0.1), "deform": False},
        "body": {"head": (0, 0, 0.1), "tail": (0, 0, 0.55), "parent": "root", "reach": 0.66},
        "head": {"head": (0, 0, 0.55), "tail": (0, 0, 1.12), "parent": "body", "reach": 0.64},
        "armL": {"head": (0.34, -0.1, 0.46), "tail": (0.46, -0.25, 0.22), "parent": "body", "reach": 0.2},
        "armR": {"head": (-0.34, -0.1, 0.46), "tail": (-0.46, -0.25, 0.22), "parent": "body", "reach": 0.2},
        "legL": {"head": (0.19, -0.05, 0.18), "tail": (0.19, -0.26, 0.03), "parent": "root", "reach": 0.15},
        "legR": {"head": (-0.19, -0.05, 0.18), "tail": (-0.19, -0.26, 0.03), "parent": "root", "reach": 0.15},
        "earL": {"head": (0.33, 0.0, 1.04), "tail": (0.43, 0.0, 1.36), "parent": "head", "reach": 0.17},
        "earR": {"head": (-0.33, 0.0, 1.04), "tail": (-0.43, 0.0, 1.36), "parent": "head", "reach": 0.17},
        "tail": {"head": (0.14, 0.36, 0.14), "tail": (0.62, 0.30, 0.88), "parent": "body", "reach": 0.34},
    })
    return skin, arm


def pose_for_render(skin, arm, shapes=None):
    for block in skin.data.shape_keys.key_blocks[1:]:
        block.value = (shapes or {}).get(block.name, 0)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--animal", required=True, choices=["pon", "noa"])
    parser.add_argument("--render")
    args = parser.parse_args(argv)
    name = args.animal

    rig.reset()
    skin, arm = (build_pon if name == "pon" else build_noa)()
    print("面数", rig.mesh_stats(skin), "シェイプキー", [k.name for k in skin.data.shape_keys.key_blocks])
    rig.export_usdz(os.path.join(rig.USDZ_DIR, f"{name}.usdz"))
    if args.render:
        os.makedirs(args.render, exist_ok=True)
        rig.setup_render(resolution=800, samples=64, target=(0, 0, 0.62), distance=4.2)
        for view, shapes, yaw in (("front", {}, 0), ("side", {}, -1.0), ("back", {}, 2.6), ("happy", {"eye_happy": 1, "mouth_a": 0.7}, 0), ("worry", {"brow_worry": 1, "mouth_u": 0.5}, 0)):
            pose_for_render(skin, arm, shapes)
            arm.rotation_euler = (0, 0, yaw)
            rig.render(os.path.join(args.render, f"{name}_{view}.png"))
        pose_for_render(skin, arm)
        arm.rotation_euler = (0, 0, 0)
    os.makedirs(os.path.join(rig.ROOT, "avatar", name), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(rig.ROOT, "avatar", name, f"{name}.blend"), compress=True)


main()
