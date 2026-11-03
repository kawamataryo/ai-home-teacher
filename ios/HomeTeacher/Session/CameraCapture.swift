@preconcurrency import AVFoundation
import AudioToolbox
import OSLog
import UIKit

/// どちらのカメラで撮るか。iPad をスタンドに立ててノートを撮るなら、ノート側を向いたカメラを選ぶ
enum CameraPosition: String, CaseIterable, Sendable {
    case front
    case back

    var label: String {
        switch self {
        case .front: "前のカメラ（画面側）"
        case .back: "後ろのカメラ"
        }
    }

    var avPosition: AVCaptureDevice.Position {
        switch self {
        case .front: .front
        case .back: .back
        }
    }
}

enum CameraError: LocalizedError {
    case unauthorized
    case unavailable
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .unauthorized: "カメラが許可されていません"
        case .unavailable: "カメラが見つかりません"
        case .captureFailed: "写真を撮れませんでした"
        }
    }
}

/// 写真を 1 枚撮る。テストではモックに差し替える
@MainActor
protocol PhotoCapturing: AnyObject {
    var isAvailable: Bool { get }
    /// カメラを準備する（撮る直前のカウントダウンと並べて呼ぶ）
    func prepare(position: CameraPosition) async throws
    /// 撮って、カメラを止める
    func capture() async throws -> UIImage
}

/// 撮る前のカウントダウン（「3・2・1・カシャ」）。`onTick` には残りの数（3, 2, 1）が渡る
@MainActor
protocol CountdownPlaying: AnyObject {
    func countdown(from start: Int, onTick: @escaping @MainActor (Int) -> Void) async
}

/// システムの音で数える（ピッ・ピッ・ピッ）。シャッター音は撮るときに AVCapturePhotoOutput が鳴らす
@MainActor
final class SystemSoundCountdown: CountdownPlaying {
    /// 短い「ピッ」（Tock）
    static let tickSound: SystemSoundID = 1104

    func countdown(from start: Int, onTick: @escaping @MainActor (Int) -> Void) async {
        for n in stride(from: start, through: 1, by: -1) {
            onTick(n)
            AudioServicesPlaySystemSound(Self.tickSound)
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

/// AVCaptureSession で写真を撮る（spec §3②）。
///
/// - 映像だけのセッション（音声の入力はつながない）。マイクとエコーキャンセルの AVAudioSession を触らないため
/// - 撮るときだけ動かし、撮ったら止める。写真は呼び出し側が縮めて送り、そのあと捨てる（端末にも保存しない）
@MainActor
final class CameraCapture: NSObject, PhotoCapturing {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var input: AVCaptureDeviceInput?
    private var continuation: CheckedContinuation<UIImage, Error>?
    /// startRunning / stopRunning は時間がかかるので、MainActor の外で呼ぶ
    private let queue = DispatchQueue(label: "com.kawamataryo.HomeTeacher.camera")
    private let logger = Logger(subsystem: "com.kawamataryo.HomeTeacher", category: "Camera")

    override init() {
        super.init()
        // マイク側（voice processing）の AVAudioSession の設定を書きかえさせない
        session.automaticallyConfiguresApplicationAudioSession = false
    }

    /// カメラがあり、拒否されていない（拒否されていたら撮影ボタンも「見て」の判定も出さない。#66）
    var isAvailable: Bool {
        Self.hasCamera && SystemPermissions.cameraState != .denied
    }

    static var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
            || AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    func prepare(position: CameraPosition) async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraError.unauthorized }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position.avPosition)
            ?? AVCaptureDevice.default(for: .video)
        else { throw CameraError.unavailable }

        session.beginConfiguration()
        session.sessionPreset = .photo
        if input?.device != device {
            if let input { session.removeInput(input) }
            let newInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(newInput) else {
                session.commitConfiguration()
                throw CameraError.unavailable
            }
            session.addInput(newInput)
            input = newInput
        }
        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()

        let session = session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                if !session.isRunning { session.startRunning() }
                done.resume()
            }
        }
    }

    func capture() async throws -> UIImage {
        guard session.isRunning else { throw CameraError.captureFailed }
        defer { stopSession() }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func stopSession() {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }

    private func finish(_ result: Result<UIImage, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

extension CameraCapture: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            if let error {
                self.logger.error("撮影に失敗: \(String(describing: error), privacy: .public)")
                self.finish(.failure(error))
            } else if let data, let image = UIImage(data: data) {
                self.finish(.success(image))
            } else {
                self.finish(.failure(CameraError.captureFailed))
            }
        }
    }
}
