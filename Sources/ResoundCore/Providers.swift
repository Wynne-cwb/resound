import Foundation

/// 一个 OpenAI 兼容的 AI 服务端点（OpenAI / DeepSeek / OpenRouter / 自建 / AIHUBMIX …）。
/// 开源后用户在设置里增删 Provider，再把 chat / embedding / 转写三种能力指派给某 Provider 的某模型。
public struct AIProvider: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String          // 展示名，如 "OpenAI"、"我的 AIHUBMIX"
    public var baseURL: String       // 形如 https://api.openai.com/v1（不含末尾 /chat/completions）
    public var apiKey: String        // 本地明文存 App Support；本地软件、用户自管
    public var presetId: String?     // 来自哪个预设（用于图标/默认值）；nil = 完全自定义

    public init(id: String, name: String, baseURL: String, apiKey: String, presetId: String? = nil) {
        self.id = id; self.name = name; self.baseURL = baseURL; self.apiKey = apiKey; self.presetId = presetId
    }
}

/// 「某 Provider 的某模型」——能力指派的指针。
public struct ModelRef: Codable, Equatable, Sendable {
    public var providerId: String
    public var model: String
    public init(providerId: String, model: String) { self.providerId = providerId; self.model = model }
}

/// Provider 全量配置（GUI 真源，存 App Support `providers.json`）。
/// chat + embedding 为必填；transcribe 为空 = 兜底本地 WhisperKit。
public struct ProvidersConfig: Codable, Equatable, Sendable {
    public var providers: [AIProvider]
    public var chat: ModelRef?
    public var embedding: ModelRef?
    public var embeddingDim: Int?            // 验证 embedding 时自动探测，建索引用
    public var transcribe: ModelRef?         // nil = 本地 WhisperKit
    // 高级（可选）：成本敏感的辅助角色可单独指模型，缺省全部回退到 chat.model
    public var rerankModel: String?
    public var contextModel: String?
    public var summaryModel: String?
    public var correctModel: String?

    public init(providers: [AIProvider] = [], chat: ModelRef? = nil, embedding: ModelRef? = nil,
                embeddingDim: Int? = nil, transcribe: ModelRef? = nil,
                rerankModel: String? = nil, contextModel: String? = nil,
                summaryModel: String? = nil, correctModel: String? = nil) {
        self.providers = providers; self.chat = chat; self.embedding = embedding
        self.embeddingDim = embeddingDim; self.transcribe = transcribe
        self.rerankModel = rerankModel; self.contextModel = contextModel
        self.summaryModel = summaryModel; self.correctModel = correctModel
    }

    public func provider(_ id: String) -> AIProvider? { providers.first { $0.id == id } }

    /// chat + embedding 都指到一个存在的 Provider 才算配齐（可被 `Config.load()` 解析）。
    public var isComplete: Bool {
        guard let c = chat, let e = embedding else { return false }
        return provider(c.providerId) != nil && provider(e.providerId) != nil
    }

    /// 把 provider 指派解析成运行时 `Config`。非 provider 项（vault/词表模型等）从既有 .env 取。
    public func toConfig(env: [String: String]) -> Config? {
        guard let c = chat, let cp = provider(c.providerId),
              let e = embedding, let ep = provider(e.providerId) else { return nil }
        func envv(_ k: String) -> String? { let x = env[k]; return (x?.isEmpty == false) ? x : nil }
        let chatModel = c.model
        let tp = transcribe.flatMap { provider($0.providerId) }
        return Config(
            embeddingBaseURL: ep.baseURL,
            embeddingKey: ep.apiKey,
            embeddingModel: e.model,
            embeddingDim: embeddingDim ?? Int(envv("EMBEDDING_DIM") ?? "") ?? 4096,
            chatBaseURL: cp.baseURL,
            chatKey: cp.apiKey,
            chatModel: chatModel,
            rerankModel: rerankModel ?? chatModel,
            contextModel: contextModel ?? chatModel,
            answerModel: chatModel,
            summaryModel: summaryModel ?? chatModel,
            transcribeModel: transcribe?.model ?? "whisper-large-v3-turbo",
            transcribeOnline: transcribe != nil,
            transcribeBaseURL: tp?.baseURL ?? ep.baseURL,
            transcribeKey: tp?.apiKey ?? ep.apiKey,
            correctModel: correctModel ?? chatModel,
            transcribeCorrect: (envv("TRANSCRIBE_CORRECT") ?? "true").lowercased() != "false",
            speakerModel: envv("SPEAKER_MODEL"),
            vaultPath: envv("VAULT_PATH"),
            vaultAutoPush: (envv("VAULT_AUTOPUSH") ?? "false").lowercased() == "true"
        )
    }
}

