import Foundation
import AVFoundation

/// 流式重采样 + 混音：把两路音频**边读边重采样到 16k mono 边混音写出**，全程只持有几个定长小缓冲，
/// 绝不把整条音频读进 `[Float]`。修复「结束长会时 resampleAudioFile 整读 11GB → 撑爆内存卡死整机」。
/// 同一实现供录音结束混音与离线恢复复用。
public enum StreamingMix {
    static let outRate = 16000.0
    static let chunk = 16384   // 每轮处理的 16k 帧数（≈1s），内存占用与之无关地小

    /// 16k mono float32 输出格式。
    static var out16k: AVAudioFormat { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outRate, channels: 1, interleaved: false)! }

    /// 把 mic/sys 两路流式重采样到 16k mono、按真实起点对齐（后启动的补前导静音）混音，
    /// 边写边落三个文件：混音 + 两条对齐后的 16k 分轨（wav）。任一路为空/读不了则跳过该路。
    /// startHost 为各自起点秒（同一 host clock）；nil 或偏移>5s 视为不加前导静音（按 0 对齐）。
    public static func mixTo16k(mic micURL: URL?, sys sysURL: URL?,
                                micStartHost: Double?, sysStartHost: Double?,
                                outputDir: URL = FileManager.default.temporaryDirectory,
                                uid: String = UUID().uuidString,
                                log: (String) -> Void = { _ in }) throws -> (mixed: URL, mic: URL?, sys: URL?) {
        // 对齐：后启动的一路前面补静音（帧数按 16k 算）
        var micLead = 0, sysLead = 0
        if let m = micStartHost, let s = sysStartHost {
            let off = m - s
            if abs(off) > 5 { log(String(format: "  ⚠️ 两轨起点偏移异常（%.2fs），按 0 对齐", off)) }
            else if off > 0 { micLead = Int(off * outRate) }
            else if off < 0 { sysLead = Int(-off * outRate) }
        }

        let micR = micURL.flatMap { StreamResampler16k(url: $0, leadFrames: micLead) }
        let sysR = sysURL.flatMap { StreamResampler16k(url: $0, leadFrames: sysLead) }
        guard micR != nil || sysR != nil else {
            throw NSError(domain: "StreamingMix", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "两路音频都读不了（检查文件/权限）"])
        }

        let fmt = out16k
        func makeFile(_ name: String) throws -> AVAudioFile {
            let url = outputDir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: url)
            return try AVAudioFile(forWriting: url, settings: fmt.settings)
        }
        let mixedFile = try makeFile("resound-meeting-\(uid).wav")
        let micFile = micR != nil ? try makeFile("resound-meeting-\(uid)-mic.wav") : nil
        let sysFile = sysR != nil ? try makeFile("resound-meeting-\(uid)-sys.wav") : nil

        var micBuf = [Float](repeating: 0, count: chunk)
        var sysBuf = [Float](repeating: 0, count: chunk)
        let mixPCM = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk))!
        let micPCM = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk))!
        let sysPCM = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(chunk))!

        var totalFrames = 0, micFrames = 0, sysFrames = 0
        while true {
            let mN = micBuf.withUnsafeMutableBufferPointer { micR?.read(into: $0.baseAddress!, cap: chunk) ?? 0 }
            let sN = sysBuf.withUnsafeMutableBufferPointer { sysR?.read(into: $0.baseAddress!, cap: chunk) ?? 0 }
            let n = max(mN, sN)
            if n == 0 { break }
            // 混音块
            if let dst = mixPCM.floatChannelData {
                for i in 0..<n {
                    let a = i < mN ? micBuf[i] : 0
                    let b = i < sN ? sysBuf[i] : 0
                    dst[0][i] = max(-1, min(1, a * 0.8 + b * 0.8))   // 轻抬 + 硬限幅，防混后过小
                }
            }
            mixPCM.frameLength = AVAudioFrameCount(n)
            try mixedFile.write(from: mixPCM)
            totalFrames += n
            // 分轨块（各写各的实际帧数；结束早的一路自然停写）
            if let micFile, mN > 0, let d = micPCM.floatChannelData {
                d[0].update(from: micBuf, count: mN); micPCM.frameLength = AVAudioFrameCount(mN)
                try micFile.write(from: micPCM); micFrames += mN
            }
            if let sysFile, sN > 0, let d = sysPCM.floatChannelData {
                d[0].update(from: sysBuf, count: sN); sysPCM.frameLength = AVAudioFrameCount(sN)
                try sysFile.write(from: sysPCM); sysFrames += sN
            }
        }
        guard totalFrames > 0 else {
            throw NSError(domain: "StreamingMix", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "混音结果为空（两路都无有效音频）"])
        }
        log(String(format: "  ✅ 流式混音完成：%.0fs（麦克风 %.0fs + 系统 %.0fs，分轨已保留）",
                   Double(totalFrames) / outRate, Double(micFrames) / outRate, Double(sysFrames) / outRate))
        return (mixedFile.url,
                (micFile != nil && micFrames > 0) ? micFile!.url : nil,
                (sysFile != nil && sysFrames > 0) ? sysFile!.url : nil)
    }
}

