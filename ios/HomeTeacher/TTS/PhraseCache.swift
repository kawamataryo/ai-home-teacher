import Foundation
import OSLog

/// 定型句（「いいね！」「どれどれ」「そろそろ休憩しよっか」など）の音声キャッシュ
///
/// 一覧は `Resources/Phrases/teacher_phrases.json`（`scripts/generate_phrases.mjs` と共通）。
/// 音声は次の順に探し、見つかればネットワークなしですぐ再生できる:
/// 1. 同梱の `phrase_<key>.json`（`scripts/generate_phrases.mjs` で ElevenLabs から作ってリポジトリに入れたもの）
/// 2. ディスクのキャッシュ（`prepare` で初回起動時に作る。Worker が使えなければ AVSpeechSynthesizer の声）
/// ただし `preferredProvider`（いま先生の声に使っている TTS）で作ったものがあれば、そちらを先に使う
/// （Azure に切り替えたのに、定型句だけ同梱の ElevenLabs の声で話さないように）。
///
/// どちらも中身は `SynthesizedSpeech` の JSON（音声は base64）。文が一覧と違えば古いものとして使わない。
///
/// キャラごとに分ける（#120）。別のキャラの声が混ざらないように、同梱は `phrase_<キャラ>_<key>`、ディスクは
/// `PhraseCache/characters/<キャラ>/` を見る。既定の先生は今までと同じ場所（`phrase_<key>`、`PhraseCache/`）のまま。
@MainActor
final class PhraseCache {
    struct Phrase: Codable, Equatable, Sendable {
        var key: String
        var text: String
    }

    static let manifestName = "teacher_phrases"
    static let bundledPrefix = "phrase_"

    let phrases: [Phrase]
    private let bundle: Bundle
    /// nil ならディスクに書かない（テスト用）
    private let directory: URL?
    /// 先に使う声（`TTSProvider.identifier`）。nil なら見つけた順
    private let preferredProvider: String?
    /// 同梱の音声の名前に付ける印。既定の先生は空
    private let bundledInfix: String
    /// 共通の文 → このキャラの定型句（言い替えがあるものだけ）
    private let replacements: [String: Phrase]
    private var loaded: [String: SynthesizedSpeech] = [:]
    private let logger = Logger(subsystem: "com.kawamataryo.HomeTeacher", category: "PhraseCache")

    init(
        phrases: [Phrase], bundle: Bundle = .main, directory: URL? = PhraseCache.defaultDirectory, preferredProvider: String? = nil,
        character: TeacherCharacter = .haru
    ) {
        self.phrases = phrases.map { phrase in
            character.phrases[phrase.key].map { Phrase(key: phrase.key, text: $0) } ?? phrase
        }
        var replacements: [String: Phrase] = [:]
        for phrase in phrases {
            if let text = character.phrases[phrase.key] {
                replacements[Self.normalize(phrase.text)] = Phrase(key: phrase.key, text: text)
            }
        }
        self.replacements = replacements
        bundledInfix = character.id == TeacherCharacter.haru.id ? "" : "\(character.id)_"
        self.bundle = bundle
        self.directory = directory
        self.preferredProvider = preferredProvider
    }

    /// 同梱の一覧で作る
    convenience init(
        bundle: Bundle = .main, directory: URL? = PhraseCache.defaultDirectory, preferredProvider: String? = nil,
        character: TeacherCharacter = .haru
    ) throws {
        try self.init(
            phrases: Self.loadManifest(bundle: bundle), bundle: bundle,
            directory: directory.map { Self.directory(for: character, base: $0) }, preferredProvider: preferredProvider,
            character: character
        )
    }

    /// キャラごとの保存先。既定の先生は今までと同じ場所
    static func directory(for character: TeacherCharacter, base: URL) -> URL {
        guard character.id != TeacherCharacter.haru.id else { return base }
        return base.appending(path: "characters/\(character.id)", directoryHint: .isDirectory)
    }

