import Foundation
import RealityKit
import Testing
@testable import HomeTeacher

/// 動きの癖（#122）
struct MannerismSchedulerTests {
    private let set = MannerismSet(idle: [.glasses, .scratchHead, .yawn], touch: .startle)

    /// `from` から `to` 秒まで動かして、出た癖を順に返す
    private func run(_ scheduler: inout MannerismScheduler, state: AvatarState, from: Double, to: Double) -> [MannerismScheduler.Active] {
        var result: [MannerismScheduler.Active] = []
        var t = from
        while t < to {
            if let active = scheduler.update(state: state, time: t), result.last != active { result.append(active) }
            t += 0.1
        }
        return result
    }

    @Test func 待機中は間隔を空けて癖が出る() {
        var scheduler = MannerismScheduler(set: set, seed: 1)
        let shown = run(&scheduler, state: .idle, from: 0, to: 600)
        #expect(shown.count > 8)
        // 待機になってすぐは出ない
        #expect(shown[0].startedAt >= MannerismScheduler.intervalRange.lowerBound - 0.2)
        for (a, b) in zip(shown, shown.dropFirst()) {
            let gap = b.startedAt - (a.startedAt + a.kind.duration)
            #expect(gap >= MannerismScheduler.intervalRange.lowerBound - 0.2)
            #expect(gap <= MannerismScheduler.intervalRange.upperBound + 0.2)
        }
    }

    @Test(arguments: [UInt64(1), 2, 3, 99])
    func 同じ癖を続けて出さない(seed: UInt64) {
        var scheduler = MannerismScheduler(set: set, seed: seed)
        let shown = run(&scheduler, state: .idle, from: 0, to: 1000)
        for (a, b) in zip(shown, shown.dropFirst()) {
            #expect(a.kind != b.kind)
        }
        // 全部の癖が出る
        #expect(Set(shown.map(\.kind)) == Set(set.idle))
    }

    @Test(arguments: AvatarState.allCases.filter { $0 != .idle })
    func 話している間や子どもが話している間は癖が出ない(state: AvatarState) {
        var scheduler = MannerismScheduler(set: set, seed: 7)
        #expect(run(&scheduler, state: state, from: 0, to: 300).isEmpty)
    }

    @Test func 癖の途中で話し始めたらすぐやめる() {
        var scheduler = MannerismScheduler(set: set, seed: 3)
        var t = 0.0
        while scheduler.update(state: .idle, time: t) == nil { t += 0.1 }
        #expect(scheduler.active != nil)
        let result1 = scheduler.update(state: .listening, time: t + 0.1)
        #expect(result1 == nil)
        #expect(scheduler.active == nil)
    }

    @Test func 待機に戻っても間隔を空け直す() {
        var scheduler = MannerismScheduler(set: set, seed: 5)
        _ = run(&scheduler, state: .idle, from: 0, to: 100)
        _ = run(&scheduler, state: .talking, from: 100, to: 110)
        var t = 110.0
        var first: Double?
        while t < 200, first == nil {
            if scheduler.update(state: .idle, time: t) != nil { first = t }
            t += 0.1
        }
        #expect((first ?? 0) >= 110 + MannerismScheduler.intervalRange.lowerBound - 0.2)
    }

    @Test(arguments: AvatarState.allCases)
    func 触るとどの状態でも短く反応する(state: AvatarState) {
        var scheduler = MannerismScheduler(set: set, seed: 1)
        _ = scheduler.update(state: state, time: 0)
        let result2 = scheduler.touch(time: 1)
        #expect(result2)
        let result3 = scheduler.update(state: state, time: 1.1)
        #expect(result3?.kind == .startle)
        let result4 = scheduler.update(state: state, time: 1 + MannerismKind.startle.duration + 0.01)
        #expect(result4 == nil)
    }

