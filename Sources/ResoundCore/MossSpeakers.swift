import Foundation
import FluidAudio   // AudioConverter + silero VAD（经 DiarModelCache）

/// MOSS 录音的说话人命名：MOSS 已产出干净的「谁在何时说」（moss-diar.json，S01/S02 匿名标签），
/// 这里只做「这些标签分别是谁」——与 identifySpeakersByDiarization 的第 3~6 步同款：
/// 每标签取最长发言段 → silero VAD 清静音 → CAM++ 簇级质心 → 相似簇凝聚合并（MOSS 也可能把
/// 同一人拆成两个标签，实测 RMA 会 S03/S04 同为一人）→ 注册库双门匹配 + 互斥消歧 → 真名/说话人N，
/// 写正式 diarization.json + 同步 index chunk。moss-diar.json 保留（重新识别可重跑）。
///
/// 不做 diarization（MOSS 已做）、不做段归属投票（段与标签天生一一对应）、不做平滑
/// （MOSS 轮次本身干净，平滑反而会吞掉合法的短附和——正是它比拼接式强的地方）。
public func mossDiarStagingURL(_ dir: URL) -> URL { dir.appendingPathComponent("moss-diar.json") }

public func hasMossDiarStaging(_ dir: URL) -> Bool {
    FileManager.default.fileExists(atPath: mossDiarStagingURL(dir).path)
}

