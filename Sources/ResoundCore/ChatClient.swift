import Foundation

public enum ChatError: Error, CustomStringConvertible {
    case http(Int, String)
    case parse(String)
    public var description: String {
        switch self {
        case .http(let c, let m): return "chat HTTP \(c): \(m.prefix(300))"
        case .parse(let m): return "chat 解析失败: \(m.prefix(200))"
        }
    }
}

/// OpenAI 兼容 chat 客户端（DeepSeek deepseek-v4-pro / -flash）。
/// 推理模型返回 content + reasoning_content，这里只取 content。
public struct ChatClient {
    let baseURL: String
    let key: String
    public let model: String

    public init(config: Config, modelOverride: String? = nil) {
        self.baseURL = config.chatBaseURL
        self.key = config.chatKey
        self.model = modelOverride ?? config.chatModel
    }

    public func complete(system: String?, user: String,
                         maxTokens: Int = 4000, temperature: Double = 0) async throws -> String {
        var messages: [[String: Any]] = []
        if let s = system { messages.append(["role": "system", "content": s]) }
        messages.append(["role": "user", "content": user])

        var req = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": messages,
            "max_tokens": maxTokens, "temperature": temperature,
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw ChatError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw ChatError.parse(String(data: data, encoding: .utf8) ?? "")
        }
        return content
    }
}
