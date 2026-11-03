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
