import Foundation
import FluidAudio

public enum DiarBackend: String, CaseIterable {
    case manager      // FluidAudio DiarizerManager（聚类，分不开相似嗓音）
    case sortformer   // FluidAudio Sortformer（≤4 人，身份最稳）
}

public struct DiarSeg {
    public let spk: String
    public let start: Double
    public let end: Double
}

/// 跑分割，返回统一的段列表。
public func runDiarization(audio: URL, backend: DiarBackend, threshold: Float,
                           log: (String) -> Void = { print($0) }) async throws -> [DiarSeg] {
    let samples = try AudioConverter().resampleAudioFile(audio)
    switch backend {
    case .manager:
        log("⬇️  DiarizerManager 模型…")
        let models = try await DiarizerModels.downloadIfNeeded()
        let d = DiarizerManager(config: DiarizerConfig(clusteringThreshold: threshold))
        d.initialize(models: models)
        return try d.performCompleteDiarization(samples).segments.map {
            DiarSeg(spk: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    case .sortformer:
        log("⬇️  Sortformer 模型（cpuAndGPU）…")
        let config = SortformerConfig.default
        let models = try await SortformerModels.loadFromHuggingFace(config: config, computeUnits: .cpuAndGPU)
        let d = SortformerDiarizer(config: config)
        d.initialize(models: models)
        let result = try d.processComplete(samples)
        return result.speakers.values.flatMap { $0.finalizedSegments }.map {
            DiarSeg(spk: "\($0.speakerLabel)", start: Double($0.startTime), end: Double($0.endTime))
        }
    }
}

public func diarizeSmoke(audio: URL, backend: DiarBackend = .sortformer, threshold: Float = 0.7,
                         log: (String) -> Void = { print($0) }) async throws -> String {
    log("🗣  diarization（\(backend.rawValue)）…")
    let segs = try await runDiarization(audio: audio, backend: backend, threshold: threshold, log: log)
    var bySpeaker: [String: (count: Int, dur: Double)] = [:]
    for s in segs {
        bySpeaker[s.spk, default: (0, 0)].count += 1
        bySpeaker[s.spk, default: (0, 0)].dur += (s.end - s.start)
    }
    var out = "说话人数: \(bySpeaker.count)，段数: \(segs.count)\n"
    for (spk, v) in bySpeaker.sorted(by: { $0.value.dur > $1.value.dur }) {
        out += String(format: "  %@: %d 段, 共 %.0fs\n", spk, v.count, v.dur)
    }
    return out
}

// MARK: - 用 ground-truth 转录评测 diarization

/// 解析 "HH:MM:SS 说话人" 行 → (秒, 说话人)。文本/中文行不匹配会被跳过。
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

public func diarizeEval(audio: URL, transcript: URL, backend: DiarBackend = .sortformer,
                        threshold: Float = 0.7, log: (String) -> Void = { print($0) }) async throws -> String {
    let gt = parseGroundTruth(transcript)
    let gtSpeakers = Set(gt.map { $0.speaker }).sorted()
    log("📄 ground truth: \(gt.count) 条发言，\(gtSpeakers.count) 人: \(gtSpeakers.joined(separator: "/"))")

    log("🗣  diarization（\(backend.rawValue)）…")
    let segs = try await runDiarization(audio: audio, backend: backend, threshold: threshold, log: log)

    func diarAt(_ t: Double) -> String? {
        if let hit = segs.first(where: { $0.start <= t && t <= $0.end }) { return hit.spk }
        return segs.min(by: { abs(($0.start + $0.end) / 2 - t) < abs(($1.start + $1.end) / 2 - t) })?.spk
    }

    var pairs: [(gt: String, diar: String)] = []
    for u in gt { if let d = diarAt(u.t) { pairs.append((u.speaker, d)) } }

    var diarToGt: [String: [String: Int]] = [:]
    for p in pairs { diarToGt[p.diar, default: [:]][p.gt, default: 0] += 1 }
    let mapping = diarToGt.mapValues { $0.max(by: { $0.value < $1.value })!.key }

    let correct = pairs.filter { mapping[$0.diar] == $0.gt }.count
    let acc = pairs.isEmpty ? 0 : Double(correct) * 100 / Double(pairs.count)
    let diarCount = Set(segs.map { $0.spk }).count

    var report = """
    === diarization 评测（\(backend.rawValue)）===
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
