import Foundation
import AVFoundation

public enum AudioError: Error, CustomStringConvertible {
    case exportFailed(String)
    public var description: String {
        switch self {
        case .exportFailed(let m): return "音频导出失败：\(m)"
        }
    }
}

public struct M4AExporter {
    public init() {}

    /// 把任意 AVFoundation 可读音频导出为 m4a (AAC)，返回时长（秒）。
    /// `range` 给定则只导出该时间段（秒）——MOSS 长音频分块用。
    public func exportM4A(from src: URL, to dst: URL,
                          range: (start: Double, end: Double)? = nil) async throws -> Double {
        let asset = AVURLAsset(url: src)

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioError.exportFailed("无法创建 AVAssetExportSession")
        }
        export.outputURL = dst
        export.outputFileType = .m4a
        if let range {
            let scale: CMTimeScale = 600
            export.timeRange = CMTimeRange(
                start: CMTime(seconds: range.start, preferredTimescale: scale),
                end: CMTime(seconds: range.end, preferredTimescale: scale))
        }

        try? FileManager.default.removeItem(at: dst)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously {
                cont.resume()
            }
        }

        if export.status != .completed {
            let msg = export.error?.localizedDescription ?? "status=\(export.status.rawValue)"
            throw AudioError.exportFailed(msg)
        }

        if let range { return range.end - range.start }
        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }
}
