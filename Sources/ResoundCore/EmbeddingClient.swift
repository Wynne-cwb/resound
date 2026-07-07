import Foundation

public enum EmbeddingError: Error, CustomStringConvertible {
    case http(Int, String)
    case parse(String)
    public var description: String {
        switch self {
        case .http(let c, let m): return "embedding HTTP \(c): \(m.prefix(300))"
        case .parse(let m): return "embedding 解析失败: \(m.prefix(200))"
        }
    }
}

/// OpenAI 兼容 embedding 客户端（aihubmix / qwen3-embedding-8b）。
public struct EmbeddingClient {
    let baseURL: String
    let key: String
    let model: String

    public init(config: Config) {
        self.baseURL = config.embeddingBaseURL
        self.key = config.embeddingKey
        self.model = config.embeddingModel
    }

    /// 文档侧：不加 instruction。支持批量。
    public func embedDocuments(_ texts: [String]) async throws -> [[Float]] {
        try await embed(texts)
    }

    /// 查询侧：Qwen3-Embedding 非对称，query 前置 instruction。
    public func embedQuery(_ query: String) async throws -> [Float] {
        let instructed = "Instruct: Given a search query, retrieve relevant passages that answer it\nQuery: \(query)"
        return try await embed([instructed])[0]
    }

    /// 429（限流）/ 5xx / 网络抖动会重试；退避优先遵守 Retry-After，否则指数退避带抖动。
    private static let maxAttempts = 5

    private func embed(_ inputs: [String]) async throws -> [[Float]] {
        var req = URLRequest(url: URL(string: baseURL + "/embeddings")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": inputs])

        var data = Data()
        var lastErr: Error?
        for attempt in 1...Self.maxAttempts {
            do {
                let (d, resp) = try await URLSession.shared.data(for: req)
                let http = resp as? HTTPURLResponse
                let code = http?.statusCode ?? -1
                if code == 200 { data = d; break }
                let body = String(data: d, encoding: .utf8) ?? ""
                let err = EmbeddingError.http(code, body)
                // 可重试：429 限流 / 5xx / 网关瞬时路由不到模型（aihubmix 用 400 + no_available_channel 表达临时容量不足）。
                // 其余（401 鉴权、真正的 400 参数错等）立即失败。
                let transient400 = code == 400 && (body.contains("no_available_channel")
                    || body.contains("cannot be routed"))
                let retryable = code == 429 || (500...599).contains(code) || transient400
                guard retryable, attempt < Self.maxAttempts else {
                    throw err
                }
                lastErr = err
                try await Self.sleep(attempt: attempt, retryAfter: http?.value(forHTTPHeaderField: "Retry-After"))
            } catch let e as EmbeddingError {
                throw e
            } catch {
                // URLSession 网络错误（超时/连接中断）——重试
                if attempt >= Self.maxAttempts { throw error }
                lastErr = error
                try await Self.sleep(attempt: attempt, retryAfter: nil)
            }
        }
        if data.isEmpty, let lastErr { throw lastErr }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else {
            throw EmbeddingError.parse(String(data: data, encoding: .utf8) ?? "")
        }
        let sorted = arr.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return try sorted.map { item in
            guard let e = item["embedding"] as? [Any] else { throw EmbeddingError.parse("缺 embedding 字段") }
            return e.map { Float(($0 as? NSNumber)?.doubleValue ?? 0) }
        }
    }

    /// 退避等待：有 Retry-After（秒）就用它，否则 1s→2s→4s→8s 指数退避 + 抖动，上限 30s。
    private static func sleep(attempt: Int, retryAfter: String?) async throws {
        var seconds: Double
        if let ra = retryAfter, let v = Double(ra.trimmingCharacters(in: .whitespaces)) {
            seconds = v
        } else {
            seconds = pow(2.0, Double(attempt - 1)) + Double.random(in: 0...0.5)
        }
        seconds = min(seconds, 30)
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
