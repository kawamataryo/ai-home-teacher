import UIKit

/// 起動引数 `-snapshotEvery <秒>` のとき、画面を決まった間隔で Documents/snapshots/ に PNG で残す（最大 60 枚）。
/// 実機の画面を、Mac から `devicectl` で取り出して確かめるため（#105・#107）。写真や音声は含まない（アプリの画面だけ）
@MainActor
enum SessionSnapshotFile {
    static func interval(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Double? {
        guard let index = arguments.firstIndex(of: "-snapshotEvery"), index + 1 < arguments.count,
              let seconds = Double(arguments[index + 1]), seconds > 0 else { return nil }
        return seconds
    }

    static func run(every seconds: Double, limit: Int = 60) async {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let dir = documents.appending(path: "snapshots")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<limit {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows).first(where: \.isKeyWindow) else { continue }
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            try? image.pngData()?.write(to: dir.appending(path: String(format: "snap-%03d.png", index)))
        }
    }
}
