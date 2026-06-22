import Foundation

/// 录音库条目（供 App 列表展示）。
public struct RecordingSummary: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let recordedAt: String   // ISO8601
    public let durationSec: Int
    public let dir: URL
    public let audioFile: String

    public var audioURL: URL { dir.appendingPathComponent(audioFile) }
    public var transcriptURL: URL { dir.appendingPathComponent("transcript.json") }
}

/// 扫描 vault，列出全部录音（按时间倒序，新在前）。
public func listRecordings(vaultRoot: URL) -> [RecordingSummary] {
    findRecordings(vaultRoot).compactMap { dir -> RecordingSummary? in
        guard let m = try? parseManifest(dir.appendingPathComponent("recording.yaml")) else { return nil }
        return RecordingSummary(id: m.id, title: m.title, recordedAt: m.recordedAt,
                                durationSec: m.durationSec, dir: dir, audioFile: m.audioFile)
    }
    .sorted { $0.recordedAt > $1.recordedAt }
}

/// 读某录音的 transcript.json（段：start/end/text）。
public func loadTranscript(_ url: URL) -> Transcript? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(Transcript.self, from: data)
}

/// 重命名录音（改写 recording.yaml 的 title 行）。
public func renameRecording(_ rec: RecordingSummary, to newTitle: String) throws {
    let yamlURL = rec.dir.appendingPathComponent("recording.yaml")
    let text = try String(contentsOf: yamlURL, encoding: .utf8)
    let lines = text.components(separatedBy: "\n").map { line -> String in
        line.hasPrefix("title:") ? "title: \(yamlQuote(newTitle))" : line
    }
    try lines.joined(separator: "\n").write(to: yamlURL, atomically: true, encoding: .utf8)
}

/// 删除录音目录（连同音频/转录）。索引清理另调 Index.deleteRecording。
public func deleteRecording(_ rec: RecordingSummary) throws {
    try FileManager.default.removeItem(at: rec.dir)
}

// MARK: - 说话人分段（diarization.json，事实源在 vault）

public struct SpeakerSeg: Codable {
    public let start: Double
    public let end: Double
    public let speaker: String
    public init(start: Double, end: Double, speaker: String) {
        self.start = start; self.end = end; self.speaker = speaker
    }
}

public func loadDiarization(_ dir: URL) -> [SpeakerSeg]? {
    let u = dir.appendingPathComponent("diarization.json")
    guard let d = try? Data(contentsOf: u) else { return nil }
    return try? JSONDecoder().decode([SpeakerSeg].self, from: d)
}

/// 对录音做说话人分析（冷启动在线分堆 → 匿名「说话人N」），按转录段落标注并缓存 diarization.json。
public func analyzeSpeakers(_ rec: RecordingSummary, model: String) async throws -> [SpeakerSeg] {
    let (clusters, windows) = try await clusterRecording(audio: rec.audioURL, asrJSON: rec.transcriptURL, model: model)
    var winToSpk: [Int: String] = [:]
    for (rank, c) in clusters.enumerated() { for wi in c.windowIdx { winToSpk[wi] = "说话人\(rank + 1)" } }
    guard let t = loadTranscript(rec.transcriptURL) else { return [] }
    var out: [SpeakerSeg] = []
    for seg in t.segments {
        let mid = (seg.start + seg.end) / 2
        let wi = windows.firstIndex(where: { $0.start <= mid && mid <= $0.end })
            ?? windows.indices.min(by: {
                abs((windows[$0].start + windows[$0].end) / 2 - mid) <
                abs((windows[$1].start + windows[$1].end) / 2 - mid)
            })
        out.append(SpeakerSeg(start: seg.start, end: seg.end, speaker: wi.flatMap { winToSpk[$0] } ?? "?"))
    }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try enc.encode(out).write(to: rec.dir.appendingPathComponent("diarization.json"))
    return out
}