    @Test func 連打しても反応が重ならない() {
        var scheduler = MannerismScheduler(set: set, seed: 1)
        let result5 = scheduler.touch(time: 1)
        #expect(result5)
        let result6 = scheduler.touch(time: 1.1)
        #expect(!result6)
        let end = 1 + MannerismKind.startle.duration
        _ = scheduler.update(state: .idle, time: end)
        let result7 = scheduler.touch(time: end + 0.1)
        #expect(!result7)
        let result8 = scheduler.touch(time: end + MannerismScheduler.touchCooldown + 0.01)
        #expect(result8)
    }

    @Test func 癖がないキャラでも止まらない() {
        var scheduler = MannerismScheduler(set: MannerismSet(), seed: 1)
        #expect(run(&scheduler, state: .idle, from: 0, to: 200).isEmpty)
    }

    @Test func 喜ぶと応援するに重ねる動きを選ぶ() {
        let scheduler = MannerismScheduler(set: MannerismSet(praise: .clap, encourage: .nodPump), seed: 1)
        #expect(scheduler.stateOverlay(for: .praise) == .clap)
        #expect(scheduler.stateOverlay(for: .encourage) == .nodPump)
        #expect(scheduler.stateOverlay(for: .talking) == nil)
        // 今の先生は変更前の喜び方のまま
        #expect(MannerismSet.haru.praise == nil)
        #expect(MannerismSet.haru.encourage == nil)
    }
}

struct MannerismKindTests {
    @Test(arguments: MannerismKind.allCases)
    func 姿勢を動かして終わりには戻る(kind: MannerismKind) {
        // 癖は始まりと終わりでほぼ元の姿勢（なめらかに戻る）
        var pose = RigPose()
        kind.apply(elapsed: kind.duration * 0.37, to: &pose)
        #expect(pose != RigPose(), "\(kind) が何も動かさない")
        #expect(kind.duration > 0 && kind.duration <= 3, "\(kind) が長すぎる")
    }

    @Test(arguments: MannerismKind.allCases)
    func どの形式にも当てられる(kind: MannerismKind) {
        var voxel = AvatarPose()
        var paper = PaperPose()
        for t in stride(from: 0.0, through: kind.duration, by: 0.1) {
            kind.apply(elapsed: t, to: &voxel)
            kind.apply(elapsed: t, to: &paper)
        }
    }

    @Test func 癖は待機の姿勢の上に重なって終わると戻る() {
        let kinds: [MannerismKind] = [.glasses, .scratchHead, .yawn, .lookAround, .peerAtHand]
        for kind in kinds {
            var pose = AvatarPose()
            kind.apply(elapsed: kind.duration - 0.0001, to: &pose)
            #expect(pose.lift == 0)
            let head = pose.joint(.head).rotation
            #expect(abs(head.angle) < 0.03 || abs(head.angle - 2 * .pi) < 0.03, "\(kind)")
        }
    }

    @Test func 出だしと終わりはなめらか() {
        #expect(MannerismKind.envelope(0) == 0)
        #expect(MannerismKind.envelope(1) == 0)
        #expect(MannerismKind.envelope(0.5) == 1)
    }
}

/// 触った反応が、会話の状態や音声の再生を乱さない
@MainActor
struct MannerismTouchTests {
    private func playingLipSync() -> LipSyncPlayer {
        let player = LipSyncPlayer()
        player.play(LipSyncConverter.timeline(from: LipSyncDemo.alignment(for: "あああああ"))) { 0.05 }
        return player
    }

    @Test(arguments: AvatarState.allCases)
    func ボクセル_触っても状態と口が変わらない(state: AvatarState) async throws {
        let model = try await TeacherModel.load()
        try await model.preloadFaceTextures()
        let animator = AvatarAnimator(model: model)
        let lipSync = playingLipSync()
        animator.lipSync = lipSync
        animator.setState(state)
        animator.update(deltaTime: 1.0 / 60)
        animator.receiveTouches(1)
        #expect(animator.activeMannerism == .startle)
        for _ in 0..<30 { animator.update(deltaTime: 1.0 / 60) }
        #expect(animator.state == state)
        #expect(lipSync.currentShape == .a)
    }

