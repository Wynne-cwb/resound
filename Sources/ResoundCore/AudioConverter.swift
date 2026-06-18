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

public struct AudioConverter {
    public init() {}

    /// 把任意 AVFoundation 可读音频导出为 m4a (AAC)，返回时长（秒）。
    public func exportM4A(from src: URL, to dst: URL) async throws -> Double {
        let asset = AVURLAsset(url: src)

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioError.exportFailed("无法创建 AVAssetExportSession")
        }
        export.outputURL = dst
        export.outputFileType = .m4a

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

        let duration = try await asset.load(.duration)
        return CMTimeGetSeconds(duration)
    }
}
