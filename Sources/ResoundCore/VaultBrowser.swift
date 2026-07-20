import Foundation

/// 录音库条目（供 App 列表展示）。
public struct RecordingSummary: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let recordedAt: String   // ISO8601
    public let durationSec: Int
    public let dir: URL
    public let audioFile: String
    /// 是否已识别说话人（diarization.json 是否存在）。扫描时一次性算好，
    /// 列表行直接读内存标志，避免每行每次重绘都做 `fileExists` 系统调用。
    public let identified: Bool

    public init(id: String, title: String, recordedAt: String, durationSec: Int,
                dir: URL, audioFile: String, identified: Bool) {
        self.id = id; self.title = title; self.recordedAt = recordedAt
        self.durationSec = durationSec; self.dir = dir; self.audioFile = audioFile
        self.identified = identified
    }

    public var audioURL: URL { dir.appendingPathComponent(audioFile) }
    public var transcriptURL: URL { dir.appendingPathComponent("transcript.json") }
}

/// 解析单个录音目录的 manifest → RecordingSummary（导入后增量插入用，免全量扫盘）。
public func loadRecordingSummary(dir: URL) -> RecordingSummary? {
    guard let m = try? parseManifest(dir.appendingPathComponent("recording.yaml")) else { return nil }
    let identified = FileManager.default.fileExists(atPath: dir.appendingPathComponent("diarization.json").path)
    return RecordingSummary(id: m.id, title: m.title, recordedAt: m.recordedAt,
                            durationSec: m.durationSec, dir: dir, audioFile: m.audioFile, identified: identified)
}

/// 扫描 vault，列出全部录音（按时间倒序，新在前）。
public func listRecordings(vaultRoot: URL) -> [RecordingSummary] {
    findRecordings(vaultRoot).compactMap { loadRecordingSummary(dir: $0) }
        .sorted { $0.recordedAt < $1.recordedAt }   // 升序：最早在前、最新在末（列表最新在最下）
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

/// 归档录音：把目录移到 `<vault>/archive/recordings/<id>/`（在 recordings/ 之外，故不被 `findRecordings` 扫描，
/// 从列表消失但音频/转录完整保留、可手动恢复）。合并功能用它处置被合并的原录音。索引清理另调 Index.deleteRecording。
public func archiveRecording(_ rec: RecordingSummary, vaultRoot: URL) throws {
    let root = vaultRoot.appendingPathComponent("archive/recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var dst = root.appendingPathComponent(rec.id, isDirectory: true)
    if FileManager.default.fileExists(atPath: dst.path) {   // 同名已归档过 → 加后缀避免覆盖
        dst = root.appendingPathComponent("\(rec.id)-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
    }
    try FileManager.default.moveItem(at: rec.dir, to: dst)
}

/// 改写 recording.yaml 的 recorded_at 行（redate 用；事实源在 vault）。
public func setRecordingDate(_ rec: RecordingSummary, toISO iso: String) throws {
    let yamlURL = rec.dir.appendingPathComponent("recording.yaml")
    let text = try String(contentsOf: yamlURL, encoding: .utf8)
    let lines = text.components(separatedBy: "\n").map { line -> String in
        line.hasPrefix("recorded_at:") ? "recorded_at: \(iso)" : line
    }
    try lines.joined(separator: "\n").write(to: yamlURL, atomically: true, encoding: .utf8)
}

public struct RedateChange { public let id: String; public let title: String; public let old: String; public let new: String }

/// 一次性修正：对 vault 内每条录音，从标题解析会议日期，与当前 recorded_at 的「日」不同则修正
/// recording.yaml + 索引（recorded_at + chunk recording_date）。dryRun 只返回将改动项、不落盘。
public func redateFromTitles(vaultRoot: URL, indexPath: URL, embeddingDim: Int,
                             dryRun: Bool, now: Date = Date()) -> [RedateChange] {
    var out: [RedateChange] = []
    let idx = dryRun ? nil : try? Index(path: indexPath, dim: embeddingDim)
    for rec in listRecordings(vaultRoot: vaultRoot) {
        guard let d = parseTitleDate(rec.title, now: now) else { continue }
        let newDay = localDate(d)
        guard String(rec.recordedAt.prefix(10)) != newDay else { continue }   // 已一致
        let newISO = iso8601(d)
        out.append(RedateChange(id: rec.id, title: rec.title, old: rec.recordedAt, new: newISO))
        if !dryRun {
            try? setRecordingDate(rec, toISO: newISO)
            try? idx?.setRecordingDate(id: rec.id, recordedAt: newISO, day: newDay)
        }
    }
    return out
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
