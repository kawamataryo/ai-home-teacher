import XCTest

/// キャラを選ぶ画面（#123）。実際のタップを送り、縦と横のスクリーンショットを残す
final class CharacterPickerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-characterPicker", "-showAllCharacters", "-skipPermissionOnboarding"] + extra
        app.launch()
        return app
    }

    /// シミュレーターならファイルにも残す（PR に貼る）
    private func saveShot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        try? FileManager.default.createDirectory(atPath: "/tmp/ht-shots", withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: URL(fileURLWithPath: "/tmp/ht-shots/\(name).png"))
    }

    @MainActor
    func test指で選べて連打しても止まらず閉じると戻る() throws {
        let app = launch()
        let rika = app.descendants(matching: .any)["character_rika"]
        XCTAssertTrue(rika.waitForExistence(timeout: 15))
        let haru = app.descendants(matching: .any)["character_haru"]
        XCTAssertTrue(haru.exists)
        sleep(2)
        saveShot("picker_portrait")

        // 連打する
        for _ in 0..<3 {
            rika.tap()
            haru.tap()
        }
        rika.tap()
        let intro = app.staticTexts["picker_intro"]
        XCTAssertTrue(intro.label.contains("リカ"))
        XCTAssertTrue(app.buttons["picker_choose"].label.contains("リカ先生"))

        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        saveShot("picker_landscape")
        XCUIDevice.shared.orientation = .portrait

        app.buttons["picker_close"].tap()
        XCTAssertTrue(app.buttons["先生をえらぶ"].waitForExistence(timeout: 5))
    }

    /// 全員を舞台に出して、縦と横のスクリーンショットを残す。出ている間も全員の席に触れる
    @MainActor
    func test全員が舞台に出られて縦でも横でも席に触れる() throws {
        let app = launch()
        let ids = ["haru", "rika", "boru", "muni", "pon", "noa", "sora", "kona"]
        XCTAssertTrue(app.descendants(matching: .any)["character_haru"].waitForExistence(timeout: 15))
        sleep(3)
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            sleep(2)
            let name = orientation == .portrait ? "portrait" : "landscape"
            for id in ids {
                let seat = app.descendants(matching: .any)["character_\(id)"]
                XCTAssertTrue(seat.isHittable, id)
                seat.tap()
                sleep(2)
                XCTAssertTrue(app.buttons["picker_choose"].label.hasSuffix("にする"))
                saveShot("stage_\(name)_\(id)")
            }
        }
    }

    @MainActor
    func test選んだキャラが次に開いても残る() throws {
        var app = launch()
        let rika = app.descendants(matching: .any)["character_rika"]
        XCTAssertTrue(rika.waitForExistence(timeout: 15))
        rika.tap()
        app.buttons["picker_choose"].tap()
        // あいさつのあと閉じる
        XCTAssertTrue(app.buttons["先生をえらぶ"].waitForExistence(timeout: 30))
        app.terminate()

        app = launch()
        XCTAssertTrue(app.descendants(matching: .any)["character_rika"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["picker_choose"].label.contains("リカ先生"))
        // 既定に戻しておく
        let haru = app.descendants(matching: .any)["character_haru"]
        haru.tap()
        app.buttons["picker_choose"].tap()
        XCTAssertTrue(app.buttons["先生をえらぶ"].waitForExistence(timeout: 30))
    }
}
