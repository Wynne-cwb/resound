import Foundation
import FluidAudio   // 复用 AudioConverter().resampleAudioFile → 16kHz 单声道 [Float]

// MARK: - 窗口合并（ASR 碎片 → ≥targetDur 的声纹窗口）

public struct SpeakerWindow {
    public let start: Double
    public let end: Double
    public var dur: Double { end - start }
}

/// 把相邻 ASR 段贪婪合并成至少 targetDur 秒的窗口（gap<maxGap 才合并）。
/// 实测：原始 ASR 碎片(~2.4s)注册匹配仅 53%，合并到 ≥4s 回升到 85%。
public func mergeASRSegments(_ segs: [(start: Double, end: Double)],
                             targetDur: Double = 4.0, maxGap: Double = 1.0) -> [SpeakerWindow] {
    var out: [SpeakerWindow] = []
    var cur: (s: Double, e: Double)? = nil
    for seg in segs.sorted(by: { $0.start < $1.start }) {
        if cur == nil {
            cur = (seg.start, seg.end)
        } else if seg.start - cur!.e < maxGap && (cur!.e - cur!.s) < targetDur {
            cur!.e = seg.end
        } else {
            out.append(SpeakerWindow(start: cur!.s, end: cur!.e)); cur = (seg.start, seg.end)
        }
    }
    if let c = cur { out.append(SpeakerWindow(start: c.s, end: c.e)) }
    return out
}

// MARK: - 参考声纹 + 匹配（双门拒识）

public struct SpeakerRef: Codable {
    public var name: String
    public var centroid: [Float]   // 已 L2 归一
    public var count: Int
}

public struct MatchResult {
    public let name: String?       // nil = unknown（未过门）
    public let score: Float        // 最近邻 cosine
    public let margin: Float       // s1 - s2
}

/// 注册式说话人匹配器。参数默认值来自业界最佳实践调研（见 docs/DECISIONS.md 工程参数速查）。
public final class SpeakerMatcher {
    public private(set) var refs: [SpeakerRef] = []
    public var tauAbs: Float       // 绝对拒识门：最近邻 cosine 低于此 → unknown
    public var tauMargin: Float    // 相对门：s1-s2 低于此 → 模糊/unknown
    public var mergeGuard: Float   // 增量更新守门：新样本与旧质心 cosine 低于此则拒绝并入

    public init(tauAbs: Float = 0.35, tauMargin: Float = 0.0, mergeGuard: Float = 0.45) {
        self.tauAbs = tauAbs
        self.tauMargin = tauMargin
        self.mergeGuard = mergeGuard
    }

    /// 直接注入参考声纹（如从 index 声纹库加载）。
    public func setRefs(_ r: [SpeakerRef]) { refs = r }

    /// 从 JSON 声纹库加载已注册的人。
    public func loadStore(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let store = try JSONDecoder().decode(SpeakerStore.self, from: Data(contentsOf: url))
        refs = store.refs
    }

    /// 把当前参考声纹存回 JSON 声纹库。
    public func saveStore(_ url: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try enc.encode(SpeakerStore(refs: refs)).write(to: url)
    }

    /// 用一批 embedding 直接建/重置某人的参考声纹（L2 归一后求均值）。
    public func setReference(name: String, embeddings: [[Float]]) {
        guard !embeddings.isEmpty else { return }
        var c = [Float](repeating: 0, count: embeddings[0].count)
        for e in embeddings { for i in c.indices { c[i] += e[i] } }
        l2normalize(&c)
        if let idx = refs.firstIndex(where: { $0.name == name }) {
            refs[idx] = SpeakerRef(name: name, centroid: c, count: embeddings.count)
        } else {
            refs.append(SpeakerRef(name: name, centroid: c, count: embeddings.count))
        }
    }

    /// 增量注册：在线均值更新 μ_new=(n·μ_old+e)/(n+1)，带污染守门。
    /// 返回是否被接受（守门拒绝坏样本，避免污染质心）。
    @discardableResult
    public func enroll(name: String, embedding e: [Float]) -> Bool {
        if let idx = refs.firstIndex(where: { $0.name == name }) {
            let sim = cosine(e, refs[idx].centroid)
            if sim < mergeGuard { return false }   // 坏样本/可能是别人，拒绝并入
            let n = Float(refs[idx].count)
            var c = refs[idx].centroid
            for i in c.indices { c[i] = (n * c[i] + e[i]) / (n + 1) }
            l2normalize(&c)
            refs[idx].centroid = c
            refs[idx].count += 1
        } else {
            var c = e; l2normalize(&c)
            refs.append(SpeakerRef(name: name, centroid: c, count: 1))
        }
        return true
    }

