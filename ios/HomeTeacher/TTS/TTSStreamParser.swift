import Foundation

/// 続けて届く JSON オブジェクトを 1 つずつ切り出す
///
/// ElevenLabs の `stream/with-timestamps` は JSON オブジェクトを続けて送ってくる。
/// 改行区切りか、改行なしでくっついて届くかは確かめられていないので、どちらでも読めるようにする。
/// かっこの深さを数えて、文字列の中（と `\"` などのエスケープ）は数えない。
/// 届くかたまりはオブジェクトの途中で切れていてよい（状態は次の `feed` に持ち越す）。
struct JSONObjectStreamScanner: Sendable {
    private var buffer: [UInt8] = []
    private var depth = 0
    private var inString = false
    private var escaped = false

    init() {}

    /// 届いたバイト列を入れて、できあがったオブジェクトを返す
    mutating func feed(_ bytes: some Sequence<UInt8>) -> [Data] {
        var objects: [Data] = []
        // { } " \ はすべて ASCII なので、UTF-8 の多バイト文字の途中と取り違えることはない
        for byte in bytes {
            if depth == 0 {
                // オブジェクトの外（改行・空白・配列の [ , ] など）は読み飛ばす
                guard byte == UInt8(ascii: "{") else { continue }
                buffer = [byte]
                depth = 1
                inString = false
                escaped = false
                continue
            }
            buffer.append(byte)
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"): depth += 1
            case UInt8(ascii: "}"):
                depth -= 1
                if depth == 0 {
                    objects.append(Data(buffer))
                    buffer.removeAll(keepingCapacity: true)
                }
            default: break
            }
        }
        return objects
    }

    /// 書きかけのオブジェクトが残っているか（ストリームが途中で切れたか）
    var hasPartialObject: Bool { depth > 0 }
}

/// ElevenLabs の `stream/with-timestamps`（Worker の /v1/tts が中継する）の本文を読む
struct ElevenLabsStreamParser: Sendable {
    private var scanner = JSONObjectStreamScanner()

    init() {}

    /// 1 つぶんの JSON。`normalized_alignment` は入力の文と文字が対応しないので使わない
    private struct Wire: Decodable {
        var audioBase64: String?
        var alignment: TTSAlignment?
        // エラーのとき（{"detail": {...}} や Worker の {"error": "..."}）
        var detail: JSONValue?
        var error: JSONValue?

        enum CodingKeys: String, CodingKey {
            case audioBase64 = "audio_base64"
            case alignment
            case detail
            case error
        }
    }

    mutating func feed(_ text: String) throws -> [TTSChunk] {
        try feed(Data(text.utf8))
    }

    mutating func feed(_ data: Data) throws -> [TTSChunk] {
        try scanner.feed(data).compactMap(Self.decode)
    }

    /// ストリームが終わったときに呼ぶ。オブジェクトの途中で切れていたら投げる
    func finish() throws {
        if scanner.hasPartialObject { throw TTSError.invalidChunk("stream ended in the middle of a JSON object") }
    }

    private static func decode(_ object: Data) throws -> TTSChunk? {
        let wire: Wire
        do {
            wire = try JSONDecoder().decode(Wire.self, from: object)
        } catch {
            throw TTSError.invalidChunk(String(decoding: object.prefix(200), as: UTF8.self))
        }
        if wire.audioBase64 == nil, wire.alignment == nil,
           let message = [wire.error, wire.detail].compactMap({ $0 }).first(where: { $0 != .null }) {
            throw TTSError.upstream(String(describing: message))
        }
        var audio = Data()
        if let base64 = wire.audioBase64, !base64.isEmpty {
            guard let decoded = Data(base64Encoded: base64) else {
                throw TTSError.invalidChunk("audio_base64 is not base64")
            }
            audio = decoded
        }
        if audio.isEmpty, wire.alignment == nil { return nil }
        return TTSChunk(audio: audio, alignment: wire.alignment)
    }
}
