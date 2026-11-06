"""まるいマスコット「ムニ」を作る（#131）。頭と体がひとかたまりの、低い頭身のオリジナルキャラ。

使い方（リポジトリのルートで）:
    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python avatar/build_mascot.py
    ... --python avatar/build_mascot.py -- --render <出力先のフォルダ>   # 確認用のレンダリングも作る
出力:
    ios/HomeTeacher/Resources/Characters/muni.usdz
    avatar/muni/muni.blend（元データ）

形はリメッシュでひとつづきにし、色・粗さ・法線は手続き型のマテリアルから画像に焼く。
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy
import rig_common as rig
import round_face

NAME = "muni"
OUT = os.path.join(rig.ROOT, "avatar", NAME)
TEX = os.path.join(OUT, "textures")

# 主役の色は 1 つ（むらさきがかった青）
BASE = (0.20, 0.25, 0.80)
BELLY = (0.44, 0.52, 0.98)
CHEEK = (0.96, 0.42, 0.55)


def body_shapes():
    parts = [
        # 下ぶくれのおもち（段がつかないように、ひとつの卵形に近づける）
        rig.ellipsoid((0, 0, 0.50), (0.60, 0.54, 0.50)),
        rig.ellipsoid((0, 0, 0.66), (0.545, 0.50, 0.46)),
        # 短い足
        rig.ellipsoid((0.23, -0.10, 0.075), (0.16, 0.17, 0.085), segments=32, rings=20),
        rig.ellipsoid((-0.23, -0.10, 0.075), (0.16, 0.17, 0.085), segments=32, rings=20),
    ]
    # 短い手（丸い先）
    parts += rig.capsule_blob((0.53, -0.05, 0.53), (0.645, -0.10, 0.44), 0.115, 0.10)
    parts += rig.capsule_blob((-0.53, -0.05, 0.53), (-0.645, -0.10, 0.44), 0.115, 0.10)
    # 頭の上の、ちょこんとした毛（チャームポイント）
    parts += rig.capsule_blob((0.0, 0.0, 1.08), (0.02, 0.0, 1.22), 0.07, 0.042)
    parts += rig.capsule_blob((0.02, 0.0, 1.22), (0.11, 0.0, 1.30), 0.042, 0.022)
    return parts


def source_material():
    """色のむら、おなかの明るさ、ほっぺ、やわらかい粒立ちを手続き型で作る"""
    mat, nt, bsdf = rig.new_material("muni_source")
    coord = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(coord.outputs["Object"], sep.inputs[0])

    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 7
    noise.inputs["Detail"].default_value = 5
    nt.links.new(coord.outputs["Object"], noise.inputs["Vector"])
    fine = nt.nodes.new("ShaderNodeTexNoise")
    fine.inputs["Scale"].default_value = 240
    fine.inputs["Detail"].default_value = 3
    nt.links.new(coord.outputs["Object"], fine.inputs["Vector"])

    # 色のむら
    tone = nt.nodes.new("ShaderNodeMix")
    tone.data_type = "RGBA"
    tone.inputs["A"].default_value = (*[c * 0.93 for c in BASE], 1)
    tone.inputs["B"].default_value = (*[min(1, c * 1.06) for c in BASE], 1)
    nt.links.new(noise.outputs["Fac"], tone.inputs["Factor"])

    # おなか：前の下ほど明るい（楕円のグラデーション）
    def distance_to(center, scale):
        vec = nt.nodes.new("ShaderNodeVectorMath")
        vec.operation = "SUBTRACT"
        vec.inputs[1].default_value = center
        nt.links.new(coord.outputs["Object"], vec.inputs[0])
        s = nt.nodes.new("ShaderNodeVectorMath")
        s.operation = "SCALE" if False else "MULTIPLY"
        s.inputs[1].default_value = scale
        nt.links.new(vec.outputs[0], s.inputs[0])
        length = nt.nodes.new("ShaderNodeVectorMath")
        length.operation = "LENGTH"
        nt.links.new(s.outputs[0], length.inputs[0])
        return length.outputs["Value"]

    def soft(value, start, end):
        m = nt.nodes.new("ShaderNodeMapRange")
        m.interpolation_type = "SMOOTHSTEP"
        m.inputs["From Min"].default_value = start
        m.inputs["From Max"].default_value = end
        m.inputs["To Min"].default_value = 1
        m.inputs["To Max"].default_value = 0
        nt.links.new(value, m.inputs["Value"])
        return m.outputs["Result"]

    belly = nt.nodes.new("ShaderNodeMix")
    belly.data_type = "RGBA"
    nt.links.new(tone.outputs[2], belly.inputs["A"])
    belly.inputs["B"].default_value = (*BELLY, 1)
    nt.links.new(soft(distance_to((0, -0.5, 0.26), (1.15, 1.0, 1.25)), 0.30, 0.42), belly.inputs["Factor"])

    # ほっぺ（左右の目の外の下）
    cheek = nt.nodes.new("ShaderNodeMix")
    cheek.data_type = "RGBA"
    nt.links.new(belly.outputs[2], cheek.inputs["A"])
    cheek.inputs["B"].default_value = (*CHEEK, 1)
    add = nt.nodes.new("ShaderNodeMath")
    add.operation = "MAXIMUM"
    nt.links.new(soft(distance_to((0.335, -0.42, 0.59), (1, 1, 1.25)), 0.035, 0.115), add.inputs[0])
    nt.links.new(soft(distance_to((-0.335, -0.42, 0.59), (1, 1, 1.25)), 0.035, 0.115), add.inputs[1])
    scale = nt.nodes.new("ShaderNodeMath")
    scale.operation = "MULTIPLY"
    scale.inputs[1].default_value = 0.8
    nt.links.new(add.outputs[0], scale.inputs[0])
    nt.links.new(scale.outputs[0], cheek.inputs["Factor"])
    nt.links.new(cheek.outputs[2], bsdf.inputs["Base Color"])

    # 粗さ：おもちのように少しだけつや
    rough = nt.nodes.new("ShaderNodeMapRange")
    rough.inputs["To Min"].default_value = 0.38
    rough.inputs["To Max"].default_value = 0.56
    nt.links.new(noise.outputs["Fac"], rough.inputs["Value"])
    nt.links.new(rough.outputs["Result"], bsdf.inputs["Roughness"])

    # 細かい粒立ち（触りたくなる手ざわり）
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.07
    bump.inputs["Distance"].default_value = 0.02
    nt.links.new(fine.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


def build():
    skin = rig.sculpt_body(body_shapes(), voxel_size=0.0125, smooth_iterations=40)
    rig.decimate_to(skin, 13000)
    rig.smart_uv(skin)
    surface = round_face.Surface(skin)
    rig.bake_pbr(skin, source_material(), NAME, 1024, TEX)

    round_face.add_face(skin, surface, round_face.FaceSpec(prefix="muni", eye_x=0.215, eye_z=0.70, mouth_z=0.58))

    arm = rig.add_armature(skin, {
        "root": {"head": (0, 0, 0), "tail": (0, 0, 0.1), "deform": False},
        "body": {"head": (0, 0, 0.1), "tail": (0, 0, 0.6), "parent": "root", "reach": 0.78},
        "head": {"head": (0, 0, 0.6), "tail": (0, 0, 1.08), "parent": "body", "reach": 0.62},
        "armL": {"head": (0.48, -0.04, 0.55), "tail": (0.70, -0.10, 0.42), "parent": "body", "reach": 0.25},
        "armR": {"head": (-0.48, -0.04, 0.55), "tail": (-0.70, -0.10, 0.42), "parent": "body", "reach": 0.25},
        "legL": {"head": (0.25, -0.03, 0.18), "tail": (0.25, -0.2, 0.03), "parent": "root", "reach": 0.17},
        "legR": {"head": (-0.25, -0.03, 0.18), "tail": (-0.25, -0.2, 0.03), "parent": "root", "reach": 0.17},
        "earL": {"head": (0, 0, 1.08), "tail": (0.1, 0, 1.31), "parent": "head", "reach": 0.14},
        "earR": {"head": (0, 0, 1.1), "tail": (0, 0, 1.18), "parent": "head", "deform": False},
    })  # 目と口も肌と同じ計算のウェイトにする（1 本の骨に固定すると、頭を傾けたときに肌に沈む）
    return skin, arm


def pose_for_render(skin, arm, shapes=None, rotations=None):
    for block in skin.data.shape_keys.key_blocks[1:]:
        block.value = (shapes or {}).get(block.name, 0)
    for bone in arm.pose.bones:
        bone.rotation_mode = "XYZ"
        bone.rotation_euler = (rotations or {}).get(bone.name, (0, 0, 0))


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--render")
    args = parser.parse_args(argv)

    rig.reset()
    skin, arm = build()
    print("面数", rig.mesh_stats(skin), "シェイプキー", [k.name for k in skin.data.shape_keys.key_blocks])
    os.makedirs(OUT, exist_ok=True)
    rig.export_usdz(os.path.join(rig.USDZ_DIR, f"{NAME}.usdz"))
    if args.render:
        os.makedirs(args.render, exist_ok=True)
        rig.setup_render(resolution=800, samples=64, target=(0, 0, 0.62), distance=4.0)
        pose_for_render(skin, arm)
        rig.render(os.path.join(args.render, "front.png"))
        for name, shapes in {"a": {"mouth_a": 1}, "i": {"mouth_i": 1}, "o": {"mouth_o": 1}, "blink": {"eye_blink": 1}, "happy": {"eye_happy": 1, "mouth_a": 0.6}, "worry": {"brow_worry": 1, "mouth_u": 0.6}, "side": {}}.items():
            pose_for_render(skin, arm, shapes)
            arm.rotation_euler = (0, 0, -0.9 if name == "side" else 0)
            rig.render(os.path.join(args.render, f"{name}.png"))
        pose_for_render(skin, arm)
        arm.rotation_euler = (0, 0, 0)
    bpy.ops.file.pack_all()  # 画像も .blend に入れる（textures はコミットしないので、clone 直後でも質感が欠けないように）
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, f"{NAME}.blend"), compress=True)


main()
