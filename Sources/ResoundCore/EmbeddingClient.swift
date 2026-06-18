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

    private func embed(_ inputs: [String]) async throws -> [[Float]] {
        var req = URLRequest(url: URL(string: baseURL + "/embeddings")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": inputs])

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            throw EmbeddingError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
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
}
