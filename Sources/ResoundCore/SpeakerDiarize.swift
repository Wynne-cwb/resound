import Foundation
import FluidAudio   // 真 diarization + silero VAD + AudioConverter

/// 真 diarization 优先的说话人识别（②治本 + ③ silero VAD）。
///
/// 旧 `identifySpeakers` 是「ASR 段→≥4s 窗→逐窗独立提声纹→逐窗匹配/聚类」，逐窗独立易抖、
/// 转场窗混声纹误配出幽灵人。这里改成：
///   1. 用**真 diarization**（OfflineDiarizerManager，任意人数）拿干净的「谁在何时说」轮次；
///   2. 每个 diar 说话人簇汇总它**全部**轮次的音频、用 **silero VAD 清掉静音/噪声**后提 CAM++ 声纹，
///      得到簇级质心（比逐窗稳得多）→ 去注册库匹配真名，没匹中给匿名「说话人N」；
///   3. ASR 段按所在 diar 轮次贴标签 → 平滑 → 写 diarization.json + 同步 index chunk 真名。
///
/// diarization 跑空时回退到逐窗 `identifySpeakers`（与旧行为一致）。
@discardableResult
public func identifySpeakersByDiarization(
    _ rec: RecordingSummary, model: String,
    indexPath: URL?, embeddingDim: Int,
    backend: DiarBackend = .sortformer,
    diarThreshold: Float = 0.7,
    useVAD: Bool = true,
    saturationFallback: Bool = true,
    saturationLimit: Int = 4,
    dryRun: Bool = false,
    log: (String) -> Void = { print($0) }
) async throws -> [SpeakerSeg] {
    guard let t = loadTranscript(rec.transcriptURL) else { return [] }
    // 单次解码 16k：diarization 与下游提声纹共用，避免同一文件解码两遍。
    let samples = try AudioConverter().resampleAudioFile(rec.audioURL)

    // 1) 真 diarization → 干净轮次
    let diar = try await runDiarization(samples: samples, backend: backend, threshold: diarThreshold, log: log)
    guard !diar.isEmpty else {
        log("⚠️ diarization 结果为空，回退逐窗匹配")
        return try await identifySpeakers(rec, model: model, indexPath: indexPath, embeddingDim: embeddingDim, dryRun: dryRun, log: log)
    }
    // 2) silero VAD：全曲语音区间（提声纹前清静音/噪声，声道无关地提质量）
    var voiced: [(start: Double, end: Double)] = []
    if useVAD {
        do {
            let vad = try await DiarModelCache.shared.vad()
            voiced = try await vad.segmentSpeech(samples).map { (Double($0.startTime), Double($0.endTime)) }
            log("🔇 VAD：\(voiced.count) 段语音")
        } catch {
            log("⚠️ VAD 不可用，跳过去静音：\(error.localizedDescription)")
        }
    }
    // 取 [s,e] 内、且落在 VAD 语音区间里的样本（拼接），上限 maxDur 秒；无 VAD 则原样切。
    func voicedSlice(_ s: Double, _ e: Double, maxDur: Double = 15) -> [Float] {
        guard useVAD, !voiced.isEmpty else { return slice(samples, start: s, end: min(e, s + maxDur)) }
        var out: [Float] = []
        for v in voiced where v.end > s && v.start < e {
            let a = max(s, v.start), b = min(e, v.end)
            if b - a > 0.1 { out.append(contentsOf: slice(samples, start: a, end: b)) }
            if Double(out.count) / 16000.0 >= maxDur { break }
        }
        return out.isEmpty ? slice(samples, start: s, end: min(e, s + maxDur)) : out
    }

    let embedder = try await DiarModelCache.shared.embedder(model: model)
    var bySpk: [String: [DiarSeg]] = [:]
    for d in diar { bySpk[d.spk, default: []].append(d) }
    func clusterDur(_ segs: [DiarSeg]) -> Double { segs.reduce(0) { $0 + ($1.end - $1.start) } }

    // 3) 每个原始簇 → 簇级声纹质心（先于路由判断算好，供合并 + 匹配复用）
    var centroid: [String: [Float]] = [:]
    for (spk, segs) in bySpk {
        let top = segs.sorted { ($0.end - $0.start) > ($1.end - $1.start) }.prefix(6)
        var embs: [[Float]] = []
        for s in top {
            let sl = voicedSlice(s.start, s.end)
            if sl.count >= 8000, let e = embedder.embed(sl) { embs.append(e) }   // ≥0.5s 才提
        }
        guard !embs.isEmpty else { continue }
        var c = [Float](repeating: 0, count: embs[0].count)
        for e in embs { for i in c.indices { c[i] += e[i] } }
        l2normalize(&c)
        centroid[spk] = c
    }

    // 4) 凝聚式合并：Sortformer 常把同一个人切成多个簇（实测 2 人会被过检成 4 簇）。
    //    两个簇质心 cos > mergeTau 视为「同一个人被切开」→ 并回去。
    //    ⚠️ 阈值要保守：相似嗓音（实测 Tao/Wynne 两男声压缩音频）跨人 cos 可达 0.70~0.75，
    //    同人簇 cos 0.85+，中间有缝 → 取 0.80：过检的 1-on-1 收敛回真实人数，又不把相似的两人并成一个。
    let mergeTau: Float = 0.80
    let spks = Array(bySpk.keys)
    var parent = Dictionary(uniqueKeysWithValues: spks.map { ($0, $0) })
    func find(_ x: String) -> String { var r = x; while parent[r] != r { r = parent[r]! }; var c = x; while parent[c] != c { let n = parent[c]!; parent[c] = r; c = n }; return r }
    func union(_ a: String, _ b: String) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }
    for i in 0..<spks.count {
        for j in (i+1)..<spks.count {
            guard let ci = centroid[spks[i]], let cj = centroid[spks[j]] else { continue }
            let cs = cosine(ci, cj)
            if cs > mergeTau {
                union(spks[i], spks[j])
                log(String(format: "   ↔︎ 合并簇 %@+%@（cos=%.2f > %.2f，判为同一人）", spks[i], spks[j], cs, mergeTau))
            }
        }
    }
    // rawSpk → 合并后代表簇；并重算合并簇的成员/时长/质心（按时长加权）。
    let mergedOf = Dictionary(uniqueKeysWithValues: spks.map { ($0, find($0)) })
    var mergedSegs: [String: [DiarSeg]] = [:]
    for d in diar { mergedSegs[mergedOf[d.spk] ?? d.spk, default: []].append(d) }
    var mergedCentroid: [String: [Float]] = [:]
    for (rep, members) in Dictionary(grouping: spks, by: { find($0) }) {
        var c: [Float]? = nil
        for m in members {
            guard let cm = centroid[m] else { continue }
            let w = Float(clusterDur(bySpk[m] ?? []))
            if c == nil { c = [Float](repeating: 0, count: cm.count) }
            for i in c!.indices { c![i] += cm[i] * w }
        }
        if var cc = c { l2normalize(&cc); mergedCentroid[rep] = cc }
    }
    if mergedSegs.count != bySpk.count {
        log("🔀 簇合并：\(bySpk.count) 原始簇 → \(mergedSegs.count) 实际说话人")
    }

    // 5) 路由：合并后仍 ≥saturationLimit 才判为「真·多人会」（Sortformer 4 人上限会并掉小发言者）→ 回退逐窗法。
    //    过检成 4 簇的 1-on-1 在第 4 步已收敛，不会再误触发。
    if saturationFallback, mergedSegs.count >= saturationLimit {
        log("⚠️ 合并后仍 \(mergedSegs.count) 簇（≥上限 \(saturationLimit)，真·多人会）→ 回退逐窗法")
        return try await identifySpeakers(rec, model: model, indexPath: indexPath, embeddingDim: embeddingDim, dryRun: dryRun, log: log)
    }

    // 6) 合并簇 → 匹配注册库（先各自取最佳匹配，再做互斥消歧）
    //    绝对门 0.5（逐窗用 0.35）：宁可让没注册的人落匿名「说话人N」（用户一键命名），也不要把陌生人误配成已注册者。
    let matcher = SpeakerMatcher(tauAbs: 0.5)
    if let indexPath { matcher.setRefs((try? Index(path: indexPath, dim: embeddingDim))?.loadSpeakerRefs() ?? []) }
    let order = mergedSegs.sorted(by: { clusterDur($0.value) > clusterDur($1.value) }).map { $0.key }
    var bestName: [String: String] = [:]   // 簇 → 命中的注册名（仅供互斥前的初判）
    var bestScore: [String: Float] = [:]
    for spk in order {
        guard let c = mergedCentroid[spk], !matcher.refs.isEmpty else { continue }
        let m = matcher.match(c)
        if let name = m.name { bestName[spk] = name; bestScore[spk] = m.score }
    }
    // 互斥：同一个注册者只能认领一个簇（会议里同一个人不可能是两个不同的 diar 簇）。
    //    相似嗓音会让陌生人也命中同一注册名（如 Tao cos 0.70 命中 Wynne）——只保留得分最高的那个簇，
    //    其余命中同名的降级为匿名，避免「两个不同的人都被标成 Wynne」。
    var winnerOf: [String: String] = [:]   // 注册名 → 当前最佳簇
    for spk in order {
        guard let name = bestName[spk] else { continue }
        if let cur = winnerOf[name] {
            if (bestScore[spk] ?? 0) > (bestScore[cur] ?? 0) { winnerOf[name] = spk }
        } else { winnerOf[name] = spk }
    }
    var spkName: [String: String] = [:]
    var anon = 0
    for spk in order {
        let segs = mergedSegs[spk] ?? []
        if let name = bestName[spk], winnerOf[name] == spk {
            spkName[spk] = name
            log(String(format: "   簇 %@（%.0fs）→ %@（cos=%.2f）", spk, clusterDur(segs), name, bestScore[spk] ?? 0))
        } else {
            anon += 1; spkName[spk] = "说话人\(anon)"
            if let name = bestName[spk] {
                log(String(format: "   簇 %@（%.0fs）→ 匿名（命中 %@ cos=%.2f 但已被更像的簇认领）", spk, clusterDur(segs), name, bestScore[spk] ?? 0))
            } else if let c = mergedCentroid[spk], !matcher.refs.isEmpty {
                let nearest = matcher.refs.map { ($0.name, cosine(c, $0.centroid)) }.max { $0.1 < $1.1 }
                log(String(format: "   簇 %@（%.0fs）→ 匿名（最近 %@ cos=%.2f < τ=%.2f）", spk, clusterDur(segs), nearest?.0 ?? "—", nearest?.1 ?? 0, matcher.tauAbs))
            } else {
                log(String(format: "   簇 %@（%.0fs）→ 匿名（无声纹）", spk, clusterDur(segs)))
            }
        }
    }
    let named = Set(spkName.values.filter { !$0.hasPrefix("说话人") }).sorted()
    log("🗣 diar 识别：\(mergedSegs.count) 簇 → 认出 \(named.count) 人（\(named.joined(separator: "/"))）+ \(anon) 匿名")

    // 7) ASR 段 → 所在 diar 轮次（原始簇）→ 合并簇 → 名字
    func diarAt(_ time: Double) -> String? {
        if let hit = diar.first(where: { $0.start <= time && time <= $0.end }) { return hit.spk }
        return diar.min(by: { abs(($0.start + $0.end) / 2 - time) < abs(($1.start + $1.end) / 2 - time) })?.spk
    }
    var raw: [SpeakerSeg] = []
    for seg in t.segments {
        let nm = diarAt((seg.start + seg.end) / 2).flatMap { mergedOf[$0] }.flatMap { spkName[$0] } ?? "?"
        raw.append(SpeakerSeg(start: seg.start, end: seg.end, speaker: nm))
    }
    let out = smoothSpeakerSegs(raw)
    guard !dryRun else { return out }   // 评测：只算不落盘，别覆盖用户标注
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    try enc.encode(out).write(to: rec.dir.appendingPathComponent("diarization.json"))

    // 5) index chunk 同步真名（问答引用一致）
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

