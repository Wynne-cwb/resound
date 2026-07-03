import Foundation

/// 用户词表，来自 vault/glossary.txt（+ CLI --hint）。
///
/// glossary.txt 格式（一行一条，# 注释）：
///   Resound = Resount              # 规范词 = 变体（转录后把变体替换成规范词）
///   Qwen3 = 昆3, 坤3               # 多个变体用逗号分隔
///   sherpa-onnx                    # 只做偏置、不纠正
///
/// 两层作用：
///   - terms（所有规范词 + hints）→ 转录前注入 promptTokens 做偏置（预防）
///   - corrections（变体→规范词）→ 转录后确定性替换（兜底）
public struct Glossary {
    public let terms: [String]
    public let corrections: [(canonical: String, variant: String)]

    public static func load(vaultRoot: URL, extraHints: [String] = []) -> Glossary {
        var terms: [String] = []
        var corr: [(String, String)] = []

        let f = vaultRoot.appendingPathComponent("glossary.txt")
        if let s = try? String(contentsOf: f, encoding: .utf8) {
            for raw in s.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if let eq = line.firstIndex(of: "=") {
                    let canonical = line[..<eq].trimmingCharacters(in: .whitespaces)
                    let variants = line[line.index(after: eq)...]
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    if !canonical.isEmpty {
                        terms.append(canonical)
                        for v in variants { corr.append((canonical, v)) }
                    }
                } else {
                    terms.append(line)
                }
            }
        }
        terms.append(contentsOf: extraHints)   // hints 只做偏置

        // 变体按长度降序，避免短变体先替换破坏长变体
        corr.sort { $0.1.count > $1.1.count }
        return Glossary(terms: terms, corrections: corr)
    }

    public var promptString: String? {
        terms.isEmpty ? nil : terms.joined(separator: ", ")
    }

    /// 把说话人真名同步进 vault/glossary.txt 的「自动管理」小节（纯偏置词，不加变体纠正）——
    /// 会议里常念到人名，进偏置词表可让转录把人名拼对。去重（用户手写过或本节已有则跳过）、
    /// 忽略空名与匿名「说话人N」。返回新加入的名字（便于日志）。
    @discardableResult
    public static func syncSpeakerNames(vaultRoot: URL, names: [String]) -> [String] {
        let clean = names
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("说话人") }
        guard !clean.isEmpty else { return [] }
        let f = vaultRoot.appendingPathComponent("glossary.txt")
        var text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        // 已出现过的词（规范词或裸词，任意行）视为已存在
        let existing = Set(text.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            if let eq = line.firstIndex(of: "=") { return String(line[..<eq]).trimmingCharacters(in: .whitespaces) }
            return line
        })
        // 去重 + 本批内去重，保持顺序
        var seen = Set<String>(), toAdd: [String] = []
        for n in clean where !existing.contains(n) && !seen.contains(n) { seen.insert(n); toAdd.append(n) }
        guard !toAdd.isEmpty else { return [] }
        let marker = "# --- 说话人（自动加入，转录偏置用）---"
        if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
        if !text.contains(marker) { text += "\n" + marker + "\n" }
        text += toAdd.joined(separator: "\n") + "\n"
        try? text.write(to: f, atomically: true, encoding: .utf8)
        return toAdd
    }

    /// 别名纠正：把转录里的变体替换成规范词，返回纠正后 Transcript 和替换处数（仅按段文本计）。
    public func apply(to transcript: Transcript) -> (transcript: Transcript, replacements: Int) {
        guard !corrections.isEmpty else { return (transcript, 0) }

        var count = 0
        func fix(_ s: String, counting: Bool) -> String {
            var out = s
            for (canonical, variant) in corrections where out.contains(variant) {
                if counting {
                    count += out.components(separatedBy: variant).count - 1
                }
                out = out.replacingOccurrences(of: variant, with: canonical)
            }
            return out
        }

        let segs = transcript.segments.map { seg in
            Transcript.Segment(
                id: seg.id,
                start: seg.start,
                end: seg.end,
                text: fix(seg.text, counting: true),
                words: seg.words.map {
                    Transcript.Word(w: fix($0.w, counting: false), start: $0.start, end: $0.end)
                },
                track: seg.track
            )
        }
        return (Transcript(language: transcript.language, segments: segs), count)
    }
}
