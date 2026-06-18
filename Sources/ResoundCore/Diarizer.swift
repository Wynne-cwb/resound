import Foundation
import FluidAudio

/// 说话人分割（用 FluidAudio DiarizerManager；offline VBx 管线在本机 Bus error，待修）。
/// 返回的每段带 embedding + qualityScore，供 Phase B 声纹/匹配使用。
public func diarizeSmoke(audio: URL, threshold: Float = 0.7,
                         log: (String) -> Void = { print($0) }) async throws -> String {
    log("⬇️  准备 diarization 模型（首次下载）…")
    let models = try await DiarizerModels.downloadIfNeeded()

    let diarizer = DiarizerManager(config: DiarizerConfig(clusteringThreshold: threshold))
    diarizer.initialize(models: models)

    log("🎧 解码 16kHz mono…")
    let samples = try AudioConverter().resampleAudioFile(audio)

    log("🗣  diarization 中…")
    let result = try diarizer.performCompleteDiarization(samples)

    var bySpeaker: [String: (count: Int, dur: Double)] = [:]
    var lines: [String] = []
    for seg in result.segments {
        let spk = seg.speakerId
        let dur = Double(seg.endTimeSeconds - seg.startTimeSeconds)
        bySpeaker[spk, default: (0, 0)].count += 1
        bySpeaker[spk, default: (0, 0)].dur += dur
        lines.append(String(format: "  %@  %.1f-%.1fs  q=%.2f  emb=%d",
            spk, Double(seg.startTimeSeconds), Double(seg.endTimeSeconds),
            Double(seg.qualityScore), seg.embedding.count))
    }
    var summary = "说话人数: \(bySpeaker.count)，段数: \(result.segments.count)\n"
    for (spk, v) in bySpeaker.sorted(by: { $0.value.dur > $1.value.dur }) {
        summary += String(format: "  %@: %d 段, 共 %.0fs\n", spk, v.count, v.dur)
    }
    return summary + "--- 前 30 段 ---\n" + lines.prefix(30).joined(separator: "\n")
}

// MARK: - 用 ground-truth 转录评测 diarization

/// 解析 "HH:MM:SS 说话人" 行 → (秒, 说话人)。文本行/中文行不匹配会被跳过。
func parseGroundTruth(_ url: URL) -> [(t: Double, speaker: String)] {
    guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var out: [(Double, String)] = []
    for line in s.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: " ", maxSplits: 1).map { String($0) }
        guard parts.count == 2 else { continue }
        let tc = parts[0].split(separator: ":")
        guard tc.count == 3, let h = Int(tc[0]), let m = Int(tc[1]), let sec = Int(tc[2]) else { continue }
        out.append((Double(h * 3600 + m * 60 + sec), parts[1].trimmingCharacters(in: .whitespaces)))
    }
    return out
}

public func diarizeEval(audio: URL, transcript: URL, threshold: Float = 0.7,
                        log: (String) -> Void = { print($0) }) async throws -> String {
    let gt = parseGroundTruth(transcript)
    let gtSpeakers = Set(gt.map { $0.speaker }).sorted()
    log("📄 ground truth: \(gt.count) 条发言，\(gtSpeakers.count) 人: \(gtSpeakers.joined(separator: "/"))")

    let models = try await DiarizerModels.downloadIfNeeded()
    let diarizer = DiarizerManager(config: DiarizerConfig(clusteringThreshold: threshold))
    diarizer.initialize(models: models)
    let samples = try AudioConverter().resampleAudioFile(audio)
    log("🗣  diarization（threshold=\(threshold)）…")
    let segs = try diarizer.performCompleteDiarization(samples).segments

    func diarAt(_ t: Double) -> String? {
        if let hit = segs.first(where: { Double($0.startTimeSeconds) <= t && t <= Double($0.endTimeSeconds) }) {
            return hit.speakerId
        }
        return segs.min(by: {
            abs(Double($0.startTimeSeconds + $0.endTimeSeconds) / 2 - t)
                < abs(Double($1.startTimeSeconds + $1.endTimeSeconds) / 2 - t)
        })?.speakerId
    }

    // 每条 GT 发言 → diar 说话人
    var pairs: [(gt: String, diar: String)] = []
    for u in gt { if let d = diarAt(u.t) { pairs.append((u.speaker, d)) } }

    // 每个 diar 簇映射到占比最大的 GT 说话人
    var diarToGt: [String: [String: Int]] = [:]
    for p in pairs { diarToGt[p.diar, default: [:]][p.gt, default: 0] += 1 }
    let mapping = diarToGt.mapValues { $0.max(by: { $0.value < $1.value })!.key }

    let correct = pairs.filter { mapping[$0.diar] == $0.gt }.count
    let acc = pairs.isEmpty ? 0 : Double(correct) * 100 / Double(pairs.count)
    let diarCount = Set(segs.map { $0.speakerId }).count

    var report = """
    === diarization 评测 ===
    GT 说话人数: \(gtSpeakers.count)  |  diar 检出: \(diarCount)  |  段数: \(segs.count)
    发言级标注准确率: \(String(format: "%.1f%%", acc))（\(correct)/\(pairs.count)）
    --- 簇→人 映射 ---
    """
    for (d, counts) in diarToGt.sorted(by: { $0.value.values.reduce(0,+) > $1.value.values.reduce(0,+) }) {
        let total = counts.values.reduce(0, +)
        let detail = counts.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
        report += "\n  diar[\(d)] → \(mapping[d] ?? "?")  (\(total) 条: \(detail))"
    }
    return report
}
