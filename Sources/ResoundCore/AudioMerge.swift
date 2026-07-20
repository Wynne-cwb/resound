import Foundation
import AVFoundation

/// 多条录音音频合并：按给定顺序（合并功能按 recordedAt 升序）首尾相接成一条 m4a。
/// 段间不留空（不还原真实时间间隔——相隔可能几小时/几天，插静音会产出巨量死区）。
public struct AudioMerge {
    public init() {}

    /// 把 `urls` 按顺序拼成一条 m4a 写到 `dst`，返回总时长（秒）。
    /// 单条无音轨则跳过（不崩）；全部无内容则抛错。
    public func merge(_ urls: [URL], to dst: URL, log: (String) -> Void = { _ in }) async throws -> Double {
        let comp = AVMutableComposition()
        guard let compTrack = comp.addMutableTrack(withMediaType: .audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AudioError.exportFailed("无法创建合成音轨")
        }
        var cursor = CMTime.zero
        for u in urls {
            let asset = AVURLAsset(url: u)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                log("   ⚠️ 跳过无音轨：\(u.lastPathComponent)"); continue
            }
            let dur = try await asset.load(.duration)
            guard CMTimeGetSeconds(dur) > 0 else { continue }
            try compTrack.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: track, at: cursor)
            cursor = cursor + dur
        }
        guard CMTimeGetSeconds(cursor) > 0 else { throw AudioError.exportFailed("没有可合并的音频内容") }

        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioError.exportFailed("无法创建 AVAssetExportSession")
        }
        try? FileManager.default.removeItem(at: dst)
        export.outputURL = dst
        export.outputFileType = .m4a
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else {
            throw AudioError.exportFailed(export.error?.localizedDescription ?? "status=\(export.status.rawValue)")
        }
        return CMTimeGetSeconds(cursor)
    }
}