/// 离线对比评测：在一条已入库录音上同时跑「旧逐窗法」与「新 diar 优先法」，
/// 打印各自的说话人分布（簇数 / 每人时长占比），不写盘。用于 ② 上线前用 ground-truth 离线验证。
public func diarIdCompare(_ rec: RecordingSummary, model: String,
                          indexPath: URL?, embeddingDim: Int,
                          backend: DiarBackend = .offline,
                          log: (String) -> Void = { print($0) }) async throws -> String {
    func breakdown(_ segs: [SpeakerSeg]) -> String {
        guard let t = loadTranscript(rec.transcriptURL) else { return "（无转录）" }
        // 按行数统计（与 UI 名册口径一致）
        func at(_ time: Double) -> String {
            segs.first(where: { $0.start <= time && time <= $0.end })?.speaker
                ?? segs.min(by: { abs(($0.start + $0.end)/2 - time) < abs(($1.start + $1.end)/2 - time) })?.speaker ?? "?"
        }
        var counts: [String: Int] = [:]
        for s in t.segments { counts[at((s.start + s.end)/2), default: 0] += 1 }
        let total = max(1, counts.values.reduce(0, +))
        return counts.sorted { $0.value > $1.value }
            .map { "    \($0.key): \($0.value) 句（\(Int(Double($0.value)*100/Double(total)))%）" }
            .joined(separator: "\n")
    }

    log("—— 旧法（ASR 窗逐窗匹配/聚类）——")
    let old = try await identifySpeakers(rec, model: model, indexPath: indexPath,
                                         embeddingDim: embeddingDim, dryRun: true, log: log)
    log("—— 新法（\(backend.rawValue) diar 优先 + VAD）——")
    let new = try await identifySpeakersByDiarization(rec, model: model, indexPath: indexPath,
                                                      embeddingDim: embeddingDim, backend: backend,
                                                      saturationFallback: false, dryRun: true, log: log)
    return """
    === 说话人识别对比：\(rec.title) ===
    旧法 → \(Set(old.map { $0.speaker }).count) 人：
    \(breakdown(old))
    新法（\(backend.rawValue)+VAD）→ \(Set(new.map { $0.speaker }).count) 人：
    \(breakdown(new))
    """
}
