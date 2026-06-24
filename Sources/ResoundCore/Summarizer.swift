import Foundation

/// 一个可自定义的摘要模板：不同会议场景用不同 prompt（1-on-1 / 团队会 / 头脑风暴 / 通用）。
/// prompt 支持占位符：{date} {weekday} {title} {speakers} {transcript}
public struct SummaryTemplate: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var prompt: String
    public init(id: String, name: String, prompt: String) {
        self.id = id; self.name = name; self.prompt = prompt
    }
}

/// 模板集合：存 ~/Library/Application Support/Resound/summary-templates.json。
/// 首次缺文件 → 落地内置默认模板。
public struct SummaryTemplateStore {
    public static func storeURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Resound/summary-templates.json")
    }

    public static let builtins: [SummaryTemplate] = [
        SummaryTemplate(id: "general", name: "通用", prompt: """
        这是一场会议/对话的转录，发生在 {date}（{weekday}），标题「{title}」，参与者：{speakers}。
        请输出简洁的中文纪要：
        - 一句话概述本次主题
        - 关键讨论点（要点列表）
        - 决定事项 / 结论
        - 待办与负责人（若有）
        只依据转录内容，不要臆造。

        转录：
        {transcript}
        """),
        SummaryTemplate(id: "one-on-one", name: "1-on-1", prompt: """
        这是一次 1-on-1 谈话的转录，发生在 {date}（{weekday}），参与者：{speakers}。
        请输出中文纪要，侧重：
        - 对方当前状态 / 情绪 / 关注点
        - 反馈（给出的 & 收到的）
        - 达成的共识与承诺
        - 我方需要跟进的事项
        只依据转录内容，不要臆造。

        转录：
        {transcript}
        """),
        SummaryTemplate(id: "team-meeting", name: "团队会议", prompt: """
        这是一场团队会议的转录，发生在 {date}（{weekday}），标题「{title}」，参与者：{speakers}。
        请输出中文纪要：
        - 议题概览
        - 各议题的讨论与结论
        - 决议事项
        - 行动项（事项 / 负责人 / 时间点）
        只依据转录内容，不要臆造。

        转录：
        {transcript}
        """),
        SummaryTemplate(id: "brainstorm", name: "头脑风暴", prompt: """
        这是一场头脑风暴的转录，发生在 {date}（{weekday}），参与者：{speakers}。
        请输出中文纪要，尽量保留发散的想法：
        - 核心命题
        - 提出的点子（分组列出，不要过度收敛）
        - 有共识 / 被看好的方向
        - 待验证的开放问题
        只依据转录内容，不要臆造。

        转录：
        {transcript}
        """),
    ]

    public static func load() -> [SummaryTemplate] {
        let url = storeURL()
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([SummaryTemplate].self, from: data), !list.isEmpty {
            // 自愈（仅内存，不在 load 里写盘——避免与运行中的 App 并发存盘相互覆盖丢数据）：
            // 缺 {transcript} 的模板补回，否则转录永远填不进去。文件会在用户下次保存模板时落正。
            return list.map { t in
                t.prompt.contains("{transcript}") ? t
                    : SummaryTemplate(id: t.id, name: t.name, prompt: t.prompt + "\n\n转录：\n{transcript}")
            }
        }
        try? save(builtins)
        return builtins
    }

    public static func template(id: String?) -> SummaryTemplate {
        let all = load()
        if let id, let t = all.first(where: { $0.id == id }) { return t }
        return all.first ?? builtins[0]
    }

    public static func save(_ templates: [SummaryTemplate]) throws {
        let url = storeURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try enc.encode(templates).write(to: url)
    }
}

/// 生成会议摘要：把转录 + 录音时间（作锚点）+ 模板交给 LLM。
public struct Summarizer {
    let chat: ChatClient
    public init(chat: ChatClient) { self.chat = chat }

    public struct Meta {
        public let title: String
        public let recordedAt: String   // ISO8601
        public let speakers: [String]
        public init(title: String, recordedAt: String, speakers: [String]) {
            self.title = title; self.recordedAt = recordedAt; self.speakers = speakers
        }
    }

