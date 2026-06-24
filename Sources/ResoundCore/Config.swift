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
    public var transcribeModel: String // 转写模型（TRANSCRIBE_MODEL）；在线走 OpenAI 兼容 /audio/transcriptions
    public var transcribeOnline: Bool  // true=在线 turbo（默认），false=本地 WhisperKit
    public var transcribeBaseURL: String // 在线转写端点（TRANSCRIBE_BASE_URL，缺省同 embedding）
    public var transcribeKey: String     // 在线转写 key（TRANSCRIBE_API_KEY，缺省同 embedding）
    public var correctModel: String    // 转录 AI 校对模型（CORRECT_MODEL，缺省 deepseek-v4-flash）
    public var transcribeCorrect: Bool // true=转录后跑一轮 LLM 校对纠错（默认开）
    public var speakerModel: String?   // 声纹模型 .onnx 路径（SPEAKER_MODEL）；缺省则索引不做说话人标注
    public var vaultPath: String?      // vault 根目录（VAULT_PATH）；App 录音入库用
    public var vaultAutoPush: Bool     // vault 是 git repo 时，处理完自动 commit+push 文本（VAULT_AUTOPUSH，默认关）

    public static func load() throws -> Config {
        let env = loadDotEnv()
        // 优先用 GUI 的 providers.json（chat+embedding 配齐时）；否则回退旧 .env（CLI / dev）。
        if let pc = ProvidersStore.load(), pc.isComplete, let resolved = pc.toConfig(env: env) {
            return resolved
        }
        return try loadFromEnv(env)
    }

    private static func loadFromEnv(_ env: [String: String]) throws -> Config {
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
            transcribeBaseURL: v("TRANSCRIBE_BASE_URL") ?? v("AIHUBMIX_BASE_URL") ?? "https://aihubmix.com/v1",
            transcribeKey: v("TRANSCRIBE_API_KEY") ?? v("AIHUBMIX_API_KEY") ?? "",
            correctModel: v("CORRECT_MODEL") ?? "deepseek-v4-flash",
            transcribeCorrect: (v("TRANSCRIBE_CORRECT") ?? "true").lowercased() != "false",
            speakerModel: v("SPEAKER_MODEL"),
            vaultPath: v("VAULT_PATH"),
            vaultAutoPush: (v("VAULT_AUTOPUSH") ?? "false").lowercased() == "true"
        )
    }
}

/// 读写 App Support 的 `.env`（设置页可改、运行时即时生效，无需重新 build），并支持导入/导出。
/// 设计：设置页只「合并」改动的键，保留其余既有键；空值=删除该键。
public enum ConfigStore {
    public static func envURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Resound/.env")
    }

    /// 当前生效的 env（App Support / RESOUND_ENV / cwd 向上），不抛错，供设置页回填。
    public static func current() -> [String: String] { loadDotEnv() }

    private static func quoted(_ v: String) -> String {
        (v.contains(" ") || v.contains("#") || v.isEmpty) ? "\"\(v)\"" : v
    }

    /// 把改动合并写回 App Support `.env`（key→value；value 为 nil/"" 表示删除该键）。
    public static func save(_ updates: [String: String?]) throws {
        let url = envURL()
        var dict = (try? String(contentsOf: url, encoding: .utf8)).map(parseEnv) ?? [:]
        for (k, v) in updates {
            if let v, !v.isEmpty { dict[k] = v } else { dict.removeValue(forKey: k) }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let body = dict.sorted { $0.key < $1.key }.map { "\($0.key)=\(quoted($0.value))" }.joined(separator: "\n") + "\n"
        try body.data(using: .utf8)!.write(to: url)
    }

    /// 导出当前生效配置到指定文件（.env 文本，含密钥——作为本机备份/迁移用）。
    public static func export(to url: URL) throws {
        let dict = current()
        let body = dict.sorted { $0.key < $1.key }.map { "\($0.key)=\(quoted($0.value))" }.joined(separator: "\n") + "\n"
        try body.data(using: .utf8)!.write(to: url)
    }

    /// 从 .env 文件导入并合并进 App Support `.env`。返回导入的键数。
    @discardableResult
    public static func importFrom(_ url: URL) throws -> Int {
        let s = try String(contentsOf: url, encoding: .utf8)
        let incoming = parseEnv(s)
        try save(incoming.mapValues { Optional($0) })
        return incoming.count
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
