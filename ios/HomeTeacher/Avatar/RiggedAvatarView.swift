import RealityKit
import SwiftUI
import UIKit

/// 骨とシェイプキーで動かす 3D のキャラ（#121）
struct RiggedAvatarView: View {
    var state: AvatarState
    var lipSync: LipSyncPlayer?
    var mouth: MouthShape?
    var turn: Double
    var look: CharacterLook
    var mannerisms: MannerismSet
    var touches: Int
    var onLoadFailed: () -> Void

    @State private var animator: RiggedAnimator?
    @State private var updateSubscription: EventSubscription?

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            do {
                let model = try await RiggedModel.load(name: look.modelName)
                let animator = RiggedAnimator(model: model, mannerisms: mannerisms)
                animator.setState(state)
                animator.lipSync = lipSync
                animator.mouthOverride = mouth
                animator.targetYaw = AvatarView.yaw(turn)
                content.add(animator.rig)

                // 大きさはキャラごとに違うので、見た目の大きさから写し方を決める。はずんだ分と手を上げた分の余白を上にとる
                let bounds = model.entity.visualBounds(relativeTo: nil)
                let framing = RiggedFraming(center: bounds.center, extents: bounds.extents)
                let camera = PerspectiveCamera()
                camera.camera.fieldOfViewInDegrees = RiggedFraming.fieldOfView
                camera.look(at: framing.lookAt, from: framing.eye, relativeTo: nil)
                content.add(camera)

                let sun = DirectionalLight()
                sun.light.intensity = 2_400
                sun.look(at: framing.lookAt, from: framing.lookAt + SIMD3<Float>(1.5, 3.0, 3.0) * framing.scale, relativeTo: nil)
                content.add(sun)

                // まわりの光（やわらかい部屋の明かり）。金属や毛のつやに必要
                let ibl = Entity()
                if let image = StudioLighting.equirectangular(), let environment = try? await EnvironmentResource(equirectangular: image) {
                    ibl.components.set(ImageBasedLightComponent(source: .single(environment), intensityExponent: 0.4))
                    content.add(ibl)
                    StudioLighting.receive(ibl, on: animator.rig)
                }

                updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                    MainActor.assumeIsolated {
                        animator.update(deltaTime: event.deltaTime)
                    }
                }
                self.animator = animator
            } catch {
                onLoadFailed()
            }
        } update: { _ in
            animator?.setState(state)
            if animator?.lipSync !== lipSync { animator?.lipSync = lipSync }
            animator?.mouthOverride = mouth
            animator?.targetYaw = AvatarView.yaw(turn)
            animator?.receiveTouches(touches)
        }
    }
}

/// キャラの大きさから決める写し方
struct RiggedFraming: Equatable {
    static let fieldOfView: Float = 30

    let lookAt: SIMD3<Float>
    let eye: SIMD3<Float>
    /// キャラの高さ（光の距離の目安）
    let scale: Float

    init(center: SIMD3<Float>, extents: SIMD3<Float>) {
        scale = max(max(extents.x, extents.y), 0.01)
        // 上に余白（はずむ・手を上げる）。枠の縦いっぱいに 1.45 倍の高さが入る距離
        let frameHeightForWidth = extents.x / Float(SessionStageLayout.teacherBodyWidth) / Float(SessionStageLayout.teacherAspect)
        let height = max(extents.y * 1.45, frameHeightForWidth)
        let distance = height / 2 / tan(Self.fieldOfView / 2 * .pi / 180)
        lookAt = center + [0, extents.y * 0.14, 0]
        eye = lookAt + normalize(SIMD3<Float>(0.14, 0.08, 1)) * distance
    }
}

/// 3D のキャラに当てる、まわりの光
enum StudioLighting {
    /// 上が明るく下が暖かい、やわらかい部屋の明かりの正距円筒画像
    static func equirectangular(width: Int = 256, height: Int = 128) -> CGImage? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let v = Float(y) / Float(height - 1)
            for x in 0..<width {
                let u = Float(x) / Float(width - 1)
                // 空（上）から床（下）へ
                let top = SIMD3<Float>(0.98, 0.98, 1.0)
                let mid = SIMD3<Float>(0.82, 0.80, 0.78)
                let bottom = SIMD3<Float>(0.62, 0.52, 0.45)
                var color = v < 0.5 ? mix(top, mid, t: v * 2) : mix(mid, bottom, t: (v - 0.5) * 2)
                // 左上の窓の光（つやの形になる）
                let du = (u - 0.3), dv = (v - 0.28)
                let window = max(0, 1 - (du * du * 60 + dv * dv * 90))
                color = color + SIMD3<Float>(repeating: window * 0.35)
                let i = (y * width + x) * 4
                pixels[i] = UInt8(min(255, color.x * 255))
                pixels[i + 1] = UInt8(min(255, color.y * 255))
                pixels[i + 2] = UInt8(min(255, color.z * 255))
            }
        }
        return pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )?.makeImage()
        }
    }

    @MainActor
    static func receive(_ light: Entity, on entity: Entity) {
        entity.components.set(ImageBasedLightReceiverComponent(imageBasedLight: light))
        for child in entity.children { receive(light, on: child) }
    }
}