    /// 最近邻匹配 + 双门拒识。返回 name=nil 表示判为 unknown。
    public func match(_ e: [Float]) -> MatchResult {
        guard !refs.isEmpty else { return MatchResult(name: nil, score: 0, margin: 0) }
        var scored = refs.map { (name: $0.name, s: cosine(e, $0.centroid)) }
        scored.sort { $0.s > $1.s }
        let s1 = scored[0].s
        let s2 = scored.count > 1 ? scored[1].s : -1
        let margin = s1 - max(s2, 0)
        if s1 < tauAbs { return MatchResult(name: nil, score: s1, margin: margin) }
        if scored.count > 1 && margin < tauMargin { return MatchResult(name: nil, score: s1, margin: margin) }
        return MatchResult(name: scored[0].name, score: s1, margin: margin)
    }
}

// MARK: - 音频切片

/// 取 [start,end) 秒的样本切片（16kHz）。
func slice(_ samples: [Float], start: Double, end: Double, sampleRate: Int = 16000) -> [Float] {
    let a = max(0, Int(start * Double(sampleRate)))
    let b = min(samples.count, Int(end * Double(sampleRate)))
    guard a < b else { return [] }
    return Array(samples[a..<b])
}

// MARK: - 冷启动自动分堆（在线 leader-follower 聚类）

public struct SpeakerCluster {
    public var centroid: [Float]      // L2 归一
    public var count: Int
    public var totalDur: Double
    public var windowIdx: [Int]       // 属于本堆的窗口下标（在输入数组中的序号）
    public var sampleStart: Double    // 一个代表样例的起点（最长窗口），供用户试听
    public var sampleEnd: Double
}

/// 在线增量聚类：按时间顺序逐窗，和已有堆比 cosine，≥threshold 归入并更新质心，否则开新堆。
/// 用强两两比对（非失败的全局聚类）。高纯度但会过分裂——靠"命名大堆+小堆归并"收尾。
public func onlineCluster(_ windows: [(start: Double, end: Double, emb: [Float])],
                          threshold: Float = 0.5) -> [SpeakerCluster] {
    var cs: [SpeakerCluster] = []
    for (i, w) in windows.enumerated() {
        let dur = w.end - w.start
        if cs.isEmpty {
            cs.append(SpeakerCluster(centroid: w.emb, count: 1, totalDur: dur,
                                     windowIdx: [i], sampleStart: w.start, sampleEnd: w.end))
            continue
        }
        var best = -1; var bestSim: Float = -1
        for (j, c) in cs.enumerated() {
            let s = cosine(w.emb, c.centroid)
            if s > bestSim { bestSim = s; best = j }
        }
        if bestSim >= threshold {
            let n = Float(cs[best].count)
            var c = cs[best].centroid
            for k in c.indices { c[k] = (n * c[k] + w.emb[k]) / (n + 1) }
            l2normalize(&c)
            cs[best].centroid = c
            cs[best].count += 1
            cs[best].totalDur += dur
            cs[best].windowIdx.append(i)
            if dur > (cs[best].sampleEnd - cs[best].sampleStart) {   // 记最长窗口当样例
                cs[best].sampleStart = w.start; cs[best].sampleEnd = w.end
            }
        } else {
            cs.append(SpeakerCluster(centroid: w.emb, count: 1, totalDur: dur,
                                     windowIdx: [i], sampleStart: w.start, sampleEnd: w.end))
        }
    }
    return cs.sorted { $0.totalDur > $1.totalDur }   // 大堆在前，供用户优先命名
}

/// 对一段录音自动分堆：ASR 段→合并≥targetDur 窗→提声纹→在线聚类。返回(按时长排序的堆, 每窗的[起,止])。
public func clusterRecording(audio: URL, asrJSON: URL, model: String,
                             targetDur: Double = 4.0, clusterThreshold: Float = 0.5)
    async throws -> (clusters: [SpeakerCluster], windows: [(start: Double, end: Double)]) {
    let embedder = try SpeakerEmbedder(model: model)
    let samples = try AudioConverter().resampleAudioFile(audio)
    let tr = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: asrJSON))
    let merged = mergeASRSegments(tr.segments.map { (start: $0.start, end: $0.end) }, targetDur: targetDur)
    var embedded: [(start: Double, end: Double, emb: [Float])] = []
    var wins: [(start: Double, end: Double)] = []
    for w in merged {
        guard let e = embedder.embed(slice(samples, start: w.start, end: min(w.end, w.start + 15))) else { continue }
        embedded.append((w.start, w.end, e))
        wins.append((w.start, w.end))
    }
    return (onlineCluster(embedded, threshold: clusterThreshold), wins)
}

