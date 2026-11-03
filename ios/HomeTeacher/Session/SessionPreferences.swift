import Foundation
import Observation
import SwiftUI

/// 学習セッションの設定（端末に保存する）。始めるときに読むので、変えたら次のセッションから効く。
@MainActor
@Observable
final class SessionPreferences {
    static let speakingInputModeKey = "session.speakingInputMode"
    static let cameraPositionKey = "session.cameraPosition"
    static let watchOverMinutesKey = "session.watchOverMinutes"
    static let focusMinutesKey = "session.focusMinutes"
    static let breakMinutesKey = "session.breakMinutes"
    static let nudgeVariationKey = "session.nudgeVariation"
    /// 集中の分（spec §3④。初期値 25 分）
    nonisolated static let focusChoices = [15, 20, 25, 30, 45]
    static let defaultFocusMinutes = 25
    /// 休憩の分（初期値 5 分）
    nonisolated static let breakChoices = [3, 5, 10, 15]
    static let defaultBreakMinutes = 5
    /// 見守りで「手が止まったら声をかける」までの分。0 は見守らない（spec §3⑥。初期値 3 分）
    nonisolated static let watchOverChoices = [0, 2, 3, 5]
    static let defaultWatchOverMinutes = 3

    /// 先生が話している間のマイクの扱い（spec §3①：割り込み / 保険のマイク停止）
    var speakingInputMode: SpeakingInputMode {
        didSet { defaults.set(Self.key(for: speakingInputMode), forKey: Self.speakingInputModeKey) }
    }

    /// 撮影に使うカメラ（iPad をスタンドに立てたとき、ノートを向いている方）
    var cameraPosition: CameraPosition {
        didSet { defaults.set(cameraPosition.rawValue, forKey: Self.cameraPositionKey) }
    }

    /// 見守り（#30）。手が何分止まったら声をかけるか。0 なら見守らない（カメラも使わない）
    var watchOverMinutes: Int {
        didSet { defaults.set(watchOverMinutes, forKey: Self.watchOverMinutesKey) }
    }

    /// 集中の時間（分）
    var focusMinutes: Int {
        didSet { defaults.set(focusMinutes, forKey: Self.focusMinutesKey) }
    }

    /// 休憩の時間（分）
    var breakMinutes: Int {
        didSet { defaults.set(breakMinutes, forKey: Self.breakMinutesKey) }
    }

    /// 時間での声かけ（休憩しよっか・あと5分など）の言い回しを Haiku に変えてもらうか。オフなら定型句のまま（同梱の音声ですぐ話す）
    var allowsNudgeVariation: Bool {
        didSet { defaults.set(allowsNudgeVariation, forKey: Self.nudgeVariationKey) }
    }

    /// タイマーの設定。分数と言い回しだけを差し替え、ほか（5 分前の励ましなど）は `base` のまま
    func timerSettings(base: FocusTimerSettings = FocusTimerSettings()) -> FocusTimerSettings {
        var settings = base
        settings.focusDuration = .minutes(focusMinutes)
        settings.breakDuration = .minutes(breakMinutes)
        settings.allowsVariation = allowsNudgeVariation
        return settings
    }

    /// 見守りの設定。オフなら nil
    var watchOverConfiguration: StallDetector.Configuration? {
        watchOverMinutes > 0 ? .minutes(watchOverMinutes) : nil
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        speakingInputMode = Self.mode(for: defaults.string(forKey: Self.speakingInputModeKey))
        cameraPosition = defaults.string(forKey: Self.cameraPositionKey).flatMap(CameraPosition.init(rawValue:)) ?? .front
        let minutes = defaults.object(forKey: Self.watchOverMinutesKey) as? Int
        watchOverMinutes = minutes.flatMap { Self.watchOverChoices.contains($0) ? $0 : nil } ?? Self.defaultWatchOverMinutes
        focusMinutes = Self.choice(defaults, Self.focusMinutesKey, in: Self.focusChoices) ?? Self.defaultFocusMinutes
        breakMinutes = Self.choice(defaults, Self.breakMinutesKey, in: Self.breakChoices) ?? Self.defaultBreakMinutes
        allowsNudgeVariation = defaults.bool(forKey: Self.nudgeVariationKey)
    }

    /// 保存した値が選択肢にあれば返す（選択肢を変えたときに古い値を使わない）
    private static func choice(_ defaults: UserDefaults, _ key: String, in choices: [Int]) -> Int? {
        (defaults.object(forKey: key) as? Int).flatMap { choices.contains($0) ? $0 : nil }
    }

    static func key(for mode: SpeakingInputMode) -> String {
        switch mode {
        case .bargeIn: "bargeIn"
        case .muteWhileSpeaking: "muteWhileSpeaking"
        }
    }

    static func mode(for key: String?) -> SpeakingInputMode {
        key == "muteWhileSpeaking" ? .muteWhileSpeaking : .bargeIn
    }
}

/// 設定画面（学習セッション画面の右上の歯車から開く）
struct SessionSettingsView: View {
    @Bindable var preferences: SessionPreferences
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("集中", selection: $preferences.focusMinutes) {
                        ForEach(SessionPreferences.focusChoices, id: \.self) { Text("\($0)分").tag($0) }
                    }
                    Picker("休憩", selection: $preferences.breakMinutes) {
                        ForEach(SessionPreferences.breakChoices, id: \.self) { Text("\($0)分").tag($0) }
                    }
                    Toggle("声かけの言い回しを先生に変えてもらう", isOn: $preferences.allowsNudgeVariation)
                } header: {
                    Text("タイマー")
                } footer: {
                    Text("集中と休憩をくり返し、区切りで先生が「そろそろ休憩しよっか」などと声をかけます。言い回しを変えると毎回少しちがう言い方になります（AI が作るので、話し始めが少し遅れることがあります。作れなければいつもの言い方で話します）。次の勉強から変わります。")
                }
                Section {
                    Picker("先生が話している間", selection: $preferences.speakingInputMode) {
                        Text("話しかけたら止まって聞く（割り込み）").tag(SpeakingInputMode.bargeIn)
                        Text("マイクを止める").tag(SpeakingInputMode.muteWhileSpeaking)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("先生が話している間")
                } footer: {
                    Text("先生の声を自分の声と聞きまちがえて止まってしまうときは「マイクを止める」にしてください。次の勉強から変わります。")
                }
                Section {
                    Picker("撮影に使うカメラ", selection: $preferences.cameraPosition) {
                        ForEach(CameraPosition.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("「見て」で撮影するカメラ")
                } footer: {
                    Text("iPad をスタンドに立ててノートを撮るときは、ノートの方を向いているカメラを選んでください。写真は先生に送ったあと端末からも消します。")
                }
                Section {
                    Picker("見守り", selection: $preferences.watchOverMinutes) {
                        ForEach(SessionPreferences.watchOverChoices, id: \.self) { minutes in
                            Text(minutes == 0 ? "見守らない" : "手が\(minutes)分止まったら声をかける").tag(minutes)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("見守り（前のカメラ）")
                } footer: {
                    Text("勉強中、前のカメラで手の動きと顔があるかだけを見ます。映像は iPad の中だけで使い、送ったり保存したりしません。写真を撮るのは「ちょっと見せて？」に「うん」と答えたときだけです。席を立つとタイマーが止まります。見守っている間は画面に目のマークが出ます。")
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