/// 单路流式重采样器：按需从文件读一小块 →**手动下混成单声道**→ 经 AVAudioConverter 只做采样率转换到 16k，
/// 可选在最前面吐一段静音（对齐用）。跨调用保持转换器状态，绝不整读。
///
/// ⚠️ 关键：不让 AVAudioConverter 做声道数转换——它对「离散多声道布局」（如 VPIO 产出的 7 声道）**没有下混
/// 系数会直接吐静音**（2026-07-02 抢救那场会踩过：源有健康人声，转换器却给出全零）。改为自己平均各声道成
/// 单声道，转换器只负责 rate（单声道→单声道无布局问题），对任意声道数都稳。
final class StreamResampler16k {
    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let inFormat: AVAudioFormat        // 文件原生格式（N 声道 @ 原生采样率）
    private let monoInFormat: AVAudioFormat     // 手动下混后：单声道 @ 原生采样率
    private let outFormat: AVAudioFormat        // 16k mono
    private var leadFrames: Int
    private var inputEOF = false
    private let inChunk: AVAudioFrameCount = 16384

    init?(url: URL, leadFrames: Int) {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let inFmt = f.processingFormat
        guard f.length > 0,
              let monoIn = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFmt.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: monoIn, to: out) else { return nil }
        self.file = f; self.inFormat = inFmt; self.monoInFormat = monoIn; self.outFormat = out; self.converter = conv
        self.leadFrames = max(0, leadFrames)
    }

    /// 填 out（16k mono，容量 cap 帧），返回写入帧数；0 = 彻底读完（前导静音 + 文件都吐完）。
    func read(into out: UnsafeMutablePointer<Float>, cap: Int) -> Int {
        var written = 0
        // 1) 前导静音
        if leadFrames > 0 {
            let n = min(leadFrames, cap)
            for i in 0..<n { out[i] = 0 }
            leadFrames -= n; written += n
            if written == cap { return written }
        }
        // 2) 文件重采样样本
        guard !inputEOF else { return written }
        let want = AVAudioFrameCount(cap - written)
        guard want > 0, let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: want) else { return written }
        var convErr: NSError?
        let status = converter.convert(to: outBuf, error: &convErr) { [weak self] _, outStatus in
            guard let self, !self.inputEOF else { outStatus.pointee = .endOfStream; return nil }
            // 读原生 N 声道块
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: self.inFormat, frameCapacity: self.inChunk) else {
                outStatus.pointee = .endOfStream; self.inputEOF = true; return nil
            }
            do { try self.file.read(into: inBuf, frameCount: self.inChunk) }
            catch { outStatus.pointee = .endOfStream; self.inputEOF = true; return nil }
            let frames = Int(inBuf.frameLength)
            if frames == 0 { outStatus.pointee = .endOfStream; self.inputEOF = true; return nil }
            // 手动下混成单声道（平均各声道）→ monoInFormat 缓冲
            guard let monoBuf = AVAudioPCMBuffer(pcmFormat: self.monoInFormat, frameCapacity: AVAudioFrameCount(frames)),
                  let src = inBuf.floatChannelData, let dst = monoBuf.floatChannelData else {
                outStatus.pointee = .endOfStream; self.inputEOF = true; return nil
            }
            let ch = Int(self.inFormat.channelCount)
            for i in 0..<frames {
                var acc: Float = 0
                for c in 0..<ch { acc += src[c][i] }
                dst[0][i] = acc / Float(ch)
            }
            monoBuf.frameLength = AVAudioFrameCount(frames)
            outStatus.pointee = .haveData
            return monoBuf
        }
        if status == .error { inputEOF = true; return written }
        let produced = Int(outBuf.frameLength)
        if produced > 0, let ch = outBuf.floatChannelData {
            for i in 0..<produced { out[written + i] = ch[0][i] }
            written += produced
        }
        if status == .endOfStream || produced == 0 { inputEOF = true }
        return written
    }
}
