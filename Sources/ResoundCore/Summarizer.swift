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
            return list
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
        let filled = template.prompt
            .replacingOccurrences(of: "{date}", with: date)
            .replacingOccurrences(of: "{weekday}", with: weekday)
            .replacingOccurrences(of: "{title}", with: meta.title.isEmpty ? "（无标题）" : meta.title)
            .replacingOccurrences(of: "{speakers}", with: speakers)
            .replacingOccurrences(of: "{transcript}", with: transcript)
        return try await chat.complete(
            system: "你是严谨的会议纪要助手，只依据转录内容、用中文输出 Markdown 纪要。",
            user: filled, maxTokens: 3000)
    }
}
