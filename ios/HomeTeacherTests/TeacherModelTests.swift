import Foundation
import RealityKit
import Testing
@testable import HomeTeacher

@MainActor
struct TeacherModelTests {
    @Test func usdzを読み込めて全パーツが見つかる() async throws {
        let model = try await TeacherModel.load()
        #expect(model.missingParts.isEmpty, "見つからないパーツ: \(model.missingParts)")
    }

    @Test func 顔テクスチャがすべて同梱されている() async throws {
        let model = try await TeacherModel.load()
        try await model.preloadFaceTextures()
    }

    @Test func 口のテクスチャを差し替えられる() async throws {
        let model = try await TeacherModel.load()
        try await model.preloadFaceTextures()
        model.setMouth(.a)
        let mouth = try #require(model.part(.mouth))
        let target = mouth.components.has(ModelComponent.self) ? mouth : try #require(mouth.children.first)
        let materials = try #require(target.components[ModelComponent.self]?.materials)
        #expect(materials.first is PhysicallyBasedMaterial)
    }
}
