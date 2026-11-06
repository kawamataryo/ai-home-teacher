import SwiftUI

/// デバッグ用: 先生の状態・顔テクスチャ・口パクを確認する画面
///
/// 起動引数 `-avatarState thinking` で最初の状態を指定できる（スクリーンショット用）。
/// `-avatarLipSyncDemo YES` で開いたらすぐ口パクのデモを流す。
struct AvatarGalleryView: View {
    @State private var state: AvatarState =
        AvatarState(rawValue: UserDefaults.standard.string(forKey: "avatarState") ?? "") ?? .idle
    /// nil なら口パクに任せる。起動引数 `-avatarMouth a` で固定できる（スクリーンショット用）
    @State private var mouth: MouthShape? = MouthShape(rawValue: UserDefaults.standard.string(forKey: "avatarMouth") ?? "")
    @State private var lipSync = LipSyncPlayer()
    @State private var demoText = LipSyncDemo.sentences[0]

    var body: some View {
        VStack {
            Text(state.rawValue)
                .font(.title2.monospaced())
            AvatarView(state: state, lipSync: lipSync, mouth: mouth)
            Picker("状態", selection: $state) {
                ForEach(AvatarState.allCases, id: \.self) { state in
                    Text(state.rawValue).tag(state)
                }
            }
            .pickerStyle(.segmented)
            Picker("口", selection: $mouth) {
                Text("口パク").tag(MouthShape?.none)
                ForEach(MouthShape.allCases, id: \.self) { shape in
                    Text(shape.rawValue).tag(MouthShape?.some(shape))
                }
            }
            .pickerStyle(.segmented)
            HStack {
                ForEach(LipSyncDemo.sentences, id: \.self) { sentence in
                    Button(sentence) { playDemo(sentence) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .navigationTitle("先生ギャラリー")
        .task {
            if UserDefaults.standard.bool(forKey: "avatarLipSyncDemo") {
                try? await Task.sleep(for: .seconds(1.5))
                playDemo(LipSyncDemo.sentences[0])
            }
        }
    }

    /// 音声なしで、作った文字タイミングに合わせて口を動かす
    private func playDemo(_ sentence: String) {
        mouth = nil
        state = .talking
        let timeline = LipSyncConverter.timeline(from: LipSyncDemo.alignment(for: sentence))
        let start = Date()
        lipSync.play(timeline) {
            let elapsed = Date().timeIntervalSince(start)
            return elapsed <= timeline.duration ? elapsed : nil
        }
        Task {
            try? await Task.sleep(for: .seconds(timeline.duration + 0.2))
            if lipSync.isFinished, state == .talking { state = .idle }
        }
    }
}

/// デモ用の文字タイミング（ElevenLabs の alignment のかわり）
enum LipSyncDemo {
    static let sentences = ["きょうは わりあいを やってみよう！", "今日もがんばろう", "ちょっとノートみせて？"]

    static func alignment(for text: String) -> TTSAlignment {
        var characters: [String] = []
        var starts: [Double] = []
        var ends: [Double] = []
        var t = 0.0
        for character in text {
            let s = String(character)
            let duration: Double
            switch Kana.classify(s) {
            case .smallVowel: duration = 0.08
            case .silent: duration = 0.25
            case .unknown: duration = 0.3
            default: duration = 0.14
            }
            characters.append(s)
            starts.append(t)
            ends.append(t + duration)
            t += duration
        }
        return TTSAlignment(characters: characters, characterStartTimesSeconds: starts, characterEndTimesSeconds: ends)
    }
}

#Preview {
    NavigationStack { AvatarGalleryView() }
}
