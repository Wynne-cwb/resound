import Foundation

/// 「智能错词标注」学习器：观察用户在转录里做的查找替换（错→对），跨录音累计；
/// 达到阈值时产出「加入词表」建议，用户一键确认即写回 vault 的 glossary.txt。
///
/// 把「自己判断哪个词该进词表」这个重操作，降级成「系统观察 + 一键确认」。
///
/// 设计要点：
/// - **计数维度是不同录音数**：单条录音里一次 replaceAll 把所有 `q` 一次换掉，只算 1 次；
///   反复在不同会议里出现,才是值得进词表的系统性 ASR 错误。
/// - **已知词 vs 新词阈值不同**：`to` 已是词表规范词（已知术语被听错）→ 第 1 次就建议；
///   全新词 → 攒够 `newWordThreshold`（默认 2）条不同录音再建议，避免一次性误操作进表。
/// - **变体安全分流**：英文/型号/较长 token 走确定性子串替换（硬，进 glossary 变体）；
///   模糊短中文词只把规范词加进偏置 + 留作 AI 校对 few-shot（软），
///   避免「学→Share」式短串子串替换污染未来正常文本（见 [TranscriptCorrector]）。
/// - **dismiss 过的不再打扰**；观察日志放 App Support（派生、机器本地、噪声大），
///   只有用户确认的规范结果才落进 vault。
public struct CorrectionObservation: Codable, Identifiable, Hashable {
    public var from: String              // 错（被替换掉的写法）
    public var to: String                // 对（替换成的规范词）
    public var recordingIds: [String]    // 出现过此更正的不同录音（去重）
    public enum Status: String, Codable { case pending, accepted, dismissed }
    public var status: Status

    public var id: String { from + "\u{1}" + to }
    /// 跨录音出现次数。
    public var count: Int { recordingIds.count }
    /// 该更正若被采纳，是走确定性子串替换（硬）还是仅 AI 校对（软）。
    public var hardReplace: Bool { CorrectionLearner.isHardReplaceSafe(from) }
}

public enum CorrectionLearner {
    /// 新词（`to` 不在现有词表）攒够几条不同录音才提示。已知词恒为 1。
    public static let newWordThreshold = 2

    static func storeURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Resound")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("correction-observations.json")
    }

    static func load() -> [CorrectionObservation] {
        guard let d = try? Data(contentsOf: storeURL()) else { return [] }
        return (try? JSONDecoder().decode([CorrectionObservation].self, from: d)) ?? []
    }

    static func save(_ all: [CorrectionObservation]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? enc.encode(all).write(to: storeURL())
    }

    /// 变体能否安全地做确定性子串替换：含 ASCII 字母/数字（英文专名/型号）→ 安全；
    /// 否则要够长（≥4 字），太短的纯中文串（如「学」「片」）做子串替换会误伤正常文本。
    public static func isHardReplaceSafe(_ variant: String) -> Bool {
        if variant.range(of: "[A-Za-z0-9]", options: .regularExpression) != nil { return true }
        return variant.count >= 4
    }

    /// 这条更正值不值得作为词表候选来观察（挡掉整句改写、纯空格/盘古之白调整等非术语更正）。
    static func shouldObserve(from: String, to: String) -> Bool {
        guard !from.isEmpty, !to.isEmpty, from != to else { return false }
        guard from.count <= 32, to.count <= 32 else { return false }   // 整句改写不是术语
        let strip: (String) -> String = {
            $0.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00A0}", with: "")
        }
        if strip(from) == strip(to) { return false }                    // 仅空格差异（盘古之白）
        return true
    }

    /// 记录一次更正。返回非 nil = 此刻「刚跨过阈值」，应即时提示用户（仅跨越当下提示一次，
    /// 后续同更正在新录音里出现不再重复打扰，但仍留在收件箱 [pending] 里待确认）。
    @discardableResult
    public static func record(from rawFrom: String, to rawTo: String, recordingId: String,
                              knownCanonicals: Set<String>) -> CorrectionObservation? {
        let from = rawFrom.trimmingCharacters(in: .whitespaces)
        let to = rawTo.trimmingCharacters(in: .whitespaces)
        guard shouldObserve(from: from, to: to) else { return nil }

        var all = load()
        let key = from + "\u{1}" + to
        let prevCount = all.first { $0.id == key }?.count ?? 0
        var current: CorrectionObservation
        if let i = all.firstIndex(where: { $0.id == key }) {
            if all[i].status == .dismissed { return nil }               // 已忽略，不再观察/打扰
            if !all[i].recordingIds.contains(recordingId) { all[i].recordingIds.append(recordingId) }
            current = all[i]
        } else {
            current = CorrectionObservation(from: from, to: to, recordingIds: [recordingId], status: .pending)
            all.append(current)
        }
        save(all)

        guard current.status == .pending else { return nil }
        let threshold = knownCanonicals.contains(to) ? 1 : newWordThreshold
        return (prevCount < threshold && current.count >= threshold) ? current : nil
    }

    /// 待确认建议（收件箱）：按出现次数降序。
    public static func pending() -> [CorrectionObservation] {
        load().filter { $0.status == .pending }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.to < $1.to }
    }

    /// 采纳建议：按安全度分流写回 glossary.txt，并标记为 accepted。
    public static func accept(_ obs: CorrectionObservation, vaultRoot: URL) {
        var entries = GlossaryStore.load(vaultRoot: vaultRoot)
        if isHardReplaceSafe(obs.from) {
            // 硬：把错写法登记成 `to` 的易错变体（转录后确定性替换回规范词）。
            if let i = entries.firstIndex(where: { $0.canonical == obs.to }) {
                if !entries[i].variants.contains(obs.from) { entries[i].variants.append(obs.from) }
            } else {
                entries.append(GlossaryEntry(canonical: obs.to, variants: [obs.from]))
            }
        } else {
            // 软：危险短串不做子串硬替换，只保证规范词进偏置；错听例子交给 AI 校对器（mishearExamples）。
            if !entries.contains(where: { $0.canonical == obs.to }) {
                entries.append(GlossaryEntry(canonical: obs.to))
            }
        }
        try? GlossaryStore.save(entries, vaultRoot: vaultRoot)
        setStatus(obs.id, .accepted)
    }

    /// 忽略建议：标记 dismissed，之后该更正不再观察/提示。
    public static func dismiss(_ id: String) { setStatus(id, .dismissed) }

    static func setStatus(_ id: String, _ s: CorrectionObservation.Status) {
        var all = load()
        if let i = all.firstIndex(where: { $0.id == id }) { all[i].status = s; save(all) }
    }

    /// 已采纳的「软更正」错听例子，喂给 [TranscriptCorrector] 做 few-shot（硬更正已由 glossary 子串替换处理）。
    public static func mishearExamples() -> [(wrong: String, right: String)] {
        load().filter { $0.status == .accepted && !isHardReplaceSafe($0.from) }
            .map { (wrong: $0.from, right: $0.to) }
    }
}
