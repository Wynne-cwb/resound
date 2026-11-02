import Foundation
import FluidAudio   // AudioConverter + silero VAD（经 DiarModelCache）

/// 从「用户认可标注正确」的录音重建声纹库（2026-11-02，第二次清库后用）。
///
/// 与改名时的增量注册（renameSpeakerInRecording）相比，这里做了三件事防止再次污染：
///   1. 样本只取**同一说话人连续 run 内、且在其自身分段区间内**的 VAD 有声部分——不跨越别人的插话拼窗；
///   2. 每条录音每人先求一个录音级质心，跨录音做 leave-one-out 一致性检查，低于门限的整条剔除
///      （标注错位/被别人顶替的录音会在这里暴露，而不是悄悄混进质心）；
///   3. 顺带输出 genuine / impostor 分数分布（录音级质心 vs 本人/他人参考），作为匹配阈值的标定依据。
public struct SpeakerRebuildItem: Codable {
    public let id: String
    /// diarization.json 里的说话人标签 → 注册用的真名；不在表里的标签（如「说话人1」）跳过。
    public let map: [String: String]
}

public func rebuildSpeakerRefs(
    vaultRoot: URL, plan: [SpeakerRebuildItem], model: String,
    indexPath: URL, embeddingDim: Int,
    minConsistency: Float = 0.5, perRecording: Int = 8,
    dryRun: Bool,
    log: (String) -> Void = { print($0) }
) async throws {
    let byId = Dictionary(plan.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let recs = listRecordings(vaultRoot: vaultRoot).filter { byId[$0.id] != nil }
    let missing = Set(byId.keys).subtracting(recs.map { $0.id })
    if !missing.isEmpty { log("⚠️ plan 里有 \(missing.count) 条录音在 vault 找不到：\(missing.sorted().joined(separator: ", "))") }

    let embedder = try await DiarModelCache.shared.embedder(model: model)
    let vad = try? await DiarModelCache.shared.vad()

    // (person, recId) → 窗口声纹
    var embs: [String: [String: [[Float]]]] = [:]
    for (n, rec) in recs.enumerated() {
        guard let map = byId[rec.id]?.map, let diar = loadDiarization(rec.dir), !diar.isEmpty else {
            log("⚠️ \(rec.id) 没有 diarization.json，跳过"); continue
        }
        let samples = try AudioConverter().resampleAudioFile(rec.audioURL)
        var voiced: [(start: Double, end: Double)] = []
        if let vad {
            voiced = (try? await vad.segmentSpeech(samples))?.map { (Double($0.startTime), Double($0.endTime)) } ?? []
        }
        // Voiced parts of [s, e]; without VAD fall back to the raw interval.
        func voicedParts(_ s: Double, _ e: Double) -> [(Double, Double)] {
            guard !voiced.isEmpty else { return [(s, e)] }
            return voiced.compactMap { v in
                let a = max(s, v.start), b = min(e, v.end)
                return b - a > 0.1 ? (a, b) : nil
            }
        }

        // Contiguous same-speaker runs → windows of 3–10s voiced audio, never crossing another speaker.
        let sorted = diar.sorted { $0.start < $1.start }
        var windows: [String: [[Float]]] = [:]
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1].speaker == sorted[i].speaker { j += 1 }
            if let person = map[sorted[i].speaker] {
                var buf: [Float] = []
                func flush() {
                    if buf.count >= 3 * 16000 { windows[person, default: []].append(buf) }
                    buf = []
                }
                for seg in sorted[i...j] {
                    for (a, b) in voicedParts(seg.start, seg.end) {
                        buf.append(contentsOf: slice(samples, start: a, end: b))
                        if buf.count >= 10 * 16000 { flush() }
                    }
                }
                flush()
            }
            i = j + 1
        }
        var line: [String] = []
        for (person, ws) in windows {
            let top = ws.sorted { $0.count > $1.count }.prefix(perRecording)
            let es = top.compactMap { embedder.embed($0) }
            if !es.isEmpty { embs[person, default: [:]][rec.id] = es }
            line.append("\(person)×\(es.count)")
        }
        log("  [\(n + 1)/\(recs.count)] \(rec.id)：\(line.sorted().joined(separator: " "))")
    }

    func mean(_ vs: [[Float]]) -> [Float] {
        var c = [Float](repeating: 0, count: vs[0].count)
        for v in vs { for k in c.indices { c[k] += v[k] } }
        l2normalize(&c); return c
    }

    // Leave-one-out consistency per person: drop recordings whose centroid disagrees with the rest.
    var recCentroid: [String: [String: [Float]]] = [:]
    for (p, m) in embs { for (r, es) in m { recCentroid[p, default: [:]][r] = mean(es) } }
    var accepted: [String: Set<String>] = [:]
    log("\n=== 跨录音一致性（leave-one-out，门限 \(minConsistency)）===")
    for p in recCentroid.keys.sorted() {
        let m = recCentroid[p]!
        guard m.count >= 2 else {
            accepted[p] = Set(m.keys)
            log("  \(p)：仅 1 条录音，无法交叉校验"); continue
        }
        var scores: [(String, Float)] = []
        for (r, c) in m {
            let others = m.filter { $0.key != r }.map { $0.value }
            scores.append((r, cosine(c, mean(others))))
        }
        scores.sort { $0.1 < $1.1 }
        accepted[p] = Set(scores.filter { $0.1 >= minConsistency }.map { $0.0 })
        let vals = scores.map { $0.1 }
        log(String(format: "  %@：%d 条，LOO min %.2f / 中位 %.2f / max %.2f", p, vals.count,
                   vals.first!, vals[vals.count / 2], vals.last!))
        for (r, s) in scores where s < minConsistency { log(String(format: "    ✗ 剔除 %@（%.2f）", r, s)) }
    }

    // Final references from accepted recordings only.
    var refs: [String: (centroid: [Float], count: Int)] = [:]
    for (p, ok) in accepted where !ok.isEmpty {
        let all = ok.flatMap { embs[p]![$0]! }
        refs[p] = (mean(all), all.count)
    }

    // Calibration: recording-level centroid vs own reference (leave-one-out) and vs others' references.
    var genuine: [Float] = [], impostor: [Float] = []
    for (p, ok) in accepted {
        for r in ok {
            let c = recCentroid[p]![r]!
            let rest = ok.filter { $0 != r }.flatMap { embs[p]![$0]! }
            if !rest.isEmpty { genuine.append(cosine(c, mean(rest))) }
            for (q, ref) in refs where q != p { impostor.append(cosine(c, ref.centroid)) }
        }
    }
    func pct(_ v: [Float], _ q: Double) -> Float {
        let s = v.sorted(); return s[min(s.count - 1, max(0, Int(Double(s.count - 1) * q)))]
    }
    log("\n=== 阈值标定（录音级质心）===")
    if !genuine.isEmpty {
        log(String(format: "  本人 genuine  n=%d：min %.2f  p5 %.2f  中位 %.2f", genuine.count,
                   pct(genuine, 0), pct(genuine, 0.05), pct(genuine, 0.5)))
    }
    if !impostor.isEmpty {
        log(String(format: "  他人 impostor n=%d：中位 %.2f  p95 %.2f  max %.2f", impostor.count,
                   pct(impostor, 0.5), pct(impostor, 0.95), pct(impostor, 1)))
    }
    // Open-set simulation per (tauAbs, margin, evidence): closed = refs built without this recording;
    // open = refs built without this person at all (an unregistered speaker) → any name is a false accept.
    log("\n=== 匹配规则模拟（录音级质心；证据=参与质心的窗口数，每窗 3–10s）===")
    log("  tauAbs margin 证据 | 已注册:认对  认错  拒识 | 未注册:误认")
    for evidence in [8, 2, 1] {
        for (tau, mg) in [(Float(0.5), Float(0)), (0.6, 0), (0.6, 0.1), (0.65, 0.1), (0.7, 0.1)] {
            var ok = 0, wrong = 0, reject = 0, fa = 0, openN = 0
            for (p, recs) in accepted {
                for r in recs {
                    let c = mean(Array(embs[p]![r]!.prefix(evidence)))
                    func decide(_ cand: [(String, [Float])]) -> String? {
                        let s = cand.map { ($0.0, cosine(c, $0.1)) }.sorted { $0.1 > $1.1 }
                        guard let top = s.first, top.1 >= tau else { return nil }
                        if s.count > 1 && top.1 - max(s[1].1, 0) < mg { return nil }
                        return top.0
                    }
                    var closed: [(String, [Float])] = []
                    for (q, okq) in accepted {
                        let pool = okq.filter { !(q == p && $0 == r) }.flatMap { embs[q]![$0]! }
                        if !pool.isEmpty { closed.append((q, mean(pool))) }
                    }
                    switch decide(closed) { case p?: ok += 1; case nil: reject += 1; default: wrong += 1 }
                    openN += 1
                    if decide(closed.filter { $0.0 != p }) != nil { fa += 1 }
                }
            }
            let n = Double(ok + wrong + reject)
            log(String(format: "  %.2f   %.2f   %d   |  %5.1f%% %5.1f%% %5.1f%% |  %5.1f%%", tau, mg, evidence,
                       Double(ok) * 100 / n, Double(wrong) * 100 / n, Double(reject) * 100 / n,
                       Double(fa) * 100 / Double(openN)))
        }
    }

    log("\n=== 参考声纹两两相似度 ===")
    let names = refs.keys.sorted()
    for a in 0..<names.count {
        for b in (a + 1)..<names.count {
            log(String(format: "  %@ – %@：%.3f", names[a], names[b],
                       cosine(refs[names[a]]!.centroid, refs[names[b]]!.centroid)))
        }
    }

    guard !dryRun else { log("\n（--dry-run：未写入声纹库）"); return }
    let idx = try Index(path: indexPath, dim: embeddingDim)
    for p in names {
        try idx.upsertSpeakerRef(name: p, count: refs[p]!.count, centroid: refs[p]!.centroid)
    }
    log("\n✅ 已写入声纹库 \(names.count) 人：" + names.map { "\($0)(\(refs[$0]!.count))" }.joined(separator: " "))
}
