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
        let raw = try await chat.complete(system: system, user: user, maxTokens: 1500)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
