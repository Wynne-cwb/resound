import Foundation
import AVFoundation
import Accelerate

/// 转录前响度归一：测峰值 → 算增益（把过小的人声提上来，封顶防噪声炸开）→ 用 AVAssetExportSession
/// 套 audioMix 增益重新导出**压缩 m4a**（保持上传小、不拖慢在线转录）。仅用于转录输入，不动存储/播放音频。
/// 已经够响的录音直接返回 nil（调用方退回原文件），所以是自限定的：只对大会议室小声场景生效。
public enum AudioNormalizer {
    public static func normalizedM4A(of url: URL, targetPeak: Float = 0.9, maxGainDB: Float = 18) async throws -> URL? {
        let peak = try measurePeak(url)
        guard peak > 0.0001 else { return nil }
        let maxGain = pow(10, maxGainDB / 20)
        let gain = min(targetPeak / peak, maxGain)
        guard gain > 1.05 else { return nil }   // 本就够响，不折腾

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.setVolume(gain, at: .zero)
        let mix = AVMutableAudioMix(); mix.inputParameters = [params]

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("resound-norm-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out; export.outputFileType = .m4a; export.audioMix = mix
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else { return nil }
        return out
    }

    /// 分块读取算全局峰值（不一次性把整段塞进内存）。
    private static func measurePeak(_ url: URL) throws -> Float {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return 0 }
        var peak: Float = 0
        while true {
            try f.read(into: buf, frameCount: chunk)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            if let ch = buf.floatChannelData {
                for c in 0..<Int(fmt.channelCount) {
                    var p: Float = 0; vDSP_maxmgv(ch[c], 1, &p, vDSP_Length(n)); peak = max(peak, p)
                }
            }
            if n < Int(chunk) { break }
        }
        return peak
    }
}