/// 读写 App Support `providers.json`。
public enum ProvidersStore {
    public static func url() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Resound/providers.json")
    }

    public static func load() -> ProvidersConfig? {
        guard let data = try? Data(contentsOf: url()) else { return nil }
        return try? JSONDecoder().decode(ProvidersConfig.self, from: data)
    }

    public static func save(_ cfg: ProvidersConfig) throws {
        let u = url()
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(cfg).write(to: u)
    }

    /// 旧 `.env`（个人/CLI 既有配置）→ `providers.json` 一次性迁移：仅当 providers.json 不存在
    /// 且 .env 里已有 chat+embedding key 时执行，保证老用户升级后零感知、不弹引导。返回是否迁移了。
    @discardableResult
    public static func migrateFromEnvIfNeeded() -> Bool {
        guard load() == nil else { return false }
        let env = loadDotEnv()
        func g(_ k: String) -> String? { let x = env[k]; return (x?.isEmpty == false) ? x : nil }
        guard let chatKey = g("CHAT_API_KEY"), let embKey = g("AIHUBMIX_API_KEY") else { return false }

        let chatBase = g("CHAT_BASE_URL") ?? "https://api.deepseek.com/v1"
        let embBase = g("AIHUBMIX_BASE_URL") ?? "https://aihubmix.com/v1"
        let chatProvider = AIProvider(id: "p-chat", name: presetName(forBaseURL: chatBase) ?? "Chat",
                                      baseURL: chatBase, apiKey: chatKey, presetId: presetId(forBaseURL: chatBase))
        let embProvider = AIProvider(id: "p-embed", name: presetName(forBaseURL: embBase) ?? "Embedding",
                                     baseURL: embBase, apiKey: embKey, presetId: presetId(forBaseURL: embBase))
        var providers = [chatProvider, embProvider]

        var transcribe: ModelRef?
        let online = (g("TRANSCRIBE_ONLINE") ?? "true").lowercased() != "false"
        if online {
            // 每个能力独立一条 provider 记录（不共享），便于设置页按能力各自编辑互不干扰。
            let tBase = g("TRANSCRIBE_BASE_URL") ?? embBase
            let tKey = g("TRANSCRIBE_API_KEY") ?? embKey
            let tModel = g("TRANSCRIBE_MODEL") ?? "whisper-large-v3-turbo"
            let tp = AIProvider(id: "p-transcribe", name: presetName(forBaseURL: tBase) ?? "Transcribe",
                                baseURL: tBase, apiKey: tKey, presetId: presetId(forBaseURL: tBase))
            providers.append(tp)
            transcribe = ModelRef(providerId: tp.id, model: tModel)
        }

        let cfg = ProvidersConfig(
            providers: providers,
            chat: ModelRef(providerId: chatProvider.id, model: g("CHAT_MODEL") ?? "deepseek-v4-pro"),
            embedding: ModelRef(providerId: embProvider.id, model: g("EMBEDDING_MODEL") ?? "qwen3-embedding-8b"),
            embeddingDim: Int(g("EMBEDDING_DIM") ?? ""),
            transcribe: transcribe,
            // 精确保留旧 loadFromEnv 的默认（rerank/context/correct 缺省都是 flash），零行为变更
            rerankModel: g("RERANK_MODEL") ?? "deepseek-v4-flash",
            contextModel: g("CONTEXT_MODEL") ?? "deepseek-v4-flash",
            summaryModel: g("SUMMARY_MODEL"),   // nil → toConfig 回退 chat.model（旧默认即 ANSWER_MODEL=pro）
            correctModel: g("CORRECT_MODEL") ?? "deepseek-v4-flash")
        do { try save(cfg); return true } catch { return false }
    }

    private static func presetId(forBaseURL u: String) -> String? {
        ProviderPreset.all.first { u.hasPrefix($0.baseURL) || $0.baseURL.hasPrefix(u) }?.id
    }
    private static func presetName(forBaseURL u: String) -> String? {
        presetId(forBaseURL: u).flatMap { id in ProviderPreset.all.first { $0.id == id }?.name }
    }
}

/// 内置 Provider 预设：选中即填好 baseURL + 建议模型 + 取 key 的链接。全部走 OpenAI 兼容协议。
public struct ProviderPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let needsKey: Bool
    public let chatModels: [String]
    public let embeddingModels: [String]
    public let transcribeModels: [String]
    public let keysURL: String?      // 去哪儿拿 API Key

    // 模型名为「建议」（可自由改写），按 2026-06 各家最新整理。
    public static let all: [ProviderPreset] = [
        ProviderPreset(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1", needsKey: true,
            chatModels: ["gpt-5.5", "gpt-5.4-mini", "gpt-5-mini"],
            embeddingModels: ["text-embedding-3-large", "text-embedding-3-small"],
            transcribeModels: ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"],
            keysURL: "https://platform.openai.com/api-keys"),
        ProviderPreset(id: "anthropic", name: "Claude", baseURL: "https://api.anthropic.com/v1", needsKey: true,
            chatModels: ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"],
            embeddingModels: [], transcribeModels: [],
            keysURL: "https://console.anthropic.com/settings/keys"),
        ProviderPreset(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", needsKey: true,
            chatModels: ["deepseek-v4-pro", "deepseek-v4-flash"],
            embeddingModels: [], transcribeModels: [],
            keysURL: "https://platform.deepseek.com/api_keys"),
        ProviderPreset(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1", needsKey: true,
            chatModels: ["openai/gpt-oss-120b", "openai/gpt-oss-20b"],
            embeddingModels: [], transcribeModels: ["whisper-large-v3-turbo", "whisper-large-v3"],
            keysURL: "https://console.groq.com/keys"),
        ProviderPreset(id: "aihubmix", name: "AIHUBMIX", baseURL: "https://aihubmix.com/v1", needsKey: true,
            chatModels: ["deepseek-v4-pro", "gpt-5.5", "claude-opus-4-8"],
            embeddingModels: ["qwen3-embedding-8b", "text-embedding-3-large"],
            transcribeModels: ["whisper-large-v3-turbo"],
            keysURL: "https://aihubmix.com/token"),
        ProviderPreset(id: "ollama", name: "Ollama（本地）", baseURL: "http://localhost:11434/v1", needsKey: false,
            chatModels: ["llama3.3", "qwen3", "gemma3"],
            embeddingModels: ["nomic-embed-text", "bge-m3", "qwen3-embedding"], transcribeModels: [],
            keysURL: "https://ollama.com/download"),
    ]
}