// MARK: - 持久化声纹库（JSON，个人规模够用；派生物可由标注音频重算）

public struct SpeakerStore: Codable {
    public var refs: [SpeakerRef]
    public init(refs: [SpeakerRef]) { self.refs = refs }
}

/// 每条 (时间, 说话人) 标注 → [t, next_t] 的轮次窗口（capped），用于注册（长窗信号足）。
func turnWindows(_ labeled: [(t: Double, speaker: String)], totalDur: Double, maxWin: Double = 15) -> [(start: Double, end: Double, speaker: String)] {
    let sorted = labeled.sorted { $0.t < $1.t }
    var out: [(Double, Double, String)] = []
    for (i, u) in sorted.enumerated() {
        var end = i + 1 < sorted.count ? sorted[i + 1].t : totalDur
        end = min(end, u.t + maxWin)
        if end - u.t < 0.5 { end = min(u.t + 1.0, totalDur) }
        out.append((u.t, end, u.speaker))
    }
    return out
}

/// 从一段音频 + 标注转录注册声纹（每人挑最长 per 条轮次窗口），增量并入 store。
/// 这是「标几次变准」的引擎：跨录音重复调用会累积、用在线均值让质心变准。
public func enrollFromLabeled(audio: URL, labels: URL, store storeURL: URL,
                              model: String, per: Int = 5, maxWin: Double = 15,
                              log: (String) -> Void = { print($0) }) async throws -> String {
    let embedder = try SpeakerEmbedder(model: model)
    let samples = try AudioConverter().resampleAudioFile(audio)
    let total = Double(samples.count) / 16000.0
    var labeled = parseGroundTruth(labels).map { (t: $0.t, speaker: speakerFix[$0.speaker] ?? $0.speaker) }
    labeled.sort { $0.t < $1.t }
    let wins = turnWindows(labeled, totalDur: total, maxWin: maxWin)

    let matcher = SpeakerMatcher()
    try matcher.loadStore(storeURL)

    var byName: [String: [(dur: Double, emb: [Float])]] = [:]
    for w in wins {
        let e = embedder.embed(slice(samples, start: w.start, end: w.end))
        if let e { byName[w.speaker, default: []].append((w.end - w.start, e)) }
    }
    var report = "注册声纹库 \(storeURL.lastPathComponent)（model dim=\(embedder.dim)）\n"
    for (name, lst) in byName.sorted(by: { $0.key < $1.key }) {
        let top = lst.sorted { $0.dur > $1.dur }.prefix(per).map { $0.emb }
        let before = matcher.refs.first(where: { $0.name == name })?.count ?? 0
        if before == 0 {
            matcher.setReference(name: name, embeddings: Array(top))
        } else {
            for e in top { matcher.enroll(name: name, embedding: e) }  // 增量+守门
        }
        let after = matcher.refs.first(where: { $0.name == name })?.count ?? 0
        report += "  \(name): +\(top.count) 条样本（\(before)→\(after)）\n"
    }
    try matcher.saveStore(storeURL)
    report += "已存 \(matcher.refs.count) 人。"
    return report
}

