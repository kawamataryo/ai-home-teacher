# キャラの作り方

Blender のスクリプトから、元データ（`.blend`）と USDZ を作る。実行はリポジトリのルートで。

```sh
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup --python avatar/build_<キャラ>.py
cd ios && xcodegen generate
```

| 形式 | スクリプト | 動かし方 |
|---|---|---|
| ボクセル（パーツ） | `build_teacher.py` | パーツの transform（`AvatarPose`）、顔はテクスチャの差し替え |
| 骨とシェイプキー | `rig_common.py` と `build_<キャラ>.py` | `SkeletalPosesComponent` と `BlendShapeWeightsComponent`（`RigPose`、`RiggedModel`） |

`build_rig_proto.py` は表示の確認用の試作で、選ぶ画面には出さない。

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

キャラは 3 万三角形以下、テクスチャは 1024〜2048 を目安にする。
