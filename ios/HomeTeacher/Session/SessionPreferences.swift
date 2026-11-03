import Foundation
import Observation
import SwiftUI

/// 学習セッションの設定（端末に保存する）。始めるときに読むので、変えたら次のセッションから効く。
@MainActor
@Observable
final class SessionPreferences {
    static let speakingInputModeKey = "session.speakingInputMode"
    static let cameraPositionKey = "session.cameraPosition"

    /// 先生が話している間のマイクの扱い（spec §3①：割り込み / 保険のマイク停止）
    var speakingInputMode: SpeakingInputMode {
        didSet { defaults.set(Self.key(for: speakingInputMode), forKey: Self.speakingInputModeKey) }
    }

    /// 撮影に使うカメラ（iPad をスタンドに立てたとき、ノートを向いている方）
    var cameraPosition: CameraPosition {
        didSet { defaults.set(cameraPosition.rawValue, forKey: Self.cameraPositionKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        speakingInputMode = Self.mode(for: defaults.string(forKey: Self.speakingInputModeKey))
        cameraPosition = defaults.string(forKey: Self.cameraPositionKey).flatMap(CameraPosition.init(rawValue:)) ?? .front
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
