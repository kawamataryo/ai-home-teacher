"""まるいキャラの顔（目・光の点・口・舌）を肌に沿わせて作り、シェイプキーを足す（#131, #132）。

顔はシンプルにする。目と口は別の部品で、肌の前面に貼りつく。部品は体に結合してからシェイプキーで形を変える。
ウェイトは肌と同じ計算にする（1 本の骨に固定すると、頭を傾けたときに肌に沈む）。
"""

from dataclasses import dataclass

import bpy
import numpy as np
from mathutils.bvhtree import BVHTree

import rig_common as rig


class Surface:
    """肌の前面の位置を調べる"""

    def __init__(self, skin):
        depsgraph = bpy.context.evaluated_depsgraph_get()
        self.bvh = BVHTree.FromObject(skin, depsgraph)

    def front_y(self, x, z):
        hit = self.bvh.ray_cast((x, -3.0, z), (0, 1, 0))
        return hit[0].y if hit[0] is not None else -0.5


@dataclass
class FaceSpec:
    prefix: str
    eye_x: float
    eye_z: float
    mouth_z: float
    eye_rx: float = 0.052
    eye_rz: float = 0.066
    mouth_rx: float = 0.058
    mouth_rz: float = 0.011
    mouth_bend: float = 0.009
    eye_color: tuple = (0.015, 0.016, 0.035)
    mouth_color: tuple = (0.36, 0.05, 0.12)
    tongue_color: tuple = (0.93, 0.42, 0.48)


def disc(name, center, radii, material, part, segments=32, rings=20, thickness=0.012):
    """肌に貼りつく、平たい楕円の部品"""
    obj = rig.ellipsoid((center[0], 0, center[1]), (radii[0], thickness, radii[1]), segments=segments, rings=rings, name=name)
    obj.data.materials.append(material)
    rig.mark_part(obj, part)
    return obj


def conform(p, surface, lift=0.004):
    """(x, y, z) の y を肌の前面に合わせる。y はもとの厚みとして残す"""
    return np.array([p[0], surface.front_y(p[0], p[2]) - lift + p[1], p[2]])


