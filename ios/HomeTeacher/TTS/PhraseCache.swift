import Foundation
import OSLog

/// 定型句（「いいね！」「どれどれ」「そろそろ休憩しよっか」など）の音声キャッシュ
///
/// 一覧は `Resources/Phrases/teacher_phrases.json`（`scripts/generate_phrases.mjs` と共通）。
/// 音声は次の順に探し、見つかればネットワークなしですぐ再生できる:
/// 1. 同梱の `phrase_<key>.json`（`scripts/generate_phrases.mjs` で ElevenLabs から作ってリポジトリに入れたもの）
/// 2. ディスクのキャッシュ（`prepare` で初回起動時に作る。Worker が使えなければ AVSpeechSynthesizer の声）
///
/// どちらも中身は `SynthesizedSpeech` の JSON（音声は base64）。文が一覧と違えば古いものとして使わない。
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
    private var loaded: [String: SynthesizedSpeech] = [:]
    private let logger = Logger(subsystem: "com.kawamataryo.HomeTeacher", category: "PhraseCache")

    init(phrases: [Phrase], bundle: Bundle = .main, directory: URL? = PhraseCache.defaultDirectory) {
        self.phrases = phrases
        self.bundle = bundle
        self.directory = directory
    }

    /// 同梱の一覧で作る
    convenience init(bundle: Bundle = .main, directory: URL? = PhraseCache.defaultDirectory) throws {
        try self.init(phrases: Self.loadManifest(bundle: bundle), bundle: bundle, directory: directory)
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
        let found = [bundledURL(for: phrase), diskURL(for: phrase)]
            .compactMap { $0 }
            .lazy
            .compactMap { Self.read($0, expecting: phrase) }
            .first
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
    /// - Returns: 新しく作った数
    @discardableResult
    func prepare(primary: any TTSProvider, fallback: (any TTSProvider)?, timeout: Duration = .seconds(10)) async -> Int {
        var created = 0
        for phrase in phrases {
            if Task.isCancelled { break }
            let existing = speech(for: phrase)
            if existing?.provider == primary.identifier { continue }
            do {
                let speech = try await withTTSTimeout(timeout) { try await primary.synthesizeAll(phrase.text) }
                store(speech, for: phrase)
                created += 1
                continue
            } catch {
                logger.info("定型句を \(primary.identifier, privacy: .public) で作れなかった \(phrase.key, privacy: .public)")
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
        bundle.url(forResource: Self.bundledPrefix + phrase.key, withExtension: "json")
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
