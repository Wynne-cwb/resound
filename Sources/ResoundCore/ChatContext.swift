import Foundation

/// 多轮对话的一轮——用于把会话上下文喂给查询规划器与综合器，
/// 让"他/这个/那件事"等指代能基于前文解析，答案也能接着上文说。
public struct ChatTurn: Sendable {
    public let isUser: Bool
    public let text: String
    public init(isUser: Bool, text: String) { self.isUser = isUser; self.text = text }
}

/// 把对话历史渲染成喂给 LLM 的纯文本块（助手长回答截断，控制 token）。
public func renderHistory(_ history: [ChatTurn], assistantCap: Int = 600) -> String {
    guard !history.isEmpty else { return "" }
    var s = ""
    for t in history {
        let who = t.isUser ? "用户" : "助手"
        var body = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isUser, body.count > assistantCap { body = String(body.prefix(assistantCap)) + "…" }
        s += "\(who)：\(body)\n"
    }
    return s
}
