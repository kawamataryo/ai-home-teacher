import Foundation
import RealityKit
import Testing
@testable import HomeTeacher

/// 骨とシェイプキーで動く 3D の表示（#121）
@MainActor
struct RiggedModelTests {
    private func load() async throws -> RiggedModel {
        try await RiggedModel.load(name: "proto_rig")
    }

    @Test func 試作のusdzから骨とシェイプキーが見つかる() async throws {
        let model = try await load()
        #expect(model.missingBones.isEmpty, "\(model.missingBones)")
        for shape in RigShape.allCases where shape != .browWorry {
            #expect(model.shapeNames.contains(shape.rawValue), "\(shape)")
        }
    }

    @Test func 骨のパスの最後の名前で当てはめる() {
        let paths = RiggedModel.bonePaths(["root", "root/body", "root/body/head", "root/body/head/earL", "root/other"])
        #expect(paths[.head] == "root/body/head")
        #expect(paths[.earL] == "root/body/head/earL")
        #expect(paths[.tail] == nil)
    }

    @Test func キャラの座標の回転を骨のローカルに直す() {
        // 休止姿勢で骨が回っていても、キャラの座標で見て同じだけ回る
        let parent = simd_quatf(angle: .pi / 2, axis: [1, 0, 0])
        let rest = simd_quatf(angle: 0.4, axis: [0, 0, 1])
        let world = parent * rest
        let delta = simd_quatf(angle: 0.3, axis: [0, 1, 0])
        let local = RiggedModel.localRotation(rest: rest, world: world, delta: delta)
        let result = parent * local
        let expected = delta * world
        #expect(abs(abs(simd_dot(result.vector, expected.vector)) - 1) < 1e-5)
    }

    @Test func 骨とシェイプキーを書き込める() async throws {
        let model = try await load()
        var pose = RigPose()
        pose.set(.head, roll: 0.3)
        pose.squash = 0.8
        model.apply(pose, shapeWeights: ["mouth_a": 1, "eye_blink": 0.5])
        let target = try #require(Self.rigged(model.entity))
        let joints = try #require(target.components[SkeletalPosesComponent.self]?.poses.default)
        let rootIndex = try #require(joints.jointNames.firstIndex { !$0.contains("/") })
        #expect(abs(joints.jointTransforms[rootIndex].scale.y - 0.8) < 0.3)
        let weights = try #require(target.components[BlendShapeWeightsComponent.self])
        let data = try #require(weights.weightSet.first)
        let index = try #require(data.weightNames.firstIndex(of: "mouth_a"))
        #expect(data.weights[index] == 1)
    }

    @Test func 読み込めないモデルはエラーになる() async {
        await #expect(throws: (any Error).self) { _ = try await RiggedModel.load(name: "いないモデル") }
        // 骨のないモデルも rigged としては読まない（既定の先生に戻す）
        await #expect(throws: (any Error).self) { _ = try await RiggedModel.load(name: "teacher") }
    }

    @Test func 口パクの形がシェイプキーに流れる() async throws {
        let model = try await load()
        let animator = RiggedAnimator(model: model)
        animator.mouthOverride = .a
        for _ in 0..<30 { animator.update(deltaTime: 1.0 / 60) }
        let target = try #require(Self.rigged(model.entity))
        let data = try #require(target.components[BlendShapeWeightsComponent.self]?.weightSet.first)
        let a = try #require(data.weightNames.firstIndex(of: "mouth_a"))
        let i = try #require(data.weightNames.firstIndex(of: "mouth_i"))
        #expect(data.weights[a] > 0.9)
        #expect(data.weights[i] < 0.1)
    }

    private static func rigged(_ entity: Entity) -> Entity? {
        if entity.components.has(SkeletalPosesComponent.self) { return entity }
        for child in entity.children { if let found = rigged(child) { return found } }
        return nil
    }
}

struct RigPoseTests {
    @Test func つぶれは体積を保つ() {
        let scale = RigPose.squashScale(0.8)
        #expect(abs(scale.x * scale.y * scale.z - 1) < 1e-5)
        #expect(scale.y == 0.8)
        #expect(scale.x > 1)
    }

