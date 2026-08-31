import Foundation

public enum ChatError: Error, CustomStringConvertible {
    case http(Int, String)
    case parse(String)
    /// 模型没能把正文说完：撞上 max_tokens 上限被掐断，或思维链吃光预算导致正文为空。
    case truncated(String)
    public var description: String {
        switch self {
        case .http(let c, let m): return "chat HTTP \(c): \(m.prefix(300))"
        case .parse(let m): return "chat 解析失败: \(m.prefix(200))"
        case .truncated(let m): return "chat 输出被截断: \(m)"
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

    /// - Parameter maxTokens: 输出 token 上限。默认 nil＝**不发送该字段**，由服务端按模型上限放行。
    ///   千万别按「这个任务大概输出多长」去估它：推理模型把思维链和正文算进**同一份**预算，
    ///   估小了就是思考先花光、正文一个字吐不出来，而且 HTTP 仍是 200——静默产出空结果。
    ///   （2026-08-31 事故：摘要写死 3000，reasoning 吃满 3000、content 为空，落盘成 0 字节 summary.md。）
    public func complete(system: String?, user: String,
                         maxTokens: Int? = nil, temperature: Double = 0) async throws -> String {
        var messages: [[String: Any]] = []
        if let s = system { messages.append(["role": "system", "content": s]) }
        messages.append(["role": "user", "content": user])

        var req = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 非流式响应在生成完之前不回任何数据，等待间隔≈整次生成耗时；不限输出上限后
        // 单次已实测到 8361 token，120s 会误杀。
        req.timeoutInterval = 300
        var payload: [String: Any] = [
            "model": model, "messages": messages, "temperature": temperature,
        ]
        if let maxTokens { payload["max_tokens"] = maxTokens }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw ChatError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String else {
            throw ChatError.parse(String(data: data, encoding: .utf8) ?? "")
        }
        // 截断必须当失败：服务端用 200 + 空/半截正文表达「我没说完」，
        // 沉默地把它当结果返回，调用方就会把残缺内容当成事实写盘。
        let finish = first["finish_reason"] as? String
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let reasoning = (msg["reasoning_content"] as? String)?.count ?? 0
            throw ChatError.truncated(
                "模型未输出正文（finish_reason=\(finish ?? "?")，思维链 \(reasoning) 字）"
                + (maxTokens.map { "；本次 max_tokens=\($0)，多半是思维链吃光了预算" } ?? ""))
        }
        if finish == "length" {
            throw ChatError.truncated("正文写到一半被 max_tokens 掐断（已输出 \(content.count) 字）")
        }
        return content
    }
}
