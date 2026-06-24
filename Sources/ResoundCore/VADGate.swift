import Foundation
import AVFoundation
import FluidAudio   // AudioConverter（解码 16k mono）+ silero VAD（DiarModelCache）

/// 转录前 VAD 门控（方案 A）：用 silero VAD 找出有人声的区间，把长静音/纯噪声段从上传给
/// whisper 的音频里剔除，只把人声块按序拼接（块间留少量静音让 whisper 仍在边界断句）。
///
/// 为什么要做：whisper 这类模型「必须吐字」，在静音/背景音/杂音段上爱幻觉（凭空编出
/// 「谢谢观看」「字幕由…提供」之类高频套话）、爱重复，长静音还会把后续段落时间戳整体推偏。
/// 事前少喂垃圾即从根上减少这些翻车，顺带省上传体积/token。
///
/// 自限定（与 AudioNormalizer 同思路）：没多少静音可剪（人声占比很高）、VAD 不可用或导出失败
/// → 返回 nil，调用方退回原文件，零风险。剪辑只用于「转录输入」，存储/播放的 audio.m4a 不动。
///
/// 时间轴：拼接后 whisper 返回的是「压缩轴」时间，必须用 `spans` 映射回原始轴，才能与原音频、
/// 说话人分割（在原始音频上独立计算）对齐。
public enum VADGate {
    /// 压缩轴上一个保留块：compressedStart..<compressedStart+dur 线性对应原始轴 origStart..。
    public struct Span: Sendable {
        public let compressedStart: Double
        public let origStart: Double
        public let dur: Double
    }

    public struct Result: Sendable {
        public let url: URL          // 剪辑后的临时 m4a（调用方负责清理）
        public let spans: [Span]
    }

    /// 对 `url` 做 VAD 门控并导出剪辑后的 m4a。无可剪 / VAD 不可用 / 导出失败 → nil。
    /// - edgePad: 每个语音块前后各扩，防 VAD 削掉软起音/收尾。
    /// - bridge: 相邻语音块间隙小于此值视作自然停顿 → 不剪、并块（避免把句子切碎）。
    /// - gapPad: 压缩轴上块间插入的静音，给 whisper 一个断句锚点，避免两段话被粘成一段跨界。
    /// - minCutSavings: 预计能剪掉的静音少于此值就不值当 → nil。
    public static func voicedM4A(
        of url: URL,
        edgePad: Double = 0.2,
        bridge: Double = 0.5,
        gapPad: Double = 0.35,
        minCutSavings: Double = 3.0,
        log: (String) -> Void = { _ in }
    ) async throws -> Result? {
        // 1. 解码 16k mono → silero VAD 取语音区间（与说话人识别用同一套 VAD）
        let samples = try AudioConverter().resampleAudioFile(url)
        let totalDur = Double(samples.count) / 16000.0
        guard totalDur > 0 else { return nil }
        let vad = try await DiarModelCache.shared.vad()
        let voiced = try await vad.segmentSpeech(samples).map { (start: Double($0.startTime), end: Double($0.endTime)) }
        guard !voiced.isEmpty else { return nil }   // 一段语音都没检出：可能整段是噪声，交给原文件 + 后处理

        // 2. padding + 合并近邻（只真正剪掉间隙 > bridge 的静音）
        var blocks: [(start: Double, end: Double)] = []
        for v in voiced.sorted(by: { $0.start < $1.start }) {
            let s = max(0, v.start - edgePad), e = min(totalDur, v.end + edgePad)
            if var last = blocks.last, s - last.end < bridge {
                last.end = max(last.end, e); blocks[blocks.count - 1] = last
            } else {
                blocks.append((s, e))
            }
        }
        let voicedDur = blocks.reduce(0) { $0 + ($1.end - $1.start) }
        guard totalDur - voicedDur >= minCutSavings else { return nil }   // 没多少静音可剪，别折腾

        // 3. AVMutableComposition：把保留块按序拼起来（保留原音质，块间留 gapPad 静音）
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
        let comp = AVMutableComposition()
        guard let compTrack = comp.addMutableTrack(withMediaType: .audio,
                                                   preferredTrackID: kCMPersistentTrackID_Invalid) else { return nil }
        let ts: CMTimeScale = 600
        var cursor = CMTime.zero
        var spans: [Span] = []
        for b in blocks {
            let dur = b.end - b.start
            let range = CMTimeRange(start: CMTime(seconds: b.start, preferredTimescale: ts),
                                    duration: CMTime(seconds: dur, preferredTimescale: ts))
            try compTrack.insertTimeRange(range, of: track, at: cursor)
            spans.append(Span(compressedStart: cursor.seconds, origStart: b.start, dur: dur))
            cursor = cursor + range.duration + CMTime(seconds: gapPad, preferredTimescale: ts)
        }

        // 4. 导出 m4a（同 AudioNormalizer：AppleM4A preset，上传小）
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("resound-vad-\(UUID().uuidString).m4a")
        try? FileManager.default.removeItem(at: out)
        export.outputURL = out; export.outputFileType = .m4a
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else { return nil }
        log(String(format: "   ✂️ VAD 门控：%.0fs → %.0fs（剪掉静音/噪声 %.0fs，%d 段语音）",
                   totalDur, voicedDur, totalDur - voicedDur, spans.count))
        return Result(url: out, spans: spans)
    }

    /// 压缩轴时间 → 原始轴时间。落在保留块内：线性映射；落在块间静音 pad 里：贴到下一块起点；
    /// 超出末尾：贴末块终点。spans 必单调递增，故映射保序（end ≥ start 不变）。
    public static func mapToOriginal(_ tc: Double, spans: [Span]) -> Double {
        guard !spans.isEmpty else { return tc }
        for s in spans {
            if tc < s.compressedStart { return s.origStart }                 // 在它之前的 pad 里
            if tc <= s.compressedStart + s.dur { return s.origStart + (tc - s.compressedStart) }
        }
        let last = spans[spans.count - 1]
        return last.origStart + last.dur
    }

    /// 把整段转录的段落时间戳从压缩轴映射回原始轴（词级时间戳一并映射）。
    ///
    /// ⚠️ start/end 不独立映射：只把 start 映射回原始轴，end = 映射后 start + whisper 在**压缩轴**的原始时长。
    /// 否则若某 whisper 段跨过被剪的静音（如等待期零星嘟囔被归并成一段），独立映射会把它的 end 拉到
    /// 死区另一侧、时间戳横跨几分钟（实测「我现在要来我耶」被拉成 219s）。锚在 start + 保留原始时长：
    /// 对不跨界的段完全精确（块内映射是平移，dur 不变），对跨界段收缩回它真实说话的那一小段。
    public static func remap(_ t: Transcript, spans: [Span]) -> Transcript {
        guard !spans.isEmpty else { return t }
        let segs = t.segments.map { s -> Transcript.Segment in
            let ns = mapToOriginal(s.start, spans: spans)
            let ne = ns + max(0, s.end - s.start)
            let words = s.words.map { w -> Transcript.Word in
                let ws = mapToOriginal(w.start, spans: spans)
                return Transcript.Word(w: w.w, start: ws, end: ws + max(0, w.end - w.start))
            }
            return Transcript.Segment(id: s.id, start: ns, end: ne, text: s.text, words: words)
        }
        return Transcript(language: t.language, segments: segs)
    }
}
