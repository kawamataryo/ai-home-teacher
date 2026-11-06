"""骨とシェイプキーで動く 3D の試作キャラ（#121）。選ぶ画面には出さない。`rig_common.py` と表示（RiggedAvatarView）の確認用。

使い方（リポジトリのルートで）:
    /Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python avatar/build_rig_proto.py
出力: ios/HomeTeacher/Resources/Characters/proto_rig.usdz
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import bpy
import numpy as np
import rig_common as rig

NAME = "proto_rig"
OUT = os.path.join(rig.ROOT, "avatar", "proto_rig")


def fur_material():
    """手続き型のマテリアル（色のむらと細かい起伏）。bake_pbr で画像に焼く"""
    mat, nt, bsdf = rig.new_material("proto_source")
    noise = nt.nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 60
    noise.inputs["Detail"].default_value = 6
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.16, 0.42, 0.62, 1)
    ramp.color_ramp.elements[1].color = (0.30, 0.62, 0.82, 1)
    nt.links.new(noise.outputs["Fac"], ramp.inputs["Fac"])
    nt.links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    rough = nt.nodes.new("ShaderNodeMapRange")
    rough.inputs["To Min"].default_value = 0.45
    rough.inputs["To Max"].default_value = 0.8
    nt.links.new(noise.outputs["Fac"], rough.inputs["Value"])
    nt.links.new(rough.outputs["Result"], bsdf.inputs["Roughness"])
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.25
    nt.links.new(noise.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


def main():
    rig.reset()
    shapes = [
        rig.ellipsoid((0, 0, 0.48), (0.42, 0.38, 0.46)),
        rig.ellipsoid((0, 0, 0.95), (0.38, 0.35, 0.34)),
    ]
    shapes += rig.capsule_blob((0.36, 0, 0.62), (0.6, -0.02, 0.36), 0.11, 0.09)
    shapes += rig.capsule_blob((-0.36, 0, 0.62), (-0.6, -0.02, 0.36), 0.11, 0.09)
    shapes += rig.capsule_blob((0.2, 0, 0.14), (0.22, -0.03, 0.05), 0.14, 0.12)
    shapes += rig.capsule_blob((-0.2, 0, 0.14), (-0.22, -0.03, 0.05), 0.14, 0.12)
    shapes += rig.capsule_blob((0.26, 0, 1.2), (0.36, 0, 1.42), 0.1, 0.05)
    shapes += rig.capsule_blob((-0.26, 0, 1.2), (-0.36, 0, 1.42), 0.1, 0.05)
    shapes += rig.capsule_blob((0, 0.34, 0.3), (0, 0.62, 0.5), 0.09, 0.05)
    skin = rig.sculpt_body(shapes, voxel_size=0.016)
    rig.decimate_to(skin, 12000)
    rig.smart_uv(skin)
    rig.bake_pbr(skin, fur_material(), NAME, 512, OUT)

    # 顔：目と口は別の部品にして、シェイプキーで形を変える。顔の前（-Y）に貼りつく小さな楕円体
    dark = rig.flat_material("proto_face", (0.03, 0.03, 0.05), 0.25)
    mouth_mat = rig.flat_material("proto_mouth", (0.32, 0.06, 0.09), 0.5)
    eye_y, eye_z, eye_x, eye_r = -0.335, 1.0, 0.13, 0.05
    mouth_y, mouth_z = -0.345, 0.85
    eyes = [rig.ellipsoid((s * eye_x, eye_y, eye_z), (eye_r, 0.02, eye_r * 1.25), segments=24, rings=16, name="Eye") for s in (1, -1)]
    mouth = rig.ellipsoid((0, mouth_y, mouth_z), (0.05, 0.015, 0.012), segments=24, rings=16, name="Mouth")
    for part in eyes:
        part.data.materials.append(dark)
        rig.mark_part(part, "eye")
    mouth.data.materials.append(mouth_mat)
    rig.mark_part(mouth, "mouth")
    rig.join_parts(skin, eyes + [mouth])

    basis = rig.begin_shapes(skin)
    eye_ids = rig.part_vertices(skin, "eye")
    mouth_ids = rig.part_vertices(skin, "mouth")
    print("部品の頂点", len(eye_ids), len(mouth_ids), "重なり", len(eye_ids & mouth_ids), "全部", len(skin.data.vertices))
    center = np.array([0, mouth_y, mouth_z])

    def mouth_shape(sx, sz, dz=0.0):
        def fn(p):
            d = p - center
            return center + np.array([d[0] * sx, d[1], d[2] * sz + dz])
        return fn

    for name, sx, sz in (("mouth_a", 1.0, 5.0), ("mouth_i", 1.35, 1.5), ("mouth_u", 0.55, 2.4), ("mouth_e", 1.15, 3.0), ("mouth_o", 0.8, 4.2), ("mouth_n", 0.7, 0.7)):
        rig.add_shape(skin, name, basis, mouth_ids, mouth_shape(sx, sz))

    def blink(p):
        cx = eye_x if p[0] > 0 else -eye_x
        c = np.array([cx, p[1], eye_z])
        d = p - c
        return c + np.array([d[0] * 1.1, d[1], d[2] * 0.12])

    def happy(p):
        # 上向きの弧（にっこり）
        cx = eye_x if p[0] > 0 else -eye_x
        x = (p[0] - cx) / eye_r
        c = np.array([cx, p[1], eye_z])
        d = p - c
        return c + np.array([d[0] * 1.2, d[1], d[2] * 0.18 + 0.045 * (1 - x * x) - 0.015])

    rig.add_shape(skin, "eye_blink", basis, eye_ids, blink)
    rig.add_shape(skin, "eye_happy", basis, eye_ids, happy)

    rig.add_armature(skin, {
        "root": {"head": (0, 0, 0), "tail": (0, 0, 0.1), "deform": False},
        "body": {"head": (0, 0, 0.1), "tail": (0, 0, 0.72), "parent": "root", "reach": 0.62},
        "head": {"head": (0, 0, 0.72), "tail": (0, 0, 1.2), "parent": "body", "reach": 0.55},
        "armL": {"head": (0.34, 0, 0.62), "tail": (0.6, -0.02, 0.36), "parent": "body", "reach": 0.26},
        "armR": {"head": (-0.34, 0, 0.62), "tail": (-0.6, -0.02, 0.36), "parent": "body", "reach": 0.26},
        "legL": {"head": (0.2, 0, 0.2), "tail": (0.22, -0.03, 0.02), "parent": "root", "reach": 0.22},
        "legR": {"head": (-0.2, 0, 0.2), "tail": (-0.22, -0.03, 0.02), "parent": "root", "reach": 0.22},
        "earL": {"head": (0.24, 0, 1.18), "tail": (0.36, 0, 1.44), "parent": "head", "reach": 0.18},
        "earR": {"head": (-0.24, 0, 1.18), "tail": (-0.36, 0, 1.44), "parent": "head", "reach": 0.18},
        "tail": {"head": (0, 0.32, 0.3), "tail": (0, 0.62, 0.5), "parent": "body", "reach": 0.2},
    }, rigid_parts={"eye": "head", "mouth": "head"})

    print("面数", rig.mesh_stats(skin))
    print("シェイプキー", [k.name for k in skin.data.shape_keys.key_blocks])
    rig.export_usdz(os.path.join(rig.USDZ_DIR, f"{NAME}.usdz"))


main()
