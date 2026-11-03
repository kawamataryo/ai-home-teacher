import Foundation

/// 口の形（Resources/Teacher/face_mouth_*.png）
enum MouthShape: String, CaseIterable, Sendable {
    case a, i, u, e, o, n, closed

    var textureName: String { "face_mouth_\(rawValue)" }
}

/// TTS の文字タイミング（ElevenLabs の `alignment` / `normalized_alignment` と同じ形）
struct TTSAlignment: Decodable, Equatable, Sendable {
    var characters: [String]
    var characterStartTimesSeconds: [Double]
    var characterEndTimesSeconds: [Double]

    enum CodingKeys: String, CodingKey {
        case characters
        case characterStartTimesSeconds = "character_start_times_seconds"
        case characterEndTimesSeconds = "character_end_times_seconds"
    }
}

/// 口の形の時系列。`time` 秒から次のキーフレームまで `shape` の口にする
struct MouthTimeline: Equatable, Sendable {
    struct Keyframe: Equatable, Sendable {
        var time: Double
        var shape: MouthShape
    }

    /// 時間順。最後は必ず closed
    private(set) var keyframes: [Keyframe]

    init(keyframes: [Keyframe]) {
        // 同じ時刻なら後から足したほうを使う
        let ordered = keyframes.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
        var merged: [Keyframe] = []
        for keyframe in ordered {
            if merged.last?.time == keyframe.time { merged.removeLast() }
            // 同じ口が続くところはまとめる
            if merged.last?.shape != keyframe.shape { merged.append(keyframe) }
        }
        self.keyframes = merged
    }

    /// 口が動き終わる時刻
    var duration: Double { keyframes.last?.time ?? 0 }

    func shape(at time: Double) -> MouthShape {
        // time 以下で最後のキーフレームを二分探索
        var low = 0
        var high = keyframes.count
        while low < high {
            let mid = (low + high) / 2
            if keyframes[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? .closed : keyframes[low - 1].shape
    }
}

/// 文字タイミングを口の形に変換する
enum LipSyncConverter {
    /// 読みのない文字（漢字など）で、口を 1 回開け閉めする長さの目安（秒）
    static let syllableDuration = 0.15
    /// ま行・ば行・ぱ行の頭で唇を閉じる長さの上限（秒）
    static let lipClosureDuration = 0.05

    static func timeline(from alignment: TTSAlignment) -> MouthTimeline {
        let count = min(
            alignment.characters.count,
            alignment.characterStartTimesSeconds.count,
            alignment.characterEndTimesSeconds.count
        )
        var keyframes: [MouthTimeline.Keyframe] = []
        var previousVowel: MouthShape?
        var lastEnd = 0.0

        for index in 0..<count {
            let character = alignment.characters[index]
            let start = alignment.characterStartTimesSeconds[index]
            let end = max(start, alignment.characterEndTimesSeconds[index])

            // 前の文字との間があいていたら口を閉じる
            if index > 0, start > lastEnd + 0.01 {
                keyframes.append(.init(time: lastEnd, shape: .closed))
            }
            lastEnd = end

            switch Kana.classify(character) {
            case .vowel(let vowel, let closesLips):
                if closesLips, end - start > 0.02 {
                    keyframes.append(.init(time: start, shape: .closed))
                    keyframes.append(.init(time: start + min(lipClosureDuration, (end - start) * 0.3), shape: vowel))
                } else {
                    keyframes.append(.init(time: start, shape: vowel))
                }
                previousVowel = vowel
            case .smallVowel(let vowel):
                // きゃ・ふぁ など: 前の音の母音を置き換える
                if let last = keyframes.last, last.shape != .closed, last.shape != .n, previousVowel != nil {
                    keyframes[keyframes.count - 1].shape = vowel
                } else {
                    keyframes.append(.init(time: start, shape: vowel))
                }
                previousVowel = vowel
            case .longVowel:
                // ー: 前の母音をのばす
                keyframes.append(.init(time: start, shape: previousVowel ?? .closed))
            case .n:
                keyframes.append(.init(time: start, shape: .n))
                previousVowel = nil
            case .sokuon, .silent:
                keyframes.append(.init(time: start, shape: .closed))
                previousVowel = nil
            case .unknown:
                // 読みがわからない文字は、長さに合わせて「あ」と閉じを交互に
                let slots = max(1, Int(((end - start) / syllableDuration).rounded()))
                let slot = (end - start) / Double(slots)
                for k in 0..<slots {
                    let t = start + slot * Double(k)
                    keyframes.append(.init(time: t, shape: .a))
                    keyframes.append(.init(time: t + slot * 0.7, shape: .closed))
                }
                previousVowel = .a
            }
        }
        if count > 0 {
            keyframes.append(.init(time: lastEnd, shape: .closed))
        }
        return MouthTimeline(keyframes: keyframes)
    }
}

/// かな 1 文字の分類
enum Kana {
    enum Kind: Equatable {
        /// 母音を持つかな。`closesLips` はま行・ば行・ぱ行（唇を閉じてから開く）
        case vowel(MouthShape, closesLips: Bool)
        /// ゃゅょぁぃぅぇぉゎ
        case smallVowel(MouthShape)
        /// ー
        case longVowel
        /// ん
        case n
        /// っ
        case sokuon
        /// 句読点・空白など
        case silent
        /// 漢字・英数字など読みがわからない文字
        case unknown
    }

    static func classify(_ character: String) -> Kind {
        guard let scalar = character.unicodeScalars.first else { return .silent }
        if ["ー", "〜", "～"].contains(character) { return .longVowel }
        if character.unicodeScalars.allSatisfy({ silentCharacters.contains($0) }) { return .silent }
        let c = Character(toHiragana(scalar))
        if c == "ん" { return .n }
        if c == "っ" { return .sokuon }
        if let vowel = smallVowels[c] { return .smallVowel(vowel) }
        for (vowel, row) in vowelRows where row.contains(c) {
            return .vowel(vowel, closesLips: lipClosing.contains(c))
        }
        return .unknown
    }

    /// カタカナをひらがなに寄せる
    private static func toHiragana(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        if (0x30A1...0x30F6).contains(scalar.value), let h = Unicode.Scalar(scalar.value - 0x60) {
            return h
        }
        return scalar
    }

    private static let silentCharacters = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)

    private static let vowelRows: [(MouthShape, Set<Character>)] = [
        (.a, Set("あかさたなはまやらわがざだばぱ")),
        (.i, Set("いきしちにひみりゐぎじぢびぴ")),
        (.u, Set("うくすつぬふむゆるぐずづぶぷゔ")),
        (.e, Set("えけせてねへめれゑげぜでべぺ")),
        (.o, Set("おこそとのほもよろをごぞどぼぽ")),
    ]

    private static let smallVowels: [Character: MouthShape] = [
        "ぁ": .a, "ゃ": .a, "ゎ": .a,
        "ぃ": .i,
        "ぅ": .u, "ゅ": .u,
        "ぇ": .e,
        "ぉ": .o, "ょ": .o,
    ]

    private static let lipClosing = Set<Character>("まみむめもばびぶべぼぱぴぷぺぽ")
}

/// 文字タイミングがない TTS 用: 音量（RMS）で口を開け閉めする
///
/// 開く・閉じるのしきい値をずらして、しきい値付近でぱたぱたしないようにする。
struct AmplitudeLipSync: Sendable {
    var openThreshold: Float = 0.04
    var closeThreshold: Float = 0.02
    private(set) var shape: MouthShape = .closed