def add_face(skin, surface, spec, extra_parts=()):
    """顔の部品を作って結合し、口と目のシェイプキーを足す。`extra_parts` は一緒に結合する部品（鼻・ひげなど）"""
    eye_mat = rig.flat_material(f"{spec.prefix}_eye", spec.eye_color, 0.12)
    shine_mat = rig.flat_material(f"{spec.prefix}_shine", (1, 1, 1), 0.25)
    mouth_mat = rig.flat_material(f"{spec.prefix}_mouth", spec.mouth_color, 0.45)
    tongue_mat = rig.flat_material(f"{spec.prefix}_tongue", spec.tongue_color, 0.5)

    ex, ez, rx, rz, mz = spec.eye_x, spec.eye_z, spec.eye_rx, spec.eye_rz, spec.mouth_z
    mrx, mrz, bend = spec.mouth_rx, spec.mouth_rz, spec.mouth_bend

    eyes = []
    shines = []
    for side in (1, -1):
        eyes.append(disc("Eye", (side * ex, ez), (rx, rz), eye_mat, "eye", thickness=0.014))
        shines.append(disc("Shine", (side * ex + 0.31 * rx, ez + 0.36 * rz), (0.3 * rx, 0.27 * rz), shine_mat, "shine", segments=16, rings=10, thickness=0.005))
    mouth = disc("Mouth", (0, mz), (mrx, mrz), mouth_mat, "mouth", thickness=0.008)
    tongue = disc("Tongue", (0, mz - 0.004), (mrx * 0.5, mrz * 0.4), tongue_mat, "tongue", segments=20, rings=12, thickness=0.004)

    def place(part, lift, curve=0.0):
        for v in part.data.vertices:
            p = np.array(v.co)
            x = p[0] / mrx if curve else 0
            v.co = tuple(conform(np.array([p[0], p[1], p[2] + curve * x * x]), surface, lift))
        part.data.update()

    for part in eyes:
        place(part, 0.004)
    for part in shines:
        place(part, 0.02)
    place(mouth, 0.004, bend)
    place(tongue, 0.012, bend)

    rig.join_parts(skin, eyes + shines + [mouth, tongue] + list(extra_parts))
    basis = rig.begin_shapes(skin)
    eye_ids = rig.part_vertices(skin, "eye")
    shine_ids = rig.part_vertices(skin, "shine")
    mouth_ids = rig.part_vertices(skin, "mouth")
    tongue_ids = rig.part_vertices(skin, "tongue")

    def thickness(p, lift):
        """もとの位置の、肌からの厚み"""
        return p[1] - surface.front_y(p[0], p[2]) + lift

    def add_mouth(name, width, height, drop, tongue_down):
        """口を開く。笑顔の弧をほどきながら楕円に広げる"""
        def fn(p):
            x = p[0] / mrx
            flat = p[2] - bend * x * x
            nz = mz + (flat - mz) * height - drop * 0.3
            return conform(np.array([p[0] * width, thickness(p, 0.004), nz]), surface, 0.004)

        rig.add_shape(skin, name, basis, mouth_ids, fn)
        key = skin.data.shape_keys.key_blocks[name]
        for i in tongue_ids:
            p = basis[i]
            x = p[0] / mrx
            flat = p[2] - bend * x * x
            nz = mz - drop * 0.3 - mrz * height * tongue_down + (flat - (mz - 0.004)) * height * 0.9
            key.data[i].co = tuple(conform(np.array([p[0] * width * 0.95, thickness(p, 0.012), nz]), surface, 0.012))

    add_mouth("mouth_a", 1.25, 7.5, 0.05, 0.55)
    add_mouth("mouth_i", 1.5, 2.6, 0.0, 0.0)
    add_mouth("mouth_u", 0.58, 3.4, 0.0, 0.2)
    add_mouth("mouth_e", 1.3, 4.6, 0.01, 0.35)
    add_mouth("mouth_o", 0.82, 6.0, 0.03, 0.45)
    add_mouth("mouth_n", 0.62, 0.7, -0.01, 0.0)

    def center(p):
        return np.sign(p[0]) * ex, ez

    def blink(p):
        cx, cz = center(p)
        u = (p[0] - cx) / rx
        nz = cz - 0.012 + (p[2] - cz) * 0.13 - 0.018 * u * u
        return conform(np.array([cx + (p[0] - cx) * 1.15, thickness(p, 0.004), nz]), surface, 0.004)

    def happy(p):
        cx, cz = center(p)
        u = (p[0] - cx) / rx
        nz = cz + (p[2] - cz) * 0.2 + 0.03 * (1 - u * u) - 0.012
        return conform(np.array([cx + (p[0] - cx) * 1.2, thickness(p, 0.004), nz]), surface, 0.004)

    def worry(p):
        # 目尻を下げる（困り顔）
        cx, cz = center(p)
        tilt = -np.sign(cx) * (p[0] - cx) * 0.55
        return conform(np.array([p[0], thickness(p, 0.004), cz + (p[2] - cz) * 0.82 + tilt]), surface, 0.004)

    def hidden_shine(p):
        """まばたきでは光の点を目の中に沈める"""
        cx, cz = center(p)
        return conform(np.array([cx + (p[0] - cx) * 0.05, thickness(p, 0.02), cz + (p[2] - cz) * 0.05]), surface, -0.01)

    for name, fn in (("eye_blink", blink), ("eye_happy", happy)):
        rig.add_shape(skin, name, basis, eye_ids, fn)
        key = skin.data.shape_keys.key_blocks[name]
        for i in shine_ids:
            key.data[i].co = tuple(hidden_shine(basis[i]))
    rig.add_shape(skin, "brow_worry", basis, eye_ids, worry)
