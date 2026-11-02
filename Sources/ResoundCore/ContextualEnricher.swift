import Foundation

/// Contextual Retrieval：给每个 chunk 生成"它在整篇里的背景"，前置到 chunk 再 embed，让 chunk 自包含。
/// 整篇文档放在 prompt 前部，DeepSeek 自动 prefix 缓存，逐 chunk 调用只为文档付一次。
public struct ContextualEnricher {
    let chat: ChatClient
    public init(chat: ChatClient) { self.chat = chat }

    public func context(document: String, chunk: String) async throws -> String {
        let system = """
        你为会议/笔记转录的片段生成简短检索上下文。只输出一两句中文，说明该片段在整篇里的背景\
        （主题、涉及的人或对象、所处阶段），不要复述原文、不要解释、不要加引号。
        """
        let user = """
        <文档>
        \(document)
        </文档>

        待定位片段：
        <片段>
        \(chunk)
        </片段>

        用一两句话给出该片段的背景上下文，只输出上下文本身。
        """
        let raw = try await chat.complete(system: system, user: user)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Batched variant: one request locates several chunks against the same document.
    ///
    /// Why: per-chunk calls cost (chunks × whole transcript) input tokens and one request per chunk —
    /// the 2026-10-08 Platform meeting alone was 141 requests. The document still comes first so the
    /// shared prefix (system + document) stays cacheable across batches.
    /// Returns one entry per input chunk; nil where the model's answer was missing or unparseable
    /// (callers retry those one by one, so a sloppy batch never silently drops context).
    public func contexts(document: String, chunks: [String]) async throws -> [String?] {
        guard chunks.count > 1 else {
            return [try await context(document: document, chunk: chunks.first ?? "")]
        }
        let system = """
        你为会议/笔记转录的片段生成简短检索上下文。对每个片段只输出一两句中文，说明该片段在整篇里的背景\
        （主题、涉及的人或对象、所处阶段），不要复述原文、不要解释、不要加引号。\
        每条都必须自带整篇的大背景（这是一场关于什么的会议/文档、目标或关键时间点），再说该片段处在哪个环节、\
        讲了什么——每条会被单独拿去检索，看不到其它条，所以即使与其它条重复也要写全，不要省略成「继续讨论…」。
        """
        let numbered = chunks.enumerated()
            .map { "<片段 \($0.offset + 1)>\n\($0.element)\n</片段 \($0.offset + 1)>" }
            .joined(separator: "\n")
        let user = """
        <文档>
        \(document)
        </文档>

        待定位片段：
        \(numbered)

        为每个片段给出一两句背景上下文。逐行输出「[序号] 上下文」，序号与片段一一对应、共 \(chunks.count) 行，\
        不要输出任何其它文字。
        """
        let raw = try await chat.complete(system: system, user: user)
        var out = [String?](repeating: nil, count: chunks.count)
        for line in raw.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("["), let close = t.firstIndex(of: "]"),
                  let n = Int(t[t.index(after: t.startIndex)..<close]), (1...chunks.count).contains(n) else { continue }
            let ctx = t[t.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if !ctx.isEmpty { out[n - 1] = ctx }
        }
        return out
    }
}