/// 用声纹库给一段录音的 ASR 段打说话人标签（跨录音识别）。返回每窗 (起止, 人/unknown, 分数)。
public func recognizeWithStore(audio: URL, asrJSON: URL, store storeURL: URL,
                               model: String, targetDur: Double = 4.0,
                               tauAbs: Float = 0.35, tauMargin: Float = 0.0,
                               log: (String) -> Void = { print($0) }) async throws -> String {
    let embedder = try SpeakerEmbedder(model: model)
    let matcher = SpeakerMatcher(tauAbs: tauAbs, tauMargin: tauMargin)
    try matcher.loadStore(storeURL)
    guard !matcher.refs.isEmpty else { return "声纹库为空，先 enroll。" }
    let samples = try AudioConverter().resampleAudioFile(audio)
    let tr = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: asrJSON))
    let windows = mergeASRSegments(tr.segments.map { (start: $0.start, end: $0.end) }, targetDur: targetDur)

    var tally: [String: (n: Int, dur: Double)] = [:]
    for w in windows {
        guard let e = embedder.embed(slice(samples, start: w.start, end: min(w.end, w.start + 15))) else { continue }
        let name = matcher.match(e).name ?? "unknown"
        tally[name, default: (0, 0)].n += 1
        tally[name, default: (0, 0)].dur += w.dur
    }
    var report = "识别 \(windows.count) 窗（声纹库 \(matcher.refs.count) 人，τ_abs=\(tauAbs)）：\n"
    for (name, v) in tally.sorted(by: { $0.value.dur > $1.value.dur }) {
        report += String(format: "  %@: %d 窗, 共 %.0fs\n", name, v.n, v.dur)
    }
    return report
}

// MARK: - 冷启动闭环评测（自动分堆→命名最大K堆→其余归并→算准确率）

public func coldStartEval(audio: URL, asrJSON: URL, groundTruth: URL, model: String,
                          targetDur: Double = 4.0, clusterTh: Float = 0.5, absorbTh: Float = 0.45,
                          log: (String) -> Void = { print($0) }) async throws -> String {
    var gt = parseGroundTruth(groundTruth).map { (t: $0.t, speaker: speakerFix[$0.speaker] ?? $0.speaker) }
    gt.sort { $0.t < $1.t }
    func gtAt(_ t: Double) -> String {
        var lo = 0, hi = gt.count - 1, ans = 0
        while lo <= hi { let m = (lo + hi) / 2; if gt[m].t <= t { ans = m; lo = m + 1 } else { hi = m - 1 } }
        return gt.isEmpty ? "?" : gt[ans].speaker
    }
    let (clusters, windows) = try await clusterRecording(audio: audio, asrJSON: asrJSON, model: model,
                                                          targetDur: targetDur, clusterThreshold: clusterTh)
    // 每窗真值
    let truth = windows.map { gtAt(($0.start + $0.end) / 2) }
    let realPeople = Set(truth).count
    // 每堆 GT 多数票（模拟用户命名）+ 每窗属于哪个堆
    var winCluster = [Int](repeating: -1, count: windows.count)
    var clusterName: [Int: String] = [:]
    for (ci, c) in clusters.enumerated() {
        var votes: [String: Int] = [:]
        for wi in c.windowIdx { winCluster[wi] = ci; votes[truth[wi], default: 0] += 1 }
        clusterName[ci] = votes.max(by: { $0.value < $1.value })!.key
    }

    var report = """
    === 冷启动闭环评测（自动分堆→命名→归并）===
    \(windows.count) 窗，真 \(realPeople) 人 → 自动分 \(clusters.count) 堆 (cluster-th=\(clusterTh), absorb-th=\(absorbTh))
    命名K  覆盖率  准确率(全部)  准确率(已识)  认出人数
    """
    let maxK = min(clusters.count, 12)
    for K in 1...maxK {
        // 命名前 K 大堆 → 参考声纹（同名堆质心平均）
        var refsByName: [String: [[Float]]] = [:]
        for ci in 0..<K { refsByName[clusterName[ci]!, default: []].append(clusters[ci].centroid) }
        let names = Array(refsByName.keys)
        let R: [[Float]] = names.map { n in
            var c = [Float](repeating: 0, count: clusters[0].centroid.count)
            for e in refsByName[n]! { for i in c.indices { c[i] += e[i] } }
            l2normalize(&c); return c
        }
        // 每堆最终预测
        var clusterPred = [String](repeating: "unknown", count: clusters.count)
        for ci in 0..<clusters.count {
            if ci < K { clusterPred[ci] = clusterName[ci]! ; continue }
            var best = -1; var bestSim: Float = -1
            for (j, r) in R.enumerated() { let s = cosine(clusters[ci].centroid, r); if s > bestSim { bestSim = s; best = j } }
            clusterPred[ci] = bestSim >= absorbTh ? names[best] : "unknown"
        }
        var known = 0, correct = 0, correctKnown = 0
        for wi in windows.indices {
            let pred = clusterPred[winCluster[wi]]
            if pred != "unknown" { known += 1; if pred == truth[wi] { correctKnown += 1 } }
            if pred == truth[wi] { correct += 1 }
        }
        let tot = windows.count
        report += String(format: "\n%4d  %5.0f%%  %9.1f%%  %9.1f%%  %6d",
                         K, Double(known)*100/Double(tot), Double(correct)*100/Double(tot),
                         known > 0 ? Double(correctKnown)*100/Double(known) : 0, names.count)
    }
    return report
}

