# キャラの作り方

Blender のスクリプトから、元データ（`.blend`）と USDZ を作る。実行はリポジトリのルートで。

```sh
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python avatar/build_<キャラ>.py
cd ios && xcodegen generate
```

| 形式 | スクリプト | 動かし方 |
|---|---|---|
| ボクセル（パーツ） | `voxel_common.py` と `build_teacher.py`（ハル）、`build_rika.py`（リカ）、`build_boru.py`（ボル） | パーツの transform（`AvatarPose`）、顔はテクスチャの差し替え |
| 骨とシェイプキー | `rig_common.py` と `build_<キャラ>.py` | `SkeletalPosesComponent` と `BlendShapeWeightsComponent`（`RigPose`、`RiggedModel`） |

`build_rig_proto.py` は表示の確認用の試作で、選ぶ画面には出さない。

## ボクセルのキャラの書き出し（#124）

```sh
BL=/Applications/Blender.app/Contents/MacOS/Blender
$BL -b --factory-startup --python avatar/build_rika.py    # rika.usdz と rika_*.png と avatar/rika.blend
$BL -b --factory-startup --python avatar/build_boru.py    # boru.usdz と boru_*.png と avatar/boru.blend
cd ios && xcodegen generate
```

`.blend` にはテクスチャも入っているので、そのまま開ける。確認は `$BL -b --factory-startup --python avatar/render_voxels.py -- <出力先>.png` で 3 人を並べて Cycles で写す（アルファからシルエットが作れる）。

`build_teacher.py` を流しても `teacher.usdz` の中身は同じ。ただし Blender はプリムの順番を毎回そろえないので、ファイルのバイト列は変わる。比べるときはパス順に並べて比べ、変えていないならコミットしない。

新しいキャラの作り方：

- パーツの名前と原点は `voxel_common.py` の先頭のとおり。リソースは平らに同梱されるので、usdz と顔のテクスチャの名前は `<id>.usdz`、`<id>_eyes_open.png` のように一意にする
- 質感は `Surfaces.add(名前, 色, 種類, roughness, metallic)`。`Part(name, surface_uv=True)` のパーツに `grain_png` のむらのあるテクスチャが貼られる
- `characters.json` の `look.faceTextures` に頭文字を書く。`glowingFace: true` なら顔を `UnlitMaterial` で見せる（LED の画面）

落とし穴：

- **Blender の Alpha に値を入れただけでは USD に出ない**（`opacity = 1` になる）。アルファのある画像をつなぐ（`Surfaces.add` の `alpha`）
- **重なった箱の面を同じ位置にしない**。Cycles で黒い点になる。少しずらす
- **読み込めないと黙って今の先生が出る**。`VoxelCharacterAssetTests` で全キャラの全パーツと顔を確かめる
- **まわりの光**：`VoxelAvatarView` は、今の先生には太陽の光だけで、ほかのキャラには `StudioLighting` を当てる。RealityView が 1 枚のときの今の先生は既定のまわりの光でも明るいが、何枚も並ぶと起動ごとに暗くなることがある（Simulator で確認。原因は未解明）。選ぶ画面では全員に `StudioLighting` を当ててそろえる
- 腕は短くて頭に届かない。頭の横まで上げて、画面で見て決める

## 骨とシェイプキーのきまり（#121 の試作で確かめた）

- 骨の名前：`root` `body` `head` `armL` `armR` `legL` `legR` `earL` `earR` `tail`（ないものは無視する）。`root` は足元から上（+Z）に向ける。つぶれと伸びは `root` のスケールで作る
- シェイプキーの名前：`mouth_a` `mouth_i` `mouth_u` `mouth_e` `mouth_o` `mouth_n` `eye_blink` `eye_happy` `brow_worry`
- キャラは -Y を向き、+Z が上、+X がキャラの左、足元が Z=0
- 回転はキャラの座標で書く。骨ごとの向きは `RiggedModel` が吸収する

## 落とし穴

- **メッシュは 1 つに結合する**。シェイプキーを持つメッシュが複数あると、RealityKit では片方の組しか動かない。マテリアルは複数のままでよい
- **モディファイアを適用してからシェイプキーを作る**。シェイプキーのあとは適用できない
- **`shape_key_add` は `from_mix=False` にする**。既定の `True` だと、関係のない頂点まで動くことがあった（口が縦に伸びた）。`add_shape` は確かめて、動いていたら止める
- **手続き型のシェーダーは USD に出ない**。`bake_pbr` で色・粗さ・法線の画像に焼く
- **ウェイトの混ぜ幅を広くする**。狭いと関節の内側が折れ重なる
- **シェイプキーと骨は名前で引く**。USD の中の順番は一定ではない
- USD のルートの Y-up の回転を消さない。向きと位置は外側の親で動かす
- 目と口のマテリアルを番号で決めない。書き出しで順番が変わる
- 毛のシェーダー（`CustomMaterial`）は、この Mac に Metal Toolchain がないので使っていない。毛は `bake_pbr` の法線と粗さで表す

## 面数とテクスチャの目安

iPad の実機では未確認（#129）。Simulator で、骨 4 本・シェイプキー 3 個・PBR 3 枚のとき、26 万三角形でも更新は 1 秒に約 60 回で崩れなかった。これは Mac の GPU での参考値。

キャラは 3 万三角形以下、テクスチャは 1024〜2048 を目安にする。ボクセルのキャラは 5 千三角形以下で、質感のテクスチャは 256 四方。