    @Test(arguments: AvatarState.allCases)
    func どの状態でも値が壊れない(state: AvatarState) {
        for t in stride(from: 0.0, to: 8, by: 0.37) {
            let pose = RigPose.make(state: state, timeInState: t, time: t + 3)
            #expect(pose.squash > 0.6 && pose.squash < 1.4)
            #expect(pose.lift >= -0.01 && pose.lift < 0.3)
            for value in pose.shapes.values { #expect(value >= 0 && value <= 1) }
        }
    }

    @Test func 状態ごとに姿勢が違う() {
        let poses = AvatarState.allCases.map { RigPose.make(state: $0, timeInState: 1.1, time: 1.1) }
        for i in poses.indices {
            for j in poses.indices where i < j {
                #expect(poses[i] != poses[j], "\(AvatarState.allCases[i]) と \(AvatarState.allCases[j])")
            }
        }
    }

    @Test func はずむと途切れずに戻る() {
        // 着地でつぶれ、飛ぶと伸び、次のコマとの差が小さい
        var previous = RigPose.make(state: .praise, timeInState: 0, time: 0)
        var minimum: Float = 2
        var maximum: Float = 0
        for t in stride(from: 1.0 / 60, to: 3, by: 1.0 / 60) {
            let pose = RigPose.make(state: .praise, timeInState: t, time: t)
            #expect(abs(pose.squash - previous.squash) < 0.09, "t=\(t)")
            minimum = min(minimum, pose.squash)
            maximum = max(maximum, pose.squash)
            previous = pose
        }
        #expect(minimum < 0.85)
        #expect(maximum > 1.1)
    }

    @Test func 口の形はシェイプキーに対応する() {
        for shape in MouthShape.allCases where shape != .closed {
            #expect(RigShape.shape(for: shape) != nil)
        }
        #expect(RigShape.shape(for: .closed) == nil)
    }
}

struct PaperPoseTests {
    @Test(arguments: AvatarState.allCases)
    func 状態が読み取れる(state: AvatarState) {
        _ = PaperPose.make(state: state, timeInState: 1, time: 1)
    }

    @Test func 状態ごとに姿勢が違う() {
        let poses = AvatarState.allCases.map { PaperPose.make(state: $0, timeInState: 1.1, time: 1.1) }
        for i in poses.indices {
            for j in poses.indices where i < j {
                #expect(poses[i] != poses[j], "\(AvatarState.allCases[i]) と \(AvatarState.allCases[j])")
            }
        }
    }

    @Test func 紙人形らしくコマ送りで動く() {
        let a = PaperPose.make(state: .talking, timeInState: 1.001, time: 1.001)
        let b = PaperPose.make(state: .talking, timeInState: 1.002, time: 1.002)
        #expect(a == b)
    }
}

@MainActor
struct CharacterLookTests {
    @Test func 既定の先生の見た目は今のまま() {
        #expect(CharacterLook.haru == CharacterLook(kind: .voxel, model: "teacher", faceTextures: "face"))
        #expect(CharacterCatalog().character(id: "haru").look == .haru)
        #expect(MouthShape.a.textureName == "face_mouth_a")
        #expect(EyeShape.happy.textureName == "face_eyes_happy")
    }

    @Test func 口パクは3Dのモデルにも2Dの読み取りにも流れる() async throws {
        let player = LipSyncPlayer()
        player.play(LipSyncConverter.timeline(from: LipSyncDemo.alignment(for: "あ"))) { 0.05 }
        #expect(player.update() == .a)
        let model = try await RiggedModel.load(name: "proto_rig")
        player.model = model
        player.update()
        #expect(model.mouth == .a)
    }

    @Test func 起動引数から見た目を読む() {
        #expect(CharacterLook.fromLaunchArguments(["x", "-avatarLook", "rigged:proto_rig"]) == CharacterLook(kind: .rigged, model: "proto_rig"))
        #expect(CharacterLook.fromLaunchArguments(["x", "-avatarLook", "paper"]) == CharacterLook(kind: .paper))
        #expect(CharacterLook.fromLaunchArguments(["x"]) == nil)
    }
}
