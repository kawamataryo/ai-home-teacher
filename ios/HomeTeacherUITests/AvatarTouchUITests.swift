import XCTest

/// 指で触ったときの動き（#122）。実際のタップを送る
final class AvatarTouchUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func test先生を触ると反応しても画面の状態は変わらない() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-avatarGallery", "-avatarState", "talking", "-skipPermissionOnboarding"]
        app.launch()
        let avatar = app.descendants(matching: .any)["avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        XCTAssertEqual(avatar.value as? String, "0")

        avatar.tap()
        XCTAssertEqual(avatar.value as? String, "1")
        // 触っても状態の表示はそのまま
        XCTAssertTrue(app.staticTexts["talking"].exists)
    }

    @MainActor
    func test学習セッションの先生も触れて黒板のある画面でも止まらない() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-sessionPreview", "board", "-skipPermissionOnboarding"]
        app.launch()
        let avatar = app.descendants(matching: .any)["avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        avatar.tap()
        XCTAssertEqual(avatar.value as? String, "1")
        // ほかのボタンはそのまま押せる
        XCTAssertTrue(app.buttons["おわり"].exists)
    }
}
