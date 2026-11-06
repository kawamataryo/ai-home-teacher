"""骨とシェイプキーで動く 3D キャラを Blender で作るための共通部品（#121）。

流れ（順番に意味がある）:
1. `sculpt_body`：まるい形を組み合わせ、ボクセルのリメッシュでひとつづきの肌にして、なめらかにする
2. `bake_pbr`：Blender の手続き型のマテリアルを、画像テクスチャ（色・粗さ・法線）に焼く。手続き型のノードは USD に出ないため
3. `join_parts`：目や口を体に結合する。シェイプキーを持つメッシュが複数あると RealityKit で片方しか動かないため 1 つにする
4. `add_shape`：シェイプキーを足す。モディファイアは先に適用しておく
5. `add_armature`：骨とウェイトを足す。混ぜ幅を広めにする（狭いと関節の内側が折れる）
6. `export_usdz`：USDZ に書き出す。後処理はいらない

骨の名前とシェイプキーの名前はアプリとの約束（ios/HomeTeacher/Avatar/RigPose.swift）。
キャラは Blender の -Y を向き、+Z が上、+X がキャラの左、足元が Z=0。

使うときは `sys.path` に avatar/ を足して import する。実行は `Blender -b --factory-startup --python avatar/build_<キャラ>.py`。
"""

import math
import os

import bpy
import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
USDZ_DIR = os.path.join(ROOT, "ios", "HomeTeacher", "Resources", "Characters")


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)


def select_only(obj):
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def ellipsoid(center, radii, rotation=(0, 0, 0), segments=48, rings=32, name="part"):
    """なめらかな楕円体"""
    bpy.ops.mesh.primitive_uv_sphere_add(segments=segments, ring_count=rings, radius=1.0, location=center, rotation=rotation)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = radii
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    obj.data.polygons.foreach_set("use_smooth", [True] * len(obj.data.polygons))
    obj.data.update()
    return obj


def capsule_blob(start, end, r0, r1, steps=6, name="limb"):
    """始点から終点へ太さを変えて並べた球（腕・足・しっぽの元）"""
    parts = []
    for i in range(steps + 1):
        t = i / steps
        center = tuple(start[k] + (end[k] - start[k]) * t for k in range(3))
        r = r0 + (r1 - r0) * t
        parts.append(ellipsoid(center, (r, r, r), segments=24, rings=16, name=name))
    return parts


def join(objects, name="joined"):
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()
    result = bpy.context.active_object
    result.name = name
    return result


def sculpt_body(objects, voxel_size=0.012, smooth_iterations=24, name="Skin"):
    """形を結合してひとつづきの肌にする。リメッシュで面のつながりを揃え、なめらかにしてから適用する"""
    obj = join(objects, name)
    remesh = obj.modifiers.new("Remesh", "REMESH")
    remesh.mode = "VOXEL"
    remesh.voxel_size = voxel_size
    remesh.use_smooth_shade = True
    smooth = obj.modifiers.new("Smooth", "LAPLACIANSMOOTH")
    smooth.iterations = smooth_iterations
    smooth.lambda_factor = 0.7
    smooth.use_volume_preserve = True
    select_only(obj)
    for mod in list(obj.modifiers):
        bpy.ops.object.modifier_apply(modifier=mod.name)
    obj.data.polygons.foreach_set("use_smooth", [True] * len(obj.data.polygons))
    obj.data.update()
    return obj


def decimate_to(obj, target_faces):
    """面数を目標まで減らす"""
    faces = len(obj.data.polygons)
    if faces <= target_faces:
        return
    mod = obj.modifiers.new("Decimate", "DECIMATE")
    mod.ratio = target_faces / faces
    select_only(obj)
    bpy.ops.object.modifier_apply(modifier=mod.name)


def smart_uv(obj, angle=66, margin=0.008):
    """面を UV に展開する"""
    select_only(obj)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(angle), island_margin=margin)
    bpy.ops.object.mode_set(mode="OBJECT")


def new_material(name):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = next(node for node in mat.node_tree.nodes if node.type == "BSDF_PRINCIPLED")
    return mat, mat.node_tree, bsdf


def flat_material(name, rgb, roughness=0.5):
    """画像を使わない単色のマテリアル（目や口）"""
    mat, _, bsdf = new_material(name)
    bsdf.inputs["Base Color"].default_value = (*rgb, 1)
    bsdf.inputs["Roughness"].default_value = roughness
    return mat