    init(openThreshold: Float = 0.04, closeThreshold: Float = 0.02) {
        self.openThreshold = openThreshold
        self.closeThreshold = closeThreshold
    }

    @discardableResult
    mutating func update(rms: Float) -> MouthShape {
        if shape == .closed, rms >= openThreshold {
            shape = .a
        } else if shape != .closed, rms < closeThreshold {
            shape = .closed
        }
        return shape
    }

    /// 音声サンプル（-1...1）の RMS
    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }
}

/// 再生中の時刻（または音量）に合わせて、先生の口のテクスチャを差し替える
///
/// 使い方: `play(timeline, clock: { audioPlayer.isPlaying ? audioPlayer.currentTime : nil })`。
/// `update()` は AvatarView が毎フレーム呼ぶ。
@MainActor
final class LipSyncPlayer {
    private enum Source {
        case none
        case timeline(MouthTimeline, clock: () -> TimeInterval?)
        case amplitude(level: () -> Float?)
    }

    /// 口を差し替える先。AvatarView が読み込んだモデルをつなぐ
    weak var model: TeacherModel?
    private(set) var currentShape: MouthShape = .closed
    private var source: Source = .none
    private var amplitude = AmplitudeLipSync()

    init() {}

    /// 文字タイミングから作った口の動きを、再生時刻に合わせて流す。時刻が nil なら止まっているとみなす
    func play(_ timeline: MouthTimeline, clock: @escaping () -> TimeInterval?) {
        source = .timeline(timeline, clock: clock)
        update()
    }

    /// 音量で開け閉めする（タイミングが取れない TTS 用）。音量が nil なら止まっているとみなす
    func followAmplitude(level: @escaping () -> Float?) {
        amplitude = AmplitudeLipSync()
        source = .amplitude(level: level)
        update()
    }

    func stop() {
        source = .none
        update()
    }

    /// 再生が終わっているか（タイムラインの最後を過ぎた、または止まった）
    var isFinished: Bool {
        switch source {
        case .none:
            return true
        case .timeline(let timeline, let clock):
            guard let time = clock() else { return true }
            return time >= timeline.duration
        case .amplitude(let level):
            return level() == nil
        }
    }

    @discardableResult
    func update() -> MouthShape {
        let shape: MouthShape
        switch source {
        case .none:
            shape = .closed
        case .timeline(let timeline, let clock):
            shape = clock().map { timeline.shape(at: $0) } ?? .closed
        case .amplitude(let level):
            shape = level().map { amplitude.update(rms: $0) } ?? .closed
        }
        currentShape = shape
        model?.setMouth(shape)
        return shape
    }
}
