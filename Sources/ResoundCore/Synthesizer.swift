import Foundation

/// 最终综合：把检索到的 top-k 片段交给 LLM，生成带引用的答案。
public struct Synthesizer {
    let chat: ChatClient
    public init(chat: ChatClient) { self.chat = chat }

    public func answer(query: String, hits: [SearchHit], history: [ChatTurn] = []) async throws -> String {
        guard !hits.isEmpty else { return "没有检索到相关内容。" }
        var src = ""
        for (i, h) in hits.enumerated() {
            let label: String
            if h.isDocument {
                label = "📄文档：\(h.docTitle ?? h.docId ?? "未命名")"
            } else {
                let ts = "\(Int(h.start))-\(Int(h.end))s"
                let date = h.recordingDate.map { "\($0) " } ?? ""
                label = "🎙️录音 \(date)\(h.recordingId) @\(ts)"
            }
            src += "[\(i + 1)]（\(label)）\n\(h.text)\n\n"
        }
        let system = """
        你根据检索到的会议/文档片段回答用户问题。规则：
        - 只用片段中的信息，不要臆造；信息不足就直说"片段中没有足够信息"。
        - 片段可能来自会议录音（带日期/时间）或上传的文档；回答涉及时间时按日期组织。\(todayAnchor())
        - 在引用处用 [编号] 标注来源。
        - 如有对话历史，用它理解指代（他/这个/那件事）并接着上文说，但答案内容只基于片段。
        - 用中文，简洁、条理清楚。\(zhWritingStyle)
        """
        let hist = renderHistory(history)
        let histBlock = hist.isEmpty ? "" : "对话历史：\n\(hist)\n"
        let user = "\(histBlock)当前问题：\(query)\n\n检索到的片段：\n\(src)\n请基于以上片段回答，并用 [编号] 标注引用。"
        return try await chat.complete(system: system, user: user, maxTokens: 3000)
    }
}
