import Foundation
import FluidAudio

/// Phase A 去风险冒烟：在一段音频上跑 FluidAudio diarization，看说话人数 + 分段。
public func diarizeSmoke(audio: URL, log: (String) -> Void = { print($0) }) async throws -> String {
    log("⬇️  准备 diarization 模型（首次下载）…")
    let models = try await DiarizerModels.downloadIfNeeded()

    let diarizer = DiarizerManager()
    diarizer.initialize(models: models)

    log("🎧 解码 16kHz mono…")
    let converter = AudioConverter()
    let samples = try converter.resampleAudioFile(audio)

    log("🗣  diarization 中…")
    let result = try diarizer.performCompleteDiarization(samples)

    var speakers = Set<String>()
    var lines: [String] = []
    for seg in result.segments {
        let spk = "\(seg.speakerId)"
        speakers.insert(spk)
        let s = Double(seg.startTimeSeconds), e = Double(seg.endTimeSeconds)
        lines.append(String(format: "  %@  %.1f-%.1fs", spk, s, e))
    }
    return "说话人数: \(speakers.count)，段数: \(result.segments.count)\n"
        + lines.prefix(50).joined(separator: "\n")
}
