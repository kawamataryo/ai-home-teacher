import SwiftUI

/// #9 実機スパイクの検証画面。
struct SpeechSpikeView: View {
    @State private var model = SpeechSpikeModel()

    var body: some View {
        Form {
            Section("1. 日本語への対応状況") {
                if let s = model.support {
                    row("SpeechTranscriber（iOS 26）", s.speechTranscriberAvailable && s.speechTranscriberSupportsJa,
                        detail: "利用可能=\(s.speechTranscriberAvailable) / 導入済み=\(s.speechTranscriberInstalledJa)")
                    row("DictationTranscriber", s.dictationSupportsJa, detail: "導入済み=\(s.dictationInstalledJa)")
                    row("SFSpeechRecognizer", s.sfSupportsJa, detail: "端末内=\(s.sfOnDeviceJa)")
                    LabeledContent("推奨エンジン", value: s.preferred?.rawValue ?? "なし")
                } else {
                    ProgressView()
                }
            }

            Section("2. 聞き取り") {
                Picker("エンジン", selection: $model.engine) {
                    ForEach(RecognizerKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .disabled(model.isListening)
                Toggle("エコーキャンセル（voice processing）", isOn: $model.voiceProcessing)
                    .disabled(model.isListening)
                Button(model.isListening ? "聞き取りを止める" : "聞き取りを始める") {
                    Task { await model.toggleListening() }
                }
                ProgressView(value: min(Double(model.level) * 10, 1))
                    .accessibilityLabel("入力レベル")
                Text(model.transcript.isEmpty ? "（話した言葉がここに出ます）" : model.transcript)
                    .font(.title3)
                    .frame(maxWidth: .infinity, minHeight: 80, alignment: .topLeading)
                    .foregroundStyle(model.transcript.isEmpty ? .secondary : .primary)
            }

            Section {
                Button("先生の声を流してエコーを測る") {
                    Task { await model.runEchoTest() }
                }
                .disabled(model.isEchoTesting)
                ForEach(model.trials) { t in
                    VStack(alignment: .leading) {
                        Text(String(format: "%@ / キャンセル %@ → 混入率 %.0f%%",
                                    t.engine.rawValue, t.voiceProcessing ? "ON" : "OFF", t.leakage * 100))
                            .font(.headline)
                            .foregroundStyle(t.leakage < 0.2 ? .green : .red)
                        Text("認識: 「\(t.recognizedDuringPlayback)」").font(.caption)
                    }
                }
            } header: {
                Text("3. エコー（先生の声を拾わないか）")
            } footer: {
                Text("流れる文:「\(SpeechSpikeModel.echoSentence)」\n1回目は黙って聞き、2回目は流れている途中で「待って」と話しかけてください。エコーキャンセル ON/OFF の両方で試します。")
            }

            Section {
                Button("結果をコピー（issue #9 に貼る）") { model.copyReport() }
                if !model.status.isEmpty {
                    Text(model.status).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("音声の実機検証")
        .task { await model.probe() }
    }

    private func row(_ title: String, _ ok: Bool, detail: String) -> some View {
        LabeledContent {
            Text(detail).font(.caption)
        } label: {
            Label(title, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .red)
        }
    }
}
