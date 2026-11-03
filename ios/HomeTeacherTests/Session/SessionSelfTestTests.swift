import Foundation
import Testing
@testable import HomeTeacher

@MainActor
struct SessionSelfTestTests {
    @Test func 起動引数で画面を選ぶ() {
        #expect(SessionSelfTest.mode(["HomeTeacher"]) == nil)
        #expect(SessionSelfTest.mode(["HomeTeacher", "-autoSession"]) == .log)
        #expect(SessionSelfTest.mode(["HomeTeacher", "-autoSessionDemo"]) == .screen)
    }

    @Test func 記録の時刻はミリ秒まで残す() {
        let date = Date(timeIntervalSince1970: 1_793_772_963.25)
        let stamp = SessionSelfTest.timestamp(date)
        #expect(stamp.hasSuffix("[1793772963.250]"))
        #expect(stamp.contains(".250"))
    }
}