    static func loadManifest(bundle: Bundle = .main) throws -> [Phrase] {
        guard let url = bundle.url(forResource: manifestName, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([Phrase].self, from: Data(contentsOf: url))
    }

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "PhraseCache", directoryHint: .isDirectory)
    }

    /// 比べるための形。前後の空白と、文末の句読点（。！？…）は見ない
    static func normalize(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = result.last, "。．.！!？?…〜～ 　".contains(last) {
            result.removeLast()
        }
        return result
    }

    /// 実際に話す文。共通の定型句で、このキャラに言い替えがあればそちらにする
    func spokenText(for text: String) -> String {
        replacements[Self.normalize(text)]?.text ?? text
    }

    func phrase(for text: String) -> Phrase? {
        let normalized = Self.normalize(text)
        guard !normalized.isEmpty else { return nil }
        return phrases.first { Self.normalize($0.text) == normalized }
    }

    func phrase(forKey key: String) -> Phrase? {
        phrases.first { $0.key == key }
    }

    /// 定型句なら、すぐ再生できる音声を返す
    func speech(for text: String) -> SynthesizedSpeech? {
        guard let phrase = phrase(for: text) else { return nil }
        return speech(for: phrase)
    }

    func speech(for phrase: Phrase) -> SynthesizedSpeech? {
        if let speech = loaded[phrase.key] { return speech }
        let candidates = [bundledURL(for: phrase), diskURL(for: phrase)]
            .compactMap { $0 }
            .compactMap { Self.read($0, expecting: phrase) }
        let found = candidates.first { $0.provider == preferredProvider } ?? candidates.first
        loaded[phrase.key] = found
        return found
    }

    /// 音声を覚える（ディスクにも書く）
    func store(_ speech: SynthesizedSpeech, for phrase: Phrase) {
        loaded[phrase.key] = speech
        guard let url = diskURL(for: phrase), let directory else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(speech).write(to: url, options: .atomic)
        } catch {
            logger.error("定型句を保存できなかった \(phrase.key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// まだ音声がない定型句を作る（初回起動時に裏で呼ぶ）
    ///
    /// `primary`（ElevenLabs）で作ったものがあればそのまま。予備の声（AVSpeechSynthesizer）のものしかなければ
    /// `primary` で作り直してみる。`primary` が失敗したら、何もないものだけ `fallback` で作る。
    /// 失敗した時点で、残りの定型句にも `primary` は使わない。
    /// - Returns: 新しく作った数
    @discardableResult
    func prepare(primary: any TTSProvider, fallback: (any TTSProvider)?, timeout: Duration = .seconds(10)) async -> Int {
        var created = 0
        // 一度失敗したら（オフラインなど）残りは primary を試さない。全部の時間切れを待たないため
        var primaryAvailable = true
        for phrase in phrases {
            if Task.isCancelled { break }
            let existing = speech(for: phrase)
            if existing?.provider == primary.identifier { continue }
            if primaryAvailable {
                do {
                    let speech = try await withTTSTimeout(timeout) { try await primary.synthesizeAll(phrase.text) }
                    store(speech, for: phrase)
                    created += 1
                    continue
                } catch {
                    primaryAvailable = false
                    logger.info("定型句を \(primary.identifier, privacy: .public) で作れなかった \(phrase.key, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            guard existing == nil, let fallback, !Task.isCancelled else { continue }
            if let speech = try? await fallback.synthesizeAll(phrase.text) {
                store(speech, for: phrase)
                created += 1
            }
        }
        return created
    }

    private func bundledURL(for phrase: Phrase) -> URL? {
        bundle.url(forResource: Self.bundledPrefix + bundledInfix + phrase.key, withExtension: "json")
    }

    private func diskURL(for phrase: Phrase) -> URL? {
        directory?.appending(path: "\(phrase.key).json")
    }

    private static func read(_ url: URL, expecting phrase: Phrase) -> SynthesizedSpeech? {
        guard let data = try? Data(contentsOf: url),
              let speech = try? JSONDecoder().decode(SynthesizedSpeech.self, from: data),
              speech.text == phrase.text, !speech.audio.isEmpty
        else { return nil }
        return speech
    }
}

extension PhraseCache {
    /// 起動時に裏で呼ぶ。足りない定型句の音声を作ってディスクにためる
    /// （Worker の設定がなければ AVSpeechSynthesizer の声だけで作る）。テストのホストとして起動したときは何もしない
    static func warmUp(config: AppConfig?, character: TeacherCharacter = .haru) async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let system = SystemTTSProvider()
        if let config {
            let primary = config.ttsProvider.makeProvider(client: WorkerClient(config: config), voice: character.voice)
            guard let cache = try? PhraseCache(preferredProvider: primary.identifier, character: character) else { return }
            await cache.prepare(primary: primary, fallback: system)
        } else {
            guard let cache = try? PhraseCache(character: character) else { return }
            await cache.prepare(primary: system, fallback: nil)
        }
    }
}
