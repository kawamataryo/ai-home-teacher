@preconcurrency import AVFoundation
import OSLog
import Vision

/// 前のカメラ（画面側）で子どもを見て、手の動きと顔の有無だけを読み取る（spec §3⑥）。
///
/// - 低い解像度（VGA）で動かし、読み取るのは 0.5 秒に 1 枚だけ（`sampleInterval`）
/// - Vision で顔（VNDetectFaceRectanglesRequest）と手の姿勢（VNDetectHumanHandPoseRequest）を見る。
///   手が映らないこともあるので、下の方（ノートと手のあたり）の小さな濃淡の格子のフレーム差分も使う
/// - 映像は端末の外に出さず、保存もしない。前のフレームについて持つのは 32×24 の濃淡と手の点の位置だけ
/// - 映像だけのセッション（音声はつながない）。マイクとエコーキャンセルの AVAudioSession を触らないため
/// - 「見て」の撮影（CameraCapture）とは別のセッション。同時には動かさない（WatchAwarePhotoCapture が止めて戻す）
@MainActor
final class ActivityWatcher: NSObject, ActivityWatching {
    var onSample: (@MainActor (ActivitySample) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var input: AVCaptureDeviceInput?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// startRunning / stopRunning と、フレームの読み取りはこの列で
    private let queue = DispatchQueue(label: "com.kawamataryo.HomeTeacher.watch")
    private let analyzer = FrameActivityAnalyzer()

    override init() {
        super.init()
        session.automaticallyConfiguresApplicationAudioSession = false
    }

    func start() async throws {
        guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraError.unauthorized }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw CameraError.unavailable
        }
        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
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
            output.alwaysDiscardsLateVideoFrames = true
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            output.setSampleBufferDelegate(self, queue: queue)
            session.addOutput(output)
        }
        session.commitConfiguration()
        Self.limitFrameRate(device)
        keepUpright(device)

        analyzer.reset()
        let session = session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                if !session.isRunning { session.startRunning() }
                done.resume()
            }
        }
    }

    func stop() async {
        rotationObservation = nil
        let session = session
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                if session.isRunning { session.stopRunning() }
                done.resume()
            }
        }
    }

    /// iPad の向きに合わせてフレームを立てる（向きが違うと顔が見つからず、席を立ったとまちがえる）
    private func keepUpright(_ device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotation = coordinator
        apply(angle: coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, change in
            guard let angle = change.newValue else { return }
            Task { @MainActor in self?.apply(angle: angle) }
        }
    }

    private func apply(angle: CGFloat) {
        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    /// 15fps まで下げる（読み取るのは 2 枚/秒なので、それ以上はいらない）
    private static func limitFrameRate(_ device: AVCaptureDevice) {
        let target = CMTime(value: 1, timescale: 15)
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameDuration <= target && target <= $0.maxFrameDuration }),
              (try? device.lockForConfiguration()) != nil
        else { return }
        device.activeVideoMinFrameDuration = target
        device.activeVideoMaxFrameDuration = target
        device.unlockForConfiguration()
    }
}

extension ActivityWatcher: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let sample = analyzer.process(sampleBuffer) else { return }
        Task { @MainActor in self.onSample?(sample) }
    }
}

/// フレームから ActivitySample を作る。カメラの列（`ActivityWatcher.queue`）の上だけで使う
final class FrameActivityAnalyzer: @unchecked Sendable {
    /// 読み取りの間隔
    static let sampleInterval = 0.5
    /// フレーム差分を見る格子の大きさ
    static let gridWidth = 32
    static let gridHeight = 24
    /// フレーム差分を見る範囲（上から何割より下か。ノートと手のあたり）
    static let motionRegionTop = 0.45

    private let lock = NSLock()
    private var lastProcessed: Double = -.infinity
    private var previousGrid: [UInt8] = []
    private var previousHandPoints: [CGPoint] = []
    private let logger = Logger(subsystem: "com.kawamataryo.HomeTeacher", category: "WatchOver")

    func reset() {
        lock.withLock {
            lastProcessed = -.infinity
            previousGrid = []
            previousHandPoints = []
        }
    }

    func process(_ sampleBuffer: CMSampleBuffer) -> ActivitySample? {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard time - lastProcessed >= Self.sampleInterval else { return nil }
        lastProcessed = time

        let grid = Self.lumaGrid(pixelBuffer)
        let frameMotion = MotionEstimator.frameDifference(previousGrid, grid)
        previousGrid = grid

        let faces = VNDetectFaceRectanglesRequest()
        let hands = VNDetectHumanHandPoseRequest()
        hands.maximumHandCount = 2
        // フレームは keepUpright で立ててある
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([faces, hands])
        } catch {
            logger.error("Vision に失敗: \(String(describing: error), privacy: .public)")
        }
        let facePresent = (faces.results ?? []).contains { $0.confidence > 0.5 }
        let points = (hands.results ?? []).flatMap(Self.keyPoints)
        let handMotion = MotionEstimator.handDisplacement(previousHandPoints, points)
        previousHandPoints = points
        return ActivitySample(
            facePresent: facePresent, handsVisible: !points.isEmpty, frameMotion: frameMotion, handMotion: handMotion
        )
    }

    /// 手首と指先の位置（Vision の正規化座標）
    private static func keyPoints(_ observation: VNHumanHandPoseObservation) -> [CGPoint] {
        let joints: [VNHumanHandPoseObservation.JointName] = [.wrist, .indexTip, .thumbTip]
        return joints.compactMap { joint in
            guard let point = try? observation.recognizedPoint(joint), point.confidence > 0.3 else { return nil }
            return point.location
        }
    }

    /// 明るさ（Y）の面の下の方を、小さな格子の平均にする
    private static func lumaGrid(_ pixelBuffer: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self)
        else { return [] }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let top = Int(Double(height) * motionRegionTop)
        let regionHeight = height - top
        guard width >= gridWidth, regionHeight >= gridHeight else { return [] }
        let cellWidth = width / gridWidth
        let cellHeight = regionHeight / gridHeight
        var grid = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for gy in 0..<gridHeight {
            for gx in 0..<gridWidth {
                var total = 0
                var count = 0
                // セルの中を 4 画素おきに見る
                for y in Swift.stride(from: top + gy * cellHeight, to: top + (gy + 1) * cellHeight, by: 4) {
                    let row = base + y * stride
                    for x in Swift.stride(from: gx * cellWidth, to: (gx + 1) * cellWidth, by: 4) {
                        total += Int(row[x])
                        count += 1
                    }
                }
                grid[gy * gridWidth + gx] = UInt8(total / max(count, 1))
            }
        }
        return grid
    }
}
