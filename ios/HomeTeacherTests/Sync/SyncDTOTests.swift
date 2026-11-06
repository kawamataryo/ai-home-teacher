import Foundation
import Testing
@testable import HomeTeacher

/// worker/README.md「同期 API」の例と同じ JSON を読み書きできるか。
struct SyncDTOTests {
    // worker/README.md の POST /v1/sessions の本文
    static let requestFixture = #"""
    {
      "id": "6F1C2E1A-0000-4000-8000-000000000001",
      "child_id": "default",
      "started_at": "2026-11-03T16:00:00+09:00",
      "ended_at": "2026-11-03T16:40:00+09:00",
      "focus_minutes": 35,
      "summary": "割合の文章題を 3 問やった",
      "teacher_note": "今日は割合の問題を自力で解けました！",
      "flags": ["学校で友だちとけんかしたと話していた"],
      "problems": [
        { "kind": "thinking", "summary": "割合：もとにする量を求める", "solved_by_self": true, "hint_level_reached": 1, "created_at": "2026-11-03T16:05:00+09:00" }
      ]
    }
    """#

    // worker/README.md の POST /v1/sessions のレスポンス
    static let responseFixture = #"""
    {
      "session": {
        "id": "6F1C2E1A-0000-4000-8000-000000000001",
        "child_id": "default",
        "started_at": "2026-11-03T07:00:00.000Z",
        "ended_at": "2026-11-03T07:40:00.000Z",
        "focus_minutes": 35,
        "summary": "割合の文章題を 3 問やった",
        "teacher_note": "今日は割合の問題を自力で解けました！",
        "flags": ["学校で友だちとけんかしたと話していた"],
        "updated_at": "2026-11-03T07:41:02.123Z",
        "problems": [
          { "id": "c1d2", "kind": "thinking", "summary": "割合：もとにする量を求める", "solved_by_self": true, "hint_level_reached": 1, "created_at": "2026-11-03T07:05:00.000Z" }
        ]
      }
    }
    """#

    static func utc(_ text: String) -> Date {
        try! Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
    }

    @Test func サーバーのレスポンスを小数秒付きの時刻で読める() throws {
        let response = try SyncCoding.decoder.decode(SessionResponse.self, from: Data(Self.responseFixture.utf8))
        let session = response.session
        #expect(session.id == "6F1C2E1A-0000-4000-8000-000000000001")
        #expect(session.childID == "default")
        #expect(session.startedAt == Self.utc("2026-11-03T07:00:00.000Z"))
        #expect(session.updatedAt == Self.utc("2026-11-03T07:41:02.123Z"))
        #expect(session.focusMinutes == 35)
        #expect(session.teacherNote == "今日は割合の問題を自力で解けました！")
        #expect(session.flags == ["学校で友だちとけんかしたと話していた"])
        #expect(session.problems == [
            ProblemDTO(id: "c1d2", kind: .thinking, summary: "割合：もとにする量を求める", solvedBySelf: true,
                       hintLevelReached: 1, createdAt: Self.utc("2026-11-03T07:05:00.000Z")),
        ])
    }

    @Test func タイムゾーン付きで小数秒なしの時刻も読める() throws {
        let session = try SyncCoding.decoder.decode(SessionDTO.self, from: Data(Self.requestFixture.utf8))
        #expect(session.startedAt == Self.utc("2026-11-03T07:00:00.000Z"))
        #expect(session.endedAt == Self.utc("2026-11-03T07:40:00.000Z"))
        #expect(session.problems.first?.createdAt == Self.utc("2026-11-03T07:05:00.000Z"))
        #expect(session.updatedAt == nil)
    }

    @Test func ミリ秒の時刻は書き戻しても変わらない() throws {
        // since にサーバーの updated_at をそのまま渡すので、丸めでずれないこと
        let text = "2026-11-03T07:41:02.123Z"
        #expect(SyncCoding.formatDate(try #require(SyncCoding.parseDate(text))) == text)
    }

    @Test func 時刻でない文字列は読めない() {
        let json = #"{"id":"x","started_at":"yesterday","ended_at":"2026-11-03T07:00:00Z","focus_minutes":1}"#
        #expect(throws: DecodingError.self) {
            _ = try SyncCoding.decoder.decode(SessionDTO.self, from: Data(json.utf8))
        }
    }

    @Test func 送るときはサーバーが付けるフィールドを入れずUTCで書く() throws {
        // レスポンスを読んで、そのまま送り直す（updated_at と problems[].id は strict なサーバーが 400 にする）
        let session = try SyncCoding.decoder.decode(SessionResponse.self, from: Data(Self.responseFixture.utf8)).session
        let data = try SyncCoding.encoder.encode(session)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "id", "child_id", "started_at", "ended_at", "focus_minutes", "summary", "teacher_note", "parent_prompt", "flags", "problems",
        ])
        #expect(object["started_at"] as? String == "2026-11-03T07:00:00.000Z")
        let problem = try #require((object["problems"] as? [[String: Any]])?.first)
        #expect(Set(problem.keys) == ["kind", "summary", "solved_by_self", "hint_level_reached", "created_at"])
        #expect(problem["solved_by_self"] as? Bool == true)
        #expect(problem["created_at"] as? String == "2026-11-03T07:05:00.000Z")
    }

    @Test func 子どもと問題の時刻がなければ送らない() throws {
        let session = SessionDTO(
            id: "s1", startedAt: Self.utc("2026-11-03T07:00:00.000Z"), endedAt: Self.utc("2026-11-03T07:30:00.000Z"),
            focusMinutes: 25, problems: [ProblemDTO(kind: .writing, summary: "作文", solvedBySelf: false)]
        )
        let object = try #require(try JSONSerialization.jsonObject(with: SyncCoding.encoder.encode(session)) as? [String: Any])
        #expect(object["child_id"] == nil)
        #expect(object["summary"] as? String == "")
        #expect(object["flags"] as? [String] == [])
        let problem = try #require((object["problems"] as? [[String: Any]])?.first)
        #expect(problem["created_at"] == nil)
        #expect(problem["hint_level_reached"] as? Int == 0)
    }

    @Test func セッション一覧と記憶の一覧を読める() throws {
        let list = #"""
        { "sessions": [], "server_time": "2026-11-03T07:45:00.000Z" }
        """#
        let sessions = try SyncCoding.decoder.decode(SessionListResponse.self, from: Data(list.utf8))
        #expect(sessions.serverTime == Self.utc("2026-11-03T07:45:00.000Z"))

        let memories = #"""
        {
          "memories": [
            { "id": "m1", "child_id": "default", "category": "likes", "content": "サッカー", "updated_at": "2026-11-03T07:41:02.123Z" },
            { "id": "m2", "child_id": "default", "category": "weak_points", "content": "割合", "updated_at": "2026-11-03T07:41:02Z" }
          ]
        }
        """#
        let response = try SyncCoding.decoder.decode(MemoryListResponse.self, from: Data(memories.utf8))
        #expect(response.memories.map(\.category) == [.likes, .weakPoints])
        #expect(response.memories.map(\.content) == ["サッカー", "割合"])
    }

    @Test func 記憶のPUTの本文はREADMEの形() throws {
        let request = MemoryPutRequest(category: .weakPoints, items: [MemoryItemDTO(content: "割合")])
        let json = String(decoding: try SyncCoding.encoder.encode(request), as: UTF8.self)
        #expect(json == #"{"category":"weak_points","items":[{"content":"割合"}]}"#)
    }
}