// MARK: - 给录音逐段打说话人标签（供 index 填 chunk.person_id）

/// 逐窗识别 → 带说话人的时间段（name 可能 "unknown"）。
public func recognizeSpans(samples: [Float], segments: [(start: Double, end: Double)],
                           matcher: SpeakerMatcher, embedder: SpeakerEmbedder,
                           targetDur: Double = 4.0) -> [(start: Double, end: Double, name: String)] {
    let windows = mergeASRSegments(segments, targetDur: targetDur)
    var spans: [(start: Double, end: Double, name: String)] = []
    for w in windows {
        guard let e = embedder.embed(slice(samples, start: w.start, end: min(w.end, w.start + 15))) else { continue }
        spans.append((w.start, w.end, matcher.match(e).name ?? "unknown"))
    }
    return spans
}

/// 从音频文件直接识别(内部重采样)，给 IndexPipeline 用(免它 import FluidAudio)。
public func recognizeSpansFromFile(audio: URL, segments: [(start: Double, end: Double)],
                                   matcher: SpeakerMatcher, embedder: SpeakerEmbedder,
                                   targetDur: Double = 4.0) throws -> [(start: Double, end: Double, name: String)] {
    let samples = try AudioConverter().resampleAudioFile(audio)
    return recognizeSpans(samples: samples, segments: segments, matcher: matcher, embedder: embedder, targetDur: targetDur)
}

/// 区间 [start,end] 内按重叠时长占多数的说话人；unknown/无重叠返回 nil。
public func personFor(_ spans: [(start: Double, end: Double, name: String)], start: Double, end: Double) -> String? {
    var dur: [String: Double] = [:]
    for sp in spans {
        let ov = min(end, sp.end) - max(start, sp.start)
        if ov > 0 { dur[sp.name, default: 0] += ov }
    }
    guard let best = dur.max(by: { $0.value < $1.value })?.key, best != "unknown" else { return nil }
    return best
}

/// 从标注音频注册声纹 → 直接写入 index 的 speaker_refs（向量存 index；增量+守门）。
public func enrollToIndex(audio: URL, labels: URL, indexPath: URL, embeddingDim: Int,
                          model: String, per: Int = 5, maxWin: Double = 15,
                          log: (String) -> Void = { print($0) }) async throws -> String {
    let embedder = try SpeakerEmbedder(model: model)
    let samples = try AudioConverter().resampleAudioFile(audio)
    let total = Double(samples.count) / 16000.0
    var labeled = parseGroundTruth(labels).map { (t: $0.t, speaker: speakerFix[$0.speaker] ?? $0.speaker) }
    labeled.sort { $0.t < $1.t }
    let wins = turnWindows(labeled, totalDur: total, maxWin: maxWin)

    let index = try Index(path: indexPath, dim: embeddingDim)
    let matcher = SpeakerMatcher(); matcher.setRefs(index.loadSpeakerRefs())

    var byName: [String: [(dur: Double, emb: [Float])]] = [:]
    for w in wins {
        if let e = embedder.embed(slice(samples, start: w.start, end: w.end)) {
            byName[w.speaker, default: []].append((w.end - w.start, e))
        }
    }
    var report = "注册到 index 声纹库（声纹 dim=\(embedder.dim)）\n"
    for (name, lst) in byName.sorted(by: { $0.key < $1.key }) {
        let top = lst.sorted { $0.dur > $1.dur }.prefix(per).map { $0.emb }
        let before = matcher.refs.first(where: { $0.name == name })?.count ?? 0
        if before == 0 { matcher.setReference(name: name, embeddings: Array(top)) }
        else { for e in top { matcher.enroll(name: name, embedding: e) } }
        let r = matcher.refs.first(where: { $0.name == name })!
        try index.upsertSpeakerRef(name: name, count: r.count, centroid: r.centroid)
        report += "  \(name): +\(top.count) 样本（\(before)→\(r.count)）\n"
    }
    report += "已写入 index。"
    return report
}