    public func summarize(transcript: String, meta: Meta, template: SummaryTemplate) async throws -> String {
        let date = localDate(fromISO: meta.recordedAt) ?? String(meta.recordedAt.prefix(10))
        let weekday = weekdayZh(fromISO: meta.recordedAt) ?? ""
        let speakers = meta.speakers.isEmpty ? "未知" : meta.speakers.joined(separator: "、")
        // 兜底：模板没有 {transcript} 占位符则补一段，确保转录一定被填进去（否则 AI 会反问「请提供原文」）
        var promptText = template.prompt
        if !promptText.contains("{transcript}") { promptText += "\n\n转录：\n{transcript}" }
        let filled = promptText
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{weekday}", with: weekday)
            .replacingOccurrences(of: "{title}", with: meta.title.isEmpty ? "（无标题）" : meta.title)
            .replacingOccurrences(of: "{speakers}", with: speakers)
            .replacingOccurrences(of: "{transcript}", with: transcript)
        return try await chat.complete(
            system: """
            你是严谨的会议纪要助手，只依据提供的转录内容、用中文输出 Markdown 会议纪要。
            本次会议发生于 \(date)（\(weekday)）——这是权威事实。转录里出现的相对时间（如「今年」「去年」「上个季度」「下周」「Q2」等）\
            一律以这个会议日期为基准推算，**绝不要自行假设或编造年份/日期**（例如别把今年的事写成去年）。
            \(zhWritingStyle)
            直接输出纪要正文本身，不要任何开场白、承接语或客套话（例如「好的」「以下是」「这是根据您提供的转录内容整理的会议纪要」之类一律不要），\
            不要复述本提示，不要用代码块包裹整篇，结尾也不要追加说明。
            """,
            user: filled, maxTokens: 3000)
    }
}

// MARK: - 模板提示词 AI 协助（生成 / 润色）

public enum TemplateAssistMode { case generate, polish }

/// 内置占位符块：任何模板都必须以它收尾，Summarizer 才能把真实数据填进去。
private let templatePlaceholderBlock = """
会议：{title}（{date}）
参与者：{speakers}

转录：
{transcript}
"""

/// 用 LLM 为摘要模板「生成 / 润色」提示词。
/// **务必注入内置占位符**：system 里硬性要求末尾包含占位符块；即使模型不遵守，
/// 返回后也会兜底补上缺失的 `{transcript}` 块——保证生成的模板能被正确填充。
public func assistTemplatePrompt(mode: TemplateAssistMode, intent: String, base: String,
                                 chat: ChatClient) async -> String {
    let intentTrim = intent.trimmingCharacters(in: .whitespacesAndNewlines)
    let instr: String
    switch mode {
    case .generate:
        instr = "请为一个会议摘要模板撰写一段高质量的中文提示词。用途：\(intentTrim.isEmpty ? "通用会议纪要" : intentTrim)。"
    case .polish:
        instr = "请改进下面这段会议摘要模板的提示词，使其更清晰、结构化、可直接驱动大模型生成中文会议纪要。"
            + (intentTrim.isEmpty ? "" : "额外侧重：\(intentTrim)。")
            + "\n\n原提示词：\n" + (base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "（空）" : base)
    }
    let system = """
    你是资深提示词工程师，正在帮用户完善会议纪要生成提示词。\(instr)

    要求：
    1. 用中文。
    2. 指明输出结构（如概述、关键讨论点、决议、行动项等），按用途合理取舍。
    3. 末尾必须原样包含这些占位符行：
    \(templatePlaceholderBlock)
    4. 只输出提示词正文，不要任何解释、标题或代码块。
    """
    var out = (try? await chat.complete(system: system, user: instr, maxTokens: 1200, temperature: 0.4)) ?? ""
    out = out.trimmingCharacters(in: .whitespacesAndNewlines)
    if out.isEmpty { out = templateAssistFallback(mode: mode, intent: intentTrim, base: base) }
    // 兜底：内置占位符必须在（缺 {transcript} 视为没注入，补一段标准块）
    if !out.contains("{transcript}") {
        out += "\n\n" + templatePlaceholderBlock
    }
    return out
}

/// 无网/模型失败时的本地兜底提示词（一定含占位符）。
private func templateAssistFallback(mode: TemplateAssistMode, intent: String, base: String) -> String {
    let focus = intent.isEmpty ? "本次会议要点" : intent
    let head = (mode == .polish && !base.trimmingCharacters(in: .whitespaces).isEmpty)
        ? String(base.split(separator: "\n").first ?? "")
        : "你是专业的会议纪要助手。本次会议侧重「\(focus)」，请基于以下信息输出清晰、结构化的中文纪要。"
    return [
        head, "",
        "请按以下结构组织，省略没有内容的部分：",
        "1. 概述 —— 用 2-3 句交代会议目的与结论。",
        "2. 关键讨论点 —— 分条列出，保留关键数据与分歧。",
        intent.isEmpty ? "3. 决议 —— 明确达成的结论。" : "3. \(focus) —— 重点展开本次最需要沉淀的内容。",
        "4. 行动项 —— 按「责任人 / 事项 / 截止时间」逐条列出。",
        "5. 待跟进与风险 —— 尚未解决或需关注的问题。",
        "", "语言简洁专业，忠于原意，不要编造未提及的信息。", "",
        templatePlaceholderBlock,
    ].joined(separator: "\n")
}