    @Test func 骨のキャラ_触っても状態と口が変わらない() async throws {
        let model = try await RiggedModel.load(name: "proto_rig")
        let animator = RiggedAnimator(model: model, mannerisms: MannerismSet(touch: .squish))
        let lipSync = playingLipSync()
        animator.lipSync = lipSync
        animator.setState(.talking)
        animator.update(deltaTime: 1.0 / 60)
        animator.receiveTouches(1)
        #expect(animator.activeMannerism == .squish)
        for _ in 0..<30 { animator.update(deltaTime: 1.0 / 60) }
        #expect(animator.state == .talking)
        #expect(lipSync.currentShape == .a)
        #expect(model.mouth == .a)
    }

    @Test func 同じ回数なら反応し直さない() async throws {
        let model = try await TeacherModel.load()
        try await model.preloadFaceTextures()
        let animator = AvatarAnimator(model: model)
        animator.receiveTouches(0)
        #expect(animator.activeMannerism == nil)
        animator.receiveTouches(1)
        #expect(animator.activeMannerism == .startle)
    }

    @Test func 会話の窓口は触っても何も受け取らない() {
        // 触った反応は AvatarController を通らない。話している状態のまま
        let controller = AvatarController()
        controller.send(.speakingStarted(emotion: .neutral))
        let before = controller.state
        var scheduler = MannerismScheduler(set: .haru)
        let result9 = scheduler.touch(time: 0)
        #expect(result9)
        #expect(controller.state == before)
    }
}

struct CharacterMannerismTests {
    @Test func 同梱のキャラに癖がある() {
        for character in CharacterCatalog().characters {
            #expect(!character.mannerisms.idle.isEmpty, "\(character.id)")
        }
        #expect(CharacterCatalog().character(id: "haru").mannerisms == .haru)
    }

    @Test func キャラごとに喜び方が違う() {
        let catalog = CharacterCatalog()
        #expect(catalog.character(id: "haru").mannerisms.praise != catalog.character(id: "rika").mannerisms.praise)
    }
}

/// ボクセルのキャラの素材（#124）。読み込めないと黙って既定の先生に戻るので、ここで確かめる
@MainActor
struct VoxelCharacterAssetTests {
    @Test func 同梱のボクセルのキャラは全パーツと顔が読み込める() async throws {
        let voxels = CharacterCatalog().characters.filter { $0.look.kind == .voxel }
        #expect(voxels.count >= 3)
        for character in voxels {
            let model = try await TeacherModel.load(
                name: character.look.modelName, faceTextures: character.look.faceTexturePrefix, glowingFace: character.look.glowingFace ?? false
            )
            #expect(model.missingParts.isEmpty, "\(character.id): \(model.missingParts)")
            try await model.preloadFaceTextures()
            model.setEyes(.happy)
            model.setMouth(.a)
        }
    }

    @Test func 素材の名前はキャラごとに違う() {
        let looks = CharacterCatalog().characters.filter { $0.look.kind == .voxel }.map(\.look)
        #expect(Set(looks.map(\.modelName)).count == looks.count)
        #expect(Set(looks.map(\.faceTexturePrefix)).count == looks.count)
    }

    @Test func 選べるキャラに今の先生を含むすべてが並ぶ() {
        let selectable = CharacterCatalog().selectableCharacters.map(\.id)
        #expect(selectable == ["haru", "rika", "boru", "muni"])
    }

    @Test func 今の先生の見た目は光らない() {
        #expect(CharacterCatalog().character(id: "haru").look == .haru)
        #expect(CharacterLook.haru.glowingFace == nil)
    }

    @Test func ゴーグルは下りて戻る() {
        var pose = AvatarPose()
        let d = MannerismKind.goggles.duration
        MannerismKind.goggles.apply(elapsed: d * 0.5, to: &pose)
        #expect(pose.joint(.glasses).offset.z < -0.15)
        var end = AvatarPose()
        MannerismKind.goggles.apply(elapsed: d, to: &end)
        #expect(abs(end.joint(.glasses).offset.z) < 0.001)
    }
}
