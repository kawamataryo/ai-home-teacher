import Testing
@testable import HomeTeacher

struct LeadEchoTests {
    @Test func 定型句と同じ言葉で始まる文はその部分を取り除く() {
        #expect(StudySessionCoordinator.droppingLeadEcho("すごいじゃん！よく見つけたね！", lead: "すごいじゃん！") == "よく見つけたね！")
        #expect(StudySessionCoordinator.droppingLeadEcho("すごいじゃん、よく見つけたね", lead: "すごいじゃん！") == "よく見つけたね")
    }

    @Test func 定型句だけの文は空になる() {
        #expect(StudySessionCoordinator.droppingLeadEcho("すごいじゃん！！", lead: "すごいじゃん！") == "")
    }

    @Test func 違う言葉で始まる文はそのまま() {
        #expect(StudySessionCoordinator.droppingLeadEcho("よく見つけたね！", lead: "すごいじゃん！") == "よく見つけたね！")
        #expect(StudySessionCoordinator.droppingLeadEcho("すごいね！", lead: "すごいじゃん！") == "すごいね！")
    }
}