def bake_pbr(obj, source_material, name, size, out_dir, samples=8):
    """手続き型のマテリアルを色・粗さ・法線の画像に焼き、画像テクスチャのマテリアルに置き換える"""
    os.makedirs(out_dir, exist_ok=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = samples
    scene.render.bake.margin = 8
    obj.data.materials.clear()
    obj.data.materials.append(source_material)
    nt = source_material.node_tree
    bake_node = nt.nodes.new("ShaderNodeTexImage")
    nt.nodes.active = bake_node
    select_only(obj)

    images = {}
    for kind, bake_type, colorspace, kwargs in (
        ("basecolor", "DIFFUSE", "sRGB", {"pass_filter": {"COLOR"}}),
        ("roughness", "ROUGHNESS", "Non-Color", {}),
        ("normal", "NORMAL", "Non-Color", {"normal_space": "TANGENT"}),
    ):
        image = bpy.data.images.new(f"{name}_{kind}", size, size, alpha=False, float_buffer=False)
        image.colorspace_settings.name = colorspace
        bake_node.image = image
        bpy.ops.object.bake(type=bake_type, **kwargs)
        path = os.path.join(out_dir, f"{name}_{kind}.png")
        image.filepath_raw = path
        image.file_format = "PNG"
        image.save()
        images[kind] = image

    mat, tree, bsdf = new_material(f"{name}_pbr")

    def tex(image, y):
        node = tree.nodes.new("ShaderNodeTexImage")
        node.image = image
        node.location = (-500, y)
        return node

    tree.links.new(tex(images["basecolor"], 300).outputs["Color"], bsdf.inputs["Base Color"])
    tree.links.new(tex(images["roughness"], 0).outputs["Color"], bsdf.inputs["Roughness"])
    normal_map = tree.nodes.new("ShaderNodeNormalMap")
    tree.links.new(tex(images["normal"], -300).outputs["Color"], normal_map.inputs["Color"])
    tree.links.new(normal_map.outputs["Normal"], bsdf.inputs["Normal"])
    bsdf.inputs["Metallic"].default_value = 0
    obj.data.materials.clear()
    obj.data.materials.append(mat)
    return mat


def mark_part(obj, part):
    """結合したあとも見分けられるように、頂点グループで印を付ける"""
    group = obj.vertex_groups.new(name=f"part_{part}")
    group.add([v.index for v in obj.data.vertices], 1.0, "REPLACE")


def join_parts(skin, parts):
    """目や口を体に結合する。マテリアルは保たれる"""
    bpy.ops.object.select_all(action="DESELECT")
    for part in parts:
        part.select_set(True)
    skin.select_set(True)
    bpy.context.view_layer.objects.active = skin
    bpy.ops.object.join()
    return skin


def part_vertices(obj, part):
    group = obj.vertex_groups.get(f"part_{part}")
    if group is None:
        return set()
    index = group.index
    return {v.index for v in obj.data.vertices if any(g.group == index for g in v.groups)}


def begin_shapes(obj):
    obj.shape_key_add(name="Basis")
    return np.array([v.co for v in obj.data.vertices])


def add_shape(obj, name, basis, indices, fn):
    """シェイプキーを足す。`fn(p) -> 新しい位置` を `indices` の頂点に当てる"""
    key = obj.shape_key_add(name=name, from_mix=False)
    key.data.foreach_set("co", basis.ravel())
    for i in indices:
        key.data[i].co = tuple(fn(basis[i]))
    # 関係のない頂点が動いていないことを確かめる（RealityKit で口や目が崩れる）
    moved = {i for i, data in enumerate(key.data) if np.abs(np.array(data.co) - basis[i]).max() > 1e-6}
    extra = moved - set(indices)
    if extra:
        raise RuntimeError(f"{name}: 関係のない頂点が {len(extra)} 個動いた")


def smoothstep(x):
    x = np.clip(x, 0.0, 1.0)
    return x * x * (3 - 2 * x)


def segment_distance(p, a, b):
    ab = b - a
    t = float(np.clip((p - a) @ ab / max(float(ab @ ab), 1e-9), 0, 1))
    return float(np.linalg.norm(p - (a + ab * t)))


def add_armature(obj, bones, rigid_parts=None, name="Rig"):
    """骨を足し、ウェイトを距離から計算する。

    bones: {骨の名前: {"head": (x,y,z), "tail": (x,y,z), "parent": 親, "reach": 届く距離, "deform": 変形に使うか}}
    rigid_parts: {部品の名前: 骨の名前}。目や口など、1 本の骨にだけ付ける部品
    混ぜ幅を広めにする（reach の中で滑らかに落とす）
    """
    data = bpy.data.armatures.new(name)
    arm = bpy.data.objects.new(name, data)
    bpy.context.collection.objects.link(arm)
    select_only(arm)
    bpy.ops.object.mode_set(mode="EDIT")
    for bone_name, spec in bones.items():
        bone = data.edit_bones.new(bone_name)
        bone.head, bone.tail = spec["head"], spec["tail"]
    for bone_name, spec in bones.items():
        if spec.get("parent"):
            data.edit_bones[bone_name].parent = data.edit_bones[spec["parent"]]
    bpy.ops.object.mode_set(mode="OBJECT")

    groups = {n: obj.vertex_groups.new(name=n) for n in bones}
    segments = {
        n: (np.array(s["head"], float), np.array(s["tail"], float), float(s.get("reach", 0.2)))
        for n, s in bones.items() if s.get("deform", True)
    }
    rigid = {}
    for part, bone_name in (rigid_parts or {}).items():
        for i in part_vertices(obj, part):
            rigid[i] = bone_name
    for v in obj.data.vertices:
        if v.index in rigid:
            groups[rigid[v.index]].add([v.index], 1.0, "REPLACE")
            continue
        p = np.array(v.co)
        weights = {}
        for bone_name, (a, b, reach) in segments.items():
            w = float(smoothstep(1 - segment_distance(p, a, b) / reach))
            if w > 1e-3:
                weights[bone_name] = w * w
        if not weights:
            nearest = min(segments, key=lambda n: segment_distance(p, segments[n][0], segments[n][1]))
            weights = {nearest: 1.0}
        total = sum(weights.values())
        for bone_name, w in weights.items():
            groups[bone_name].add([v.index], w / total, "REPLACE")

    # 部品の印は書き出さない
    for group in list(obj.vertex_groups):
        if group.name.startswith("part_"):
            obj.vertex_groups.remove(group)
    mod = obj.modifiers.new("Armature", "ARMATURE")
    mod.object = arm
    obj.parent = arm
    return arm


def export_usdz(path):
    """USDZ に書き出す。設定は #121 の試作で RealityKit で動くと確かめたもの"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.wm.usd_export(
        filepath=path,
        selected_objects_only=False,
        export_animation=False,
        export_hair=False,
        export_uvmaps=True,
        rename_uvmaps=True,
        export_mesh_colors=False,
        export_normals=True,
        export_materials=True,
        export_subdivision="IGNORE",
        export_armatures=True,
        only_deform_bones=False,
        export_shapekeys=True,
        use_instancing=False,
        evaluation_mode="RENDER",
        generate_preview_surface=True,
        generate_materialx_network=False,
        convert_orientation=True,
        export_global_forward_selection="NEGATIVE_Z",
        export_global_up_selection="Y",
        export_textures_mode="NEW",
        overwrite_textures=True,
        relative_paths=True,
        root_prim_path="/root",
        export_custom_properties=False,
        author_blender_name=False,
        convert_world_material=False,
        triangulate_meshes=False,
        export_lights=False,
        export_cameras=False,
    )


def mesh_stats(obj):
    triangles = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    return {"vertices": len(obj.data.vertices), "triangles": triangles}


def setup_render(resolution=900, samples=48, target=(0, 0, 0.6), distance=4.2, background=(0.92, 0.94, 0.98)):
    """確認用のレンダリングの準備（正面やや上から）"""
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = samples
    scene.render.resolution_x = scene.render.resolution_y = resolution
    scene.render.film_transparent = False
    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (*background, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.9
    scene.world = world
    cam_data = bpy.data.cameras.new("Cam")
    cam_data.lens = 70
    cam = bpy.data.objects.new("Cam", cam_data)
    bpy.context.collection.objects.link(cam)
    t = np.array(target, float)
    cam.location = tuple(t + np.array([0.12, -1, 0.1]) * distance)
    constraint = cam.constraints.new("TRACK_TO")
    empty = bpy.data.objects.new("Target", None)
    bpy.context.collection.objects.link(empty)
    empty.location = tuple(t)
    constraint.target = empty
    constraint.track_axis = "TRACK_NEGATIVE_Z"
    constraint.up_axis = "UP_Y"
    scene.camera = cam
    sun_data = bpy.data.lights.new("Sun", "SUN")
    sun_data.energy = 2.2
    sun = bpy.data.objects.new("Sun", sun_data)
    bpy.context.collection.objects.link(sun)
    sun.rotation_euler = (math.radians(50), 0, math.radians(30))


def render(path):
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
