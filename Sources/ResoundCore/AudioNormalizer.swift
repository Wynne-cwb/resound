import Foundation
import AVFoundation
import Accelerate

/// 转录前响度归一：**分窗自适应增益**（默认 5s 窗）——每窗独立测峰值、独立算增益，窗间用短 ramp 平滑。
/// 治两类场景：①整条都小声（大会议室远场）②前小后大（会议前几分钟只有远端小声说话，
/// 全局峰值被后段撑正常 → 单增益方案会整条跳过，小声段喂给 whisper 直接幻觉）。
/// 用 AVAssetExportSession 套 audioMix 增益重新导出**压缩 m4a**（保持上传小、不拖慢在线转录）。
/// 仅用于转录输入，不动存储/播放音频。整条都够响时返回 nil（调用方退回原文件），自限定。
public enum AudioNormalizer {
    public static func normalizedM4A(of url: URL, targetPeak: Float = 0.9, maxGainDB: Float = 18,
                                     windowSec: Double = 5) async throws -> URL? {
        let peaks = try windowPeaks(url, windowSec: windowSec)
        guard !peaks.isEmpty else { return nil }
        let maxGain = pow(10, maxGainDB / 20)
        let noiseFloor: Float = 0.004   // ≈-48dB：低于此视为静音/纯底噪窗，不提增益（防把噪声拉满）
        let gains = peaks.map { p -> Float in
            guard p > noiseFloor else { return 1 }
            return min(max(targetPeak / p, 1), maxGain)
        }
        guard gains.contains(where: { $0 > 1.05 }) else { return nil }   // 整条都够响，不折腾

        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let params = AVMutableAudioMixInputParameters(track: track)
        let ramp = 0.4
        let rampDur = CMTime(seconds: ramp, preferredTimescale: 600)
        params.setVolume(gains[0], at: .zero)
        var prev = gains[0]
        for i in 1..<gains.count where gains[i] != prev {
            // 不对称 ramp：降增益提前到上一窗末尾完成（防大声窗开头仍挂着高增益 → 削波）；
            // 升增益放在新窗开头（新窗本来就小声，慢半拍无害）。
            let boundary = windowSec * Double(i)
            let start = gains[i] < prev ? boundary - ramp : boundary
            params.setVolumeRamp(fromStartVolume: prev, toEndVolume: gains[i],
                                 timeRange: CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                                        duration: rampDur))
            prev = gains[i]
        }
        let mix = AVMutableAudioMix(); mix.inputParameters = [params]

        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("resound-norm-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out; export.outputFileType = .m4a; export.audioMix = mix
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else { return nil }
        return out
    }

    /// 分块读取，按 windowSec 分窗算各窗峰值（不一次性把整段塞进内存）。
    private static func windowPeaks(_ url: URL, windowSec: Double) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        let windowFrames = max(1, Int(windowSec * fmt.sampleRate))
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return [] }
        var peaks: [Float] = []
        var cur: Float = 0
        var framesInWindow = 0
        while true {
            try f.read(into: buf, frameCount: chunk)
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let ch = buf.floatChannelData else { break }
            var offset = 0
            while offset < n {
                let take = min(n - offset, windowFrames - framesInWindow)
                for c in 0..<Int(fmt.channelCount) {
                    var p: Float = 0
                    vDSP_maxmgv(ch[c] + offset, 1, &p, vDSP_Length(take))
                    cur = max(cur, p)
                }
                offset += take
                framesInWindow += take
                if framesInWindow == windowFrames {
                    peaks.append(cur); cur = 0; framesInWindow = 0
                }
            }
            if n < Int(chunk) { break }
        }
        if framesInWindow > 0 { peaks.append(cur) }
        return peaks
    }
}
