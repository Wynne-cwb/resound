import Foundation

/// 从 .env（或进程环境变量）读取 embedding / chat 两套 OpenAI 兼容配置。
public struct Config {
    public var embeddingBaseURL: String
    public var embeddingKey: String
    public var embeddingModel: String
    public var embeddingDim: Int
    public var chatBaseURL: String
    public var chatKey: String
    public var chatModel: String
    public var rerankModel: String
    public var contextModel: String

    public static func load() throws -> Config {
        let env = loadDotEnv()
        func v(_ k: String) -> String? {
            if let p = ProcessInfo.processInfo.environment[k], !p.isEmpty { return p }
            return env[k]
        }
        func req(_ k: String) throws -> String {
            guard let x = v(k), !x.isEmpty else { throw ConfigError.missing(k) }
            return x
        }
        return Config(
            embeddingBaseURL: v("AIHUBMIX_BASE_URL") ?? "https://aihubmix.com/v1",
            embeddingKey: try req("AIHUBMIX_API_KEY"),
            embeddingModel: v("EMBEDDING_MODEL") ?? "qwen3-embedding-8b",
            embeddingDim: Int(v("EMBEDDING_DIM") ?? "4096") ?? 4096,
            chatBaseURL: v("CHAT_BASE_URL") ?? "https://api.deepseek.com/v1",
            chatKey: try req("CHAT_API_KEY"),
            chatModel: v("CHAT_MODEL") ?? "deepseek-v4-pro",
            rerankModel: v("RERANK_MODEL") ?? "deepseek-v4-flash",
            contextModel: v("CONTEXT_MODEL") ?? "deepseek-v4-flash"
        )
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case missing(String)
    public var description: String {
        switch self { case .missing(let k): return "缺少配置 \(k)（检查 repo 根的 .env）" }
    }
}

/// 从 cwd 向上找 .env，解析 KEY=VALUE。
func loadDotEnv() -> [String: String] {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<5 {
        let f = dir.appendingPathComponent(".env")
        if let s = try? String(contentsOf: f, encoding: .utf8) { return parseEnv(s) }
        dir.deleteLastPathComponent()
    }
    return [:]
}

func parseEnv(_ s: String) -> [String: String] {
    var d: [String: String] = [:]
    for line in s.split(whereSeparator: \.isNewline) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("#") { continue }
        guard let eq = t.firstIndex(of: "=") else { continue }
        let k = t[..<eq].trimmingCharacters(in: .whitespaces)
        var val = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if val.count >= 2, val.hasPrefix("\""), val.hasSuffix("\"") {
            val = String(val.dropFirst().dropLast())
        }
        d[k] = val
    }
    return d
}
