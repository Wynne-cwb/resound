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
    public var answerModel: String
    public var summaryModel: String   // 摘要模型（SUMMARY_MODEL，缺省同 answerModel）
    public var transcribeModel: String // 转写模型（TRANSCRIBE_MODEL）；在线走 aihubmix /audio/transcriptions
    public var transcribeOnline: Bool  // true=在线 turbo（默认），false=本地 WhisperKit
    public var speakerModel: String?   // 声纹模型 .onnx 路径（SPEAKER_MODEL）；缺省则索引不做说话人标注
    public var vaultPath: String?      // vault 根目录（VAULT_PATH）；App 录音入库用

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
            contextModel: v("CONTEXT_MODEL") ?? "deepseek-v4-flash",
            answerModel: v("ANSWER_MODEL") ?? "deepseek-v4-pro",
            summaryModel: v("SUMMARY_MODEL") ?? v("ANSWER_MODEL") ?? "deepseek-v4-pro",
            transcribeModel: v("TRANSCRIBE_MODEL") ?? "whisper-large-v3-turbo",
            transcribeOnline: (v("TRANSCRIBE_ONLINE") ?? "true").lowercased() != "false",
            speakerModel: v("SPEAKER_MODEL"),
            vaultPath: v("VAULT_PATH")
        )
    }
}

public enum ConfigError: Error, CustomStringConvertible {
    case missing(String)
    public var description: String {
        switch self { case .missing(let k): return "缺少配置 \(k)（检查 repo 根的 .env）" }
    }
}

/// 找 .env：① 环境变量 RESOUND_ENV 指定的文件 ② ~/Library/Application Support/Resound/.env
/// ③ 从 cwd 向上 5 层。App(.app 启动 cwd=/)走①②，CLI 走③。
func loadDotEnv() -> [String: String] {
    if let p = ProcessInfo.processInfo.environment["RESOUND_ENV"],
       let s = try? String(contentsOf: URL(fileURLWithPath: p), encoding: .utf8) {
        return parseEnv(s)
    }
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Resound/.env")
    if let s = try? String(contentsOf: appSupport, encoding: .utf8) { return parseEnv(s) }

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