@discardableResult
public func nameSpeakersFromMossDiarization(
    _ rec: RecordingSummary, model: String,
    indexPath: URL?, embeddingDim: Int,
    log: (String) -> Void = { print($0) }
) async throws -> [SpeakerSeg] {
    let stagingURL = mossDiarStagingURL(rec.dir)
    guard let data = try? Data(contentsOf: stagingURL),
          let staging = try? JSONDecoder().decode([SpeakerSeg].self, from: data), !staging.isEmpty else {
        throw MossError.badResponse("moss-diar.json 缺失或为空（\(rec.id)）")
    }

    let samples = try AudioConverter().resampleAudioFile(rec.audioURL)

    // silero VAD：提声纹前清静音（与 diar 路径同款，best-effort）
    var voiced: [(start: Double, end: Double)] = []
    do {
        let vad = try await DiarModelCache.shared.vad()
        voiced = try await vad.segmentSpeech(samples).map { (Double($0.startTime), Double($0.endTime)) }
    } catch {
        log("⚠️ VAD 不可用，跳过去静音：\(error.localizedDescription)")
    }
    func voicedSlice(_ s: Double, _ e: Double, maxDur: Double = 15) -> [Float] {
        guard !voiced.isEmpty else { return slice(samples, start: s, end: min(e, s + maxDur)) }
        var out: [Float] = []
        for v in voiced where v.end > s && v.start < e {
            let a = max(s, v.start), b = min(e, v.end)
            if b - a > 0.1 { out.append(contentsOf: slice(samples, start: a, end: b)) }
            if Double(out.count) / 16000.0 >= maxDur { break }
        }
        return out.isEmpty ? slice(samples, start: s, end: min(e, s + maxDur)) : out
    }

    // 每个 MOSS 标签 → 簇级质心（取最长的 6 段；≥0.5s 才提，短「嗯/对」附和不进声纹）
    let embedder = try await DiarModelCache.shared.embedder(model: model)
    var byLabel: [String: [SpeakerSeg]] = [:]
    for s in staging { byLabel[s.speaker, default: []].append(s) }
    func labelDur(_ segs: [SpeakerSeg]) -> Double { segs.reduce(0) { $0 + ($1.end - $1.start) } }
    var centroid: [String: [Float]] = [:]
    for (label, segs) in byLabel {
        let top = segs.sorted { ($0.end - $0.start) > ($1.end - $1.start) }.prefix(6)
        var embs: [[Float]] = []
        for s in top {
            let sl = voicedSlice(s.start, s.end)
            if sl.count >= 8000, let e = embedder.embed(sl) { embs.append(e) }
        }
        guard !embs.isEmpty else { continue }
        var c = [Float](repeating: 0, count: embs[0].count)
        for e in embs { for i in c.indices { c[i] += e[i] } }
        l2normalize(&c)
        centroid[label] = c
    }

    // 凝聚合并（同人被拆成两个标签，cos > 0.80 并回；阈值依据见 SpeakerDiarize 同款注释）
    let mergeTau: Float = 0.80
    let labels = Array(byLabel.keys)
    var parent = Dictionary(uniqueKeysWithValues: labels.map { ($0, $0) })
    func find(_ x: String) -> String {
        var r = x; while parent[r] != r { r = parent[r]! }
        var c = x; while parent[c] != c { let n = parent[c]!; parent[c] = r; c = n }
        return r
    }
    for i in 0..<labels.count {
        for j in (i + 1)..<labels.count {
            guard let ci = centroid[labels[i]], let cj = centroid[labels[j]] else { continue }
            let cs = cosine(ci, cj)
            if cs > mergeTau, find(labels[i]) != find(labels[j]) {
                parent[find(labels[i])] = find(labels[j])
                log(String(format: "   ↔︎ 合并 %@+%@（cos=%.2f，判为同一人）", labels[i], labels[j], cs))
            }
        }
    }
    let mergedOf = Dictionary(uniqueKeysWithValues: labels.map { ($0, find($0)) })
    var mergedSegs: [String: [SpeakerSeg]] = [:]
    for s in staging { mergedSegs[mergedOf[s.speaker] ?? s.speaker, default: []].append(s) }
    var mergedCentroid: [String: [Float]] = [:]
    for (rep, members) in Dictionary(grouping: labels, by: { find($0) }) {
        var c: [Float]? = nil
        for m in members {
            guard let cm = centroid[m] else { continue }
            let w = Float(labelDur(byLabel[m] ?? []))
            if c == nil { c = [Float](repeating: 0, count: cm.count) }
            for i in c!.indices { c![i] += cm[i] * w }
        }
        if var cc = c { l2normalize(&cc); mergedCentroid[rep] = cc }
    }

    // 注册库双门匹配 + 互斥消歧（一个注册者只认领一个标签簇；同款阈值 0.5，宁匿名不误配）
    let matcher = SpeakerMatcher(tauAbs: 0.5)
    if let indexPath { matcher.setRefs((try? Index(path: indexPath, dim: embeddingDim))?.loadSpeakerRefs() ?? []) }
    let order = mergedSegs.sorted { labelDur($0.value) > labelDur($1.value) }.map { $0.key }
    var bestName: [String: String] = [:], bestScore: [String: Float] = [:]
    for rep in order {
        guard let c = mergedCentroid[rep], !matcher.refs.isEmpty else { continue }
        let m = matcher.match(c)
        if let name = m.name { bestName[rep] = name; bestScore[rep] = m.score }
    }
    var winnerOf: [String: String] = [:]
    for rep in order {
        guard let name = bestName[rep] else { continue }
        if let cur = winnerOf[name] {
            if (bestScore[rep] ?? 0) > (bestScore[cur] ?? 0) { winnerOf[name] = rep }
        } else { winnerOf[name] = rep }
    }
    var repName: [String: String] = [:]
    var anon = 0
    for rep in order {
        if let name = bestName[rep], winnerOf[name] == rep {
            repName[rep] = name
            log(String(format: "   %@（%.0fs）→ %@（cos=%.2f）", rep, labelDur(mergedSegs[rep] ?? []), name, bestScore[rep] ?? 0))
        } else {
            anon += 1; repName[rep] = "说话人\(anon)"
            log(String(format: "   %@（%.0fs）→ 说话人%d", rep, labelDur(mergedSegs[rep] ?? []), anon))
        }
    }
    let named = Set(repName.values.filter { !$0.hasPrefix("说话人") }).sorted()
    log("🗣 MOSS 说话人命名：\(byLabel.count) 标签 → \(mergedSegs.count) 人，认出 \(named.count)（\(named.joined(separator: "/"))）+ \(anon) 匿名")

    // 落盘：标签替换成最终名字（段时间原样，MOSS 的轮次不动）
    let out = staging.map {
        SpeakerSeg(start: $0.start, end: $0.end,
                   speaker: repName[mergedOf[$0.speaker] ?? $0.speaker] ?? "?")
    }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try enc.encode(out).write(to: rec.dir.appendingPathComponent("diarization.json"))

    // index chunk 同步真名（问答引用一致，与 diar 路径同款）
    if let indexPath {
        let idx = try Index(path: indexPath, dim: embeddingDim)
        let spans = out.map { (start: $0.start, end: $0.end, name: $0.speaker) }
        for c in idx.chunkTimes(recordingId: rec.id) {
            if let n = personFor(spans, start: c.start, end: c.end), !n.hasPrefix("说话人"), n != "?" {
                try? idx.setChunkPerson(id: c.id, person: n)
            }
        }
    }
    return out
}
