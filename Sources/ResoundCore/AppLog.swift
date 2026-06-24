import Foundation

/// 轻量持久化日志：追加到 `~/Library/Application Support/Resound/resound.log`。
///
/// 为什么需要：App 全程用 `print` 输出，而 `open` 启动的 GUI App 的 stdout **不进系统统一日志、关掉即丢**，
/// 关键失败（转写/入库异常）当场无从排查。把这些失败**落盘**，事后 `tail resound.log` 即可还原。
/// 线程安全（串行队列）；超过 ~1MB 自动截掉前半，避免无限增长。
public enum AppLog {
    private static let queue = DispatchQueue(label: "resound.applog")
    private static let maxBytes = 1_000_000

    private static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Resound", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("resound.log")
    }

    /// 当前日志文件路径（供 UI「在 Finder 中显示日志」用）。
    public static var logFileURL: URL { fileURL() }

    public static func log(_ message: String) {
        let now = Date()
        print("[log] \(message)")   // 开发时 CLI/Xcode 仍能即时看到
        queue.async {
            let stamp = stampFormatter.string(from: now)
            let line = "[\(stamp)] \(message)\n"
            let url = fileURL()
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                h.seekToEndOfFile()
                try? h.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: url)
            }
            rollIfNeeded(url)
        }
    }

    /// 记一条错误（带上下文 + Swift 错误的完整描述，含底层 domain/code）。
    public static func error(_ context: String, _ error: Error) {
        let ns = error as NSError
        log("❌ \(context) — \(error) [\(ns.domain) #\(ns.code)]")
    }

    // 仅在串行队列上访问 → 线程安全。
    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private static func rollIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes, let data = try? Data(contentsOf: url) else { return }
        try? Data(data.suffix(maxBytes / 2)).write(to: url)   // 留后半段（较新），丢前半段
    }
}
