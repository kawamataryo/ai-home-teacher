"""ボクセルのキャラを並べて Cycles でレンダリングする確認用スクリプト（#124）。USDZ を読むので、書き出したものを見られる。

使い方（リポジトリのルートで）:
    Blender -b --factory-startup --python avatar/render_voxels.py -- <出力先の .png> [teacher rika boru]

透明の背景で書き出す。シルエットは出力のアルファから作れる。`--back` を付けると後ろから写す。
"""

import math
import os
import sys

import bpy

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
args = sys.argv[sys.argv.index("--") + 1:]
back = "--back" in args
args = [a for a in args if a != "--back"]
out, names = args[0], args[1:] or ["teacher", "rika", "boru"]

bpy.ops.wm.read_factory_settings(use_empty=True)
spacing = 1.45
for i, name in enumerate(names):
    bpy.ops.wm.usd_import(filepath=os.path.join(ROOT, "ios", "HomeTeacher", "Resources", "Teacher", f"{name}.usdz"))
    top = next(o for o in bpy.context.scene.objects if o.parent is None and o.name.startswith("Teacher") and "placed" not in o)
    top["placed"] = True
    top.location.x += (i - (len(names) - 1) / 2) * spacing

scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = 48
scene.render.film_transparent = True
scene.render.resolution_x = 700 * len(names) if len(names) > 1 else 900
scene.render.resolution_y = 900
scene.render.filepath = out

world = bpy.data.worlds.new("world")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs[0].default_value = (0.85, 0.87, 0.9, 1)
world.node_tree.nodes["Background"].inputs[1].default_value = 0.8
scene.world = world

sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
sun.data.energy = 3.0
sun.rotation_euler = (math.radians(55), 0, math.radians(-25) if not back else math.radians(155))
scene.collection.objects.link(sun)

camera = bpy.data.objects.new("camera", bpy.data.cameras.new("camera"))
camera.data.lens = 70
distance = 4.2 + 1.9 * (len(names) - 1)
sign = 1 if back else -1
camera.location = (0.5, sign * distance, 1.0)
direction = (0 - camera.location.x, 0 - camera.location.y, 0.68 - camera.location.z)
from mathutils import Vector  # noqa: E402
camera.rotation_euler = Vector(direction).to_track_quat("-Z", "Y").to_euler()
scene.collection.objects.link(camera)
scene.camera = camera
bpy.ops.render.render(write_still=True)
print("レンダリング:", out)
