import Foundation

/// 最终综合：把检索到的 top-k 片段交给 LLM，生成带引用的答案。
public struct Synthesizer {
    let chat: ChatClient
    public init(chat: ChatClient) { self.chat = chat }

    public func answer(query: String, hits: [SearchHit]) async throws -> String {
        guard !hits.isEmpty else { return "没有检索到相关内容。" }
        var src = ""
        for (i, h) in hits.enumerated() {
            let ts = "\(Int(h.start))-\(Int(h.end))s"
            src += "[\(i + 1)]（\(h.recordingId) @\(ts)）\n\(h.text)\n\n"
        }
        let system = """
        你根据检索到的会议/笔记片段回答用户问题。规则：
        - 只用片段中的信息，不要臆造；信息不足就直说"片段中没有足够信息"。
        - 在引用处用 [编号] 标注来源。
        - 用中文，简洁、条理清楚。
        """
        let user = "问题：\(query)\n\n检索到的片段：\n\(src)\n请基于以上片段回答，并用 [编号] 标注引用。"
        return try await chat.complete(system: system, user: user, maxTokens: 3000)
    }
}
