import Foundation
import Testing
@testable import HomeTeacher

struct SessionTraceFileTests {
    @Test func 起動引数がなければ書かない() {
        #expect(SessionTraceFile.fromLaunchArguments(["HomeTeacher"]) == nil)
    }

    @Test func 追記していく() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "trace-\(UUID().uuidString).txt")
        let file = SessionTraceFile(url: url)
        file.append("セッション開始")
        file.append("受け付けた発話: こんにちは")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("セッション開始\n"))
        #expect(text.contains("受け付けた発話: こんにちは\n"))
        #expect(text.split(separator: "\n").count == 2)
    }
}