// MARK: - 评测（复刻 Python asr_enroll_eval：ASR 边界 + 合并 + 注册匹配）

/// CR 是转录误标，实为 GGbond（用户钉死）。评测时归一。
private let speakerFix: [String: String] = ["CR": "GGbond"]

public func speakerIDEval(audio: URL, asrJSON: URL, groundTruth: URL,
                          model: String, targetDur: Double = 4.0,
                          enrollPerSpeaker: Int = 3,
                          log: (String) -> Void = { print($0) }) async throws -> String {
    let embedder = try SpeakerEmbedder(model: model)
    log("🔉 解码音频 → 16kHz…")
    let samples = try AudioConverter().resampleAudioFile(audio)

    // GT 时间线
    var gt = parseGroundTruth(groundTruth).map { (t: $0.t, speaker: speakerFix[$0.speaker] ?? $0.speaker) }
    gt.sort { $0.t < $1.t }
    func gtAt(_ t: Double) -> String {
        var lo = 0, hi = gt.count - 1, ans = 0
        while lo <= hi { let m = (lo + hi) / 2; if gt[m].t <= t { ans = m; lo = m + 1 } else { hi = m - 1 } }
        return gt.isEmpty ? "?" : gt[ans].speaker
    }

    // ASR 段 → 合并窗口
    let tr = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: asrJSON))
    let windows = mergeASRSegments(tr.segments.map { (start: $0.start, end: $0.end) }, targetDur: targetDur)
    log("📄 ASR \(tr.segments.count) 段 → 合并 \(windows.count) 窗口(≥\(targetDur)s)；GT \(gt.count) 发言")

    // 逐窗提声纹 + 真值标签
    struct Item { let win: SpeakerWindow; let truth: String; let emb: [Float] }
    var items: [Item] = []
    for w in windows {
        let sl = slice(samples, start: w.start, end: min(w.end, w.start + 15))
        guard let e = embedder.embed(sl) else { continue }
        items.append(Item(win: w, truth: gtAt((w.start + w.end) / 2), emb: e))
    }

    // 每人挑最长 N 窗注册
    var byTruth: [String: [Int]] = [:]
    for (i, it) in items.enumerated() { byTruth[it.truth, default: []].append(i) }
    let matcher = SpeakerMatcher(tauAbs: 0, tauMargin: 0)   // 评测纯准确率，先不拒识
    var enrolled = Set<Int>()
    for (name, idxs) in byTruth {
        let top = idxs.sorted { items[$0].win.dur > items[$1].win.dur }.prefix(enrollPerSpeaker)
        matcher.setReference(name: name, embeddings: top.map { items[$0].emb })
        enrolled.formUnion(top)
    }

    // 匹配其余
    var correct = 0, total = 0
    var conf: [String: [String: Int]] = [:]
    var scored: [(s: Float, ok: Bool)] = []
    for (i, it) in items.enumerated() where !enrolled.contains(i) {
        let r = matcher.match(it.emb)
        let pred = r.name ?? "unknown"
        conf[it.truth, default: [:]][pred, default: 0] += 1
        total += 1; if pred == it.truth { correct += 1 }
        scored.append((r.score, pred == it.truth))
    }
    let acc = total > 0 ? Double(correct) * 100 / Double(total) : 0

    var report = """
    === 说话人识别评测（注册匹配, dim=\(embedder.dim), 窗≥\(targetDur)s, 每人注册\(enrollPerSpeaker)）===
    准确率: \(String(format: "%.1f%%", acc))（\(correct)/\(total)）
    --- 真人→预测 混淆 ---
    """
    for truth in conf.keys.sorted() {
        let c = conf[truth]!; let t = c.values.reduce(0, +); let hit = c[truth] ?? 0
        let detail = c.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
        report += String(format: "\n  %@  %.1f%%  (%d: %@)", truth, t > 0 ? Double(hit)*100/Double(t) : 0, t, detail)
    }
    report += "\n--- cosine 阈值 vs 命中（定 unknown 阈值参考）---"
    for th in [Float(0.0), 0.3, 0.4, 0.5, 0.6] {
        let kept = scored.filter { $0.s >= th }
        if !kept.isEmpty {
            let a = Double(kept.filter { $0.ok }.count) * 100 / Double(kept.count)
            report += String(format: "\n  th=%.1f: 保留 %d/%d, 准确率 %.1f%%", th, kept.count, scored.count, a)
        }
    }
    return report
}
