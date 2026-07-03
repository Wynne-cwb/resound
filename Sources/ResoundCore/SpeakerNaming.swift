import Foundation
import FluidAudio   // AudioConverter().resampleAudioFile → 16kHz [Float]

/// 给一条录音里的某个说话人改名（匿名「说话人N」→真实人名），并可选把声纹注册进库。
///
/// 三件事：
///   1. 改写 vault 里该录音的 diarization.json（录音库展示的事实源）。
///   2. 把该说话人主导的 chunk 在 index 里打上真名（让问答引用也显示真名）。
///   3. 若 `enroll`：从该说话人的音频窗口提声纹，upsert 进 index 的 speaker_refs
///      —— 这样以后的新录音里再出现 TA，会被自动认出（「越用越准」闭环）。
/// 重新识别说话人：重聚类后，把每个堆的质心去**已注册声纹库**里匹配 ——
/// 命中已记住的人 → 直接用真名（这会把同一个人被拆成的多个重复堆自动合并）；
/// 没命中的 → 仍按大小给匿名「说话人N」。比首次冷启动更准，越标越收敛。
/// 写回 diarization.json，并把命中真名的 chunk 在 index 里也打上真名（问答引用同步）。
@discardableResult
public func reidentifySpeakers(_ rec: RecordingSummary, model: String,
                               indexPath: URL?, embeddingDim: Int,
                               clusterThreshold: Float = 0.5,
                               log: (String) -> Void = { print($0) }) async throws -> [SpeakerSeg] {
    let (clusters, windows) = try await clusterRecording(
        audio: rec.audioURL, asrJSON: rec.transcriptURL, model: model, clusterThreshold: clusterThreshold)

    let matcher = SpeakerMatcher()
    if let indexPath { matcher.setRefs((try? Index(path: indexPath, dim: embeddingDim))?.loadSpeakerRefs() ?? []) }

    // 每个堆：匹配已记住的人 → 真名（重复堆共享同名即合并）；否则匿名
    var clusterLabel: [Int: String] = [:]
    var anon = 0
    for (rank, c) in clusters.enumerated() {
        if !matcher.refs.isEmpty, let name = matcher.match(c.centroid).name {
            clusterLabel[rank] = name
        } else {
            anon += 1; clusterLabel[rank] = "说话人\(anon)"
        }
    }
    let merged = Set(clusterLabel.values.filter { !$0.hasPrefix("说话人") }).count
    log("🔁 重识别：\(clusters.count) 堆 → 命中已记住 \(merged) 人，其余 \(anon) 个匿名")

    var winToSpk: [Int: String] = [:]
    for (rank, c) in clusters.enumerated() { for wi in c.windowIdx { winToSpk[wi] = clusterLabel[rank] } }

    guard let t = loadTranscript(rec.transcriptURL) else { return [] }
    var raw: [SpeakerSeg] = []
    for seg in t.segments {
        let mid = (seg.start + seg.end) / 2
        let wi = windows.firstIndex(where: { $0.start <= mid && mid <= $0.end })
            ?? windows.indices.min(by: {
                abs((windows[$0].start + windows[$0].end) / 2 - mid) < abs((windows[$1].start + windows[$1].end) / 2 - mid)
            })
        raw.append(SpeakerSeg(start: seg.start, end: seg.end, speaker: wi.flatMap { winToSpk[$0] } ?? "?"))
    }
    let out = smoothSpeakerSegs(raw)   // 同样平滑掉转场边界幽灵说话人
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try enc.encode(out).write(to: rec.dir.appendingPathComponent("diarization.json"))

    // index chunk 同步命中的真名
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

/// 平滑说话人分段：把「从不持续发言（最长一段都 < ephemeralMax）的噪点说话人/匿名/未知」的短段
/// 并入相邻「真实说话人（曾说满 ≥ephemeralMax）」；并修同一人夹住的 <3s 掉点。反复扫到稳定。
/// 写 diarization.json 前调用，清掉转场边界的「幽灵说话人」——让逐句/名册/**摘要**/检索口径一致。
/// （`"?"` 视为未知：不可作为真实说话人、也不作为吸收目标。）
public func smoothSpeakerSegs(_ input: [SpeakerSeg], ephemeralMax: Double = 7) -> [SpeakerSeg] {
    var segs = input
    guard segs.count >= 3 else { return segs }
    func runs() -> [(lo: Int, hi: Int, spk: String, dur: Double)] {
        var out: [(Int, Int, String, Double)] = []
        var i = 0
        while i < segs.count {
            var j = i
            while j + 1 < segs.count && segs[j + 1].speaker == segs[i].speaker { j += 1 }
            out.append((i, j, segs[i].speaker, segs[j].end - segs[i].start)); i = j + 1
        }
        return out
    }
    func relabel(_ lo: Int, _ hi: Int, _ s: String) {
        for k in lo...hi { segs[k] = SpeakerSeg(start: segs[k].start, end: segs[k].end, speaker: s) }
    }
    var changed = true, pass = 0
    while changed && pass < 8 {
        changed = false; pass += 1
        let rs = runs()
        var maxRun: [String: Double] = [:]
        for r in rs { maxRun[r.spk] = max(maxRun[r.spk] ?? 0, r.dur) }
        func established(_ s: String) -> Bool { s != "?" && (maxRun[s] ?? 0) >= ephemeralMax }
        for idx in rs.indices {
            let run = rs[idx]
            let prev = idx > 0 ? rs[idx - 1].spk : nil
            let next = idx + 1 < rs.count ? rs[idx + 1].spk : nil
            if let p = prev, p == next, p != run.spk, run.dur < 3.0 {   // A：同人夹住的 <3s 掉点
                relabel(run.lo, run.hi, p); changed = true; continue
            }
            if established(run.spk) { continue }                        // B：噪点短段并入相邻真实说话人
            let pOK = prev.map(established) ?? false
            let nOK = next.map(established) ?? false
            var target: String? = nil
            if pOK && nOK { target = rs[idx - 1].dur >= rs[idx + 1].dur ? prev : next }
            else if pOK { target = prev }
            else if nOK { target = next }
            if let target, target != run.spk { relabel(run.lo, run.hi, target); changed = true }
        }
    }
    return segs
}

/// 第三档：CAM++ 段级声纹**重验/重指派**（arXiv:2406.03155 思想；见
/// superpowers/specs/2026-07-02-speaker-attribution-research.md）。
///
/// diar/逐窗归属之外的**第二票**：对每个「连续同说话人 run」用其（去静音后的）音频重提 CAM++ 声纹、
/// 与注册库比对，**仅当**该 run 足够长(≥minDur)、声纹**高置信**（score≥minScore 且 margin≥minMargin）
/// 命中一个**已注册**的人、且与当前标签不同时，才改判。段太短/声纹不置信/命中同名 → 保持不动（保守）。
/// 目的：修正 diar 边界不准治不了的「整段人认错」——尤其相似嗓音误配、真名被塞进匿名簇、多人会逐窗法误标。
/// 不依赖 diar 边界准确度。无注册库或改判 0 处则原样返回（零回归）。
///
/// - Parameter voiced: silero VAD 语音区间（有则提声纹前去静音，更干净）；空则按原区间切片。
public func reassignBySpeakerprint(
    _ segs: [SpeakerSeg],
    samples: [Float],
    embedder: SpeakerEmbedder,
    matcher: SpeakerMatcher,
    voiced: [(start: Double, end: Double)] = [],
    minDur: Double = 2.0,
    minScore: Float = 0.6,
    minMargin: Float = 0.10,
    maxDur: Double = 15,
    log: (String) -> Void = { _ in }
) -> [SpeakerSeg] {
    guard !matcher.refs.isEmpty, segs.count >= 1 else { return segs }

    // 取 [s,e] 内、且落在 VAD 语音区间里的样本（拼接，上限 maxDur）；无 VAD 则原样切。
    func voicedSlice(_ s: Double, _ e: Double) -> [Float] {
        guard !voiced.isEmpty else { return slice(samples, start: s, end: min(e, s + maxDur)) }
        var out: [Float] = []
        for v in voiced where v.end > s && v.start < e {
            let a = max(s, v.start), b = min(e, v.end)
            if b - a > 0.1 { out.append(contentsOf: slice(samples, start: a, end: b)) }
            if Double(out.count) / 16000.0 >= maxDur { break }
        }
        return out.isEmpty ? slice(samples, start: s, end: min(e, s + maxDur)) : out
    }

    // 合并连续同说话人 run（run 越长声纹越可靠）
    var runs: [(lo: Int, hi: Int, spk: String, start: Double, end: Double)] = []
    var i = 0
    while i < segs.count {
        var j = i
        while j + 1 < segs.count && segs[j + 1].speaker == segs[i].speaker { j += 1 }
        runs.append((i, j, segs[i].speaker, segs[i].start, segs[j].end)); i = j + 1
    }

    var out = segs
    var changed = 0
    for r in runs where (r.end - r.start) >= minDur {
        let sl = voicedSlice(r.start, r.end)
        guard sl.count >= 16000, let e = embedder.embed(sl) else { continue }   // ≥1s 语音才提
        let m = matcher.match(e)
        guard let name = m.name, m.score >= minScore, m.margin >= minMargin, name != r.spk else { continue }
        for k in r.lo...r.hi { out[k] = SpeakerSeg(start: out[k].start, end: out[k].end, speaker: name) }
        changed += 1
        log(String(format: "   🔎 声纹重验：%.0f–%.0fs「%@」→「%@」(cos=%.2f margin=%.2f)",
                   r.start, r.end, r.spk, name, m.score, m.margin))
    }
    if changed > 0 { log("   🔎 声纹重验改判 \(changed) 段") }
    return out
}

/// 识别一条录音的说话人——**优先用已注册声纹逐窗直接匹配**（实验证明近乎完美：
/// Wynne+GGBond 1-on-1，190 窗 → Wynne 120 / GGBond 67，仅 1 窗未过门），
/// 没匹中的窗（声纹库里没有的人）再彼此在线聚类成匿名「说话人N」。
///
/// 比纯冷启动聚类(`analyzeSpeakers`)准得多：已登记的人直接套真名、不受聚类过分裂/误并影响；
/// 声纹库为空时自动退化为纯聚类（与旧行为一致）。写 diarization.json + 同步 index chunk 真名。
@discardableResult
public func identifySpeakers(_ rec: RecordingSummary, model: String,
                            indexPath: URL?, embeddingDim: Int,
                            targetDur: Double = 4.0, clusterThreshold: Float = 0.5,
                            dryRun: Bool = false,
                            log: (String) -> Void = { print($0) }) async throws -> [SpeakerSeg] {
    guard let t = loadTranscript(rec.transcriptURL) else { return [] }
    let embedder = try SpeakerEmbedder(model: model)
    let samples = try AudioConverter().resampleAudioFile(rec.audioURL)
    let windows = mergeASRSegments(t.segments.map { (start: $0.start, end: $0.end) }, targetDur: targetDur)

    let matcher = SpeakerMatcher()
    if let indexPath { matcher.setRefs((try? Index(path: indexPath, dim: embeddingDim))?.loadSpeakerRefs() ?? []) }

    // 逐窗提声纹：匹中已注册库 → 真名；没匹中 → 留待聚类（库里没有的新人）。
    var winLabel = [String?](repeating: nil, count: windows.count)
    var unknownIdx: [Int] = []
    var unknownEmb: [(start: Double, end: Double, emb: [Float])] = []
    for (i, w) in windows.enumerated() {
        guard let e = embedder.embed(slice(samples, start: w.start, end: min(w.end, w.start + 15))) else { continue }
        if !matcher.refs.isEmpty, let name = matcher.match(e).name {
            winLabel[i] = name
        } else {
            unknownIdx.append(i); unknownEmb.append((w.start, w.end, e))
        }
    }
    let matchedNames = Set(winLabel.compactMap { $0 }).sorted()
    if !unknownEmb.isEmpty {   // 没匹中的窗彼此聚类，让库里没有的人也能分开成「说话人N」
        let clusters = onlineCluster(unknownEmb, threshold: clusterThreshold)
        for (rank, c) in clusters.enumerated() {
            for localIdx in c.windowIdx { winLabel[unknownIdx[localIdx]] = "说话人\(rank + 1)" }
        }
    }
    let anonCount = Set(winLabel.compactMap { ($0?.hasPrefix("说话人") == true) ? $0 : nil }).count
    log("🗣 识别：认出 \(matchedNames.count) 人（\(matchedNames.joined(separator: "/"))）+ \(anonCount) 个匿名")

    // ASR 段 → 所属窗 → 标签
    var raw: [SpeakerSeg] = []
    for seg in t.segments {
        let mid = (seg.start + seg.end) / 2
        let wi = windows.firstIndex(where: { $0.start <= mid && mid <= $0.end })
            ?? windows.indices.min(by: {
                abs((windows[$0].start + windows[$0].end) / 2 - mid) < abs((windows[$1].start + windows[$1].end) / 2 - mid)
            })
        raw.append(SpeakerSeg(start: seg.start, end: seg.end, speaker: wi.flatMap { winLabel[$0] } ?? "?"))
    }
    // 第三档：CAM++ 段级声纹重验（多人会/逐窗法尤其受益——粗粒度窗 + 中点归属最容易整段认错）。
    //（此路径无 VAD 区间，reassign 内部按原区间切片。）改判后再平滑一遍。
    let reassigned = reassignBySpeakerprint(smoothSpeakerSegs(raw), samples: samples,
                                            embedder: embedder, matcher: matcher, log: log)
    let out = smoothSpeakerSegs(reassigned)
    guard !dryRun else { return out }   // 评测：只算不落盘
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try enc.encode(out).write(to: rec.dir.appendingPathComponent("diarization.json"))

    // index chunk 同步命中的真名（问答引用也显示真名）
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

@discardableResult
public func renameSpeakerInRecording(rec: RecordingSummary, oldLabel: String, newName: String,
                                     enroll: Bool, speakerModel: String?,
                                     indexPath: URL?, embeddingDim: Int,
                                     vaultRoot: URL? = nil,
                                     log: (String) -> Void = { print($0) }) async throws -> String {
    let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return "空名字，跳过" }
    guard var diar = loadDiarization(rec.dir) else {
        throw ConfigError.missing("diarization.json（先识别说话人）")
    }

    // 1) diarization.json 改名
    diar = diar.map { $0.speaker == oldLabel ? SpeakerSeg(start: $0.start, end: $0.end, speaker: name) : $0 }
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try enc.encode(diar).write(to: rec.dir.appendingPathComponent("diarization.json"))

    // 2) index chunk 持久化真名（仅当该说话人在 chunk 内占主导，避免覆盖其他说话人/声纹标）
    if let indexPath {
        let idx = try Index(path: indexPath, dim: embeddingDim)
        let spans = diar.map { (start: $0.start, end: $0.end, name: $0.speaker) }
        for c in idx.chunkTimes(recordingId: rec.id) {
            if personFor(spans, start: c.start, end: c.end) == name {
                try? idx.setChunkPerson(id: c.id, person: name)
            }
        }
    }

    // 2.5) 把真名同步进 glossary.txt 偏置词表（会议里常念到人名 → 偏置让转录拼对）。
    //      在 enroll 早退之前做，保证任何命名路径（记不记声纹）都会加入；顺带回填已注册的其他人名。
    let vroot: URL? = vaultRoot ?? {
        let v = rec.dir.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()   // <vault>/recordings/YYYY/MM/<id> → 上溯 4 级
        return FileManager.default.fileExists(atPath: v.appendingPathComponent("resound.yaml").path) ? v : nil
    }()
    if let vroot {
        var names = [name]
        if let indexPath, let idx = try? Index(path: indexPath, dim: embeddingDim) {
            names.append(contentsOf: idx.loadSpeakerRefs().map { $0.name })
        }
        let added = Glossary.syncSpeakerNames(vaultRoot: vroot, names: names)
        if !added.isEmpty { log("  📝 说话人已加入词表偏置：\(added.joined(separator: "、"))") }
    }

    // 3) 声纹注册（可选）
    guard enroll, let model = speakerModel else {
        return enroll ? "已改名（未配 SPEAKER_MODEL，跳过声纹注册）" : "已改名为 \(name)"
    }
    let segs = diar.filter { $0.speaker == name }.map { (start: $0.start, end: $0.end) }
    guard !segs.isEmpty else { return "已改名为 \(name)" }
    let embedder = try SpeakerEmbedder(model: model)
    let samples = try AudioConverter().resampleAudioFile(rec.audioURL)
    let windows = mergeASRSegments(segs, targetDur: 4.0)
        .sorted { $0.dur > $1.dur }.prefix(5)   // 取最长的几个窗口做样本
    var embs: [[Float]] = []
    for w in windows {
        if let e = embedder.embed(slice(samples, start: w.start, end: min(w.end, w.start + 15))) { embs.append(e) }
    }
    guard !embs.isEmpty else { return "已改名为 \(name)（音频太短，未注册声纹）" }

    let matcher = SpeakerMatcher()
    if let indexPath {
        let idx = try Index(path: indexPath, dim: embeddingDim)
        matcher.setRefs(idx.loadSpeakerRefs())
        let existing = matcher.refs.first(where: { $0.name == name })?.count ?? 0
        if existing == 0 { matcher.setReference(name: name, embeddings: embs) }
        else { for e in embs { matcher.enroll(name: name, embedding: e) } }
        if let r = matcher.refs.first(where: { $0.name == name }) {
            try idx.upsertSpeakerRef(name: name, count: r.count, centroid: r.centroid)
        }
        log("🔊 已记住 \(name)（+\(embs.count) 样本，共 \(matcher.refs.first(where: { $0.name == name })?.count ?? embs.count)）")
    }
    return "已记住 \(name) · 以后的新录音会自动认出 TA"
}
