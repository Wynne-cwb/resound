import ArgumentParser
import Foundation
import ResoundCore

@main
struct Resound: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resound",
        abstract: "Resound — 录音 → 转录 → 按数据契约写入 vault",
        subcommands: [Transcribe.self, Record.self, Normalize.self, IndexCommand.self, Search.self, Ask.self, Doctor.self]
    )
}

/// resound normalize --vault <path> —— 对已有转录重做繁→简归一 + 别名纠正
struct Normalize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "对 vault 内已有 transcript.json 重做繁→简归一+别名纠正")

    @Option(name: .long, help: "vault 根目录")
    var vault: String

    func run() async throws {
        let n = try IngestPipeline(vaultRoot: URL(fileURLWithPath: vault)).normalizeExisting()
        print("✅ 归一 \(n) 个 transcript（记得重建索引 resound index）")
    }
}

/// resound ask "<问题>" —— 检索 + LLM 综合，给带引用的答案
struct Ask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "问答：检索 + 重排 + LLM 综合，输出带引用的答案")

    @Argument(help: "问题")
    var query: String

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    @Option(name: .long, help: "喂给综合的片段数")
    var k: Int = 8

    @Option(name: .long, help: "综合模型（默认 .env 的 ANSWER_MODEL=pro）")
    var answerModel: String?

    func run() async throws {
        let cfg = try Config.load()
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        let pipeline = IndexPipeline(config: cfg)
        let hits = try await pipeline.search(query: query, indexPath: indexURL, topK: k, rerank: true)
        guard !hits.isEmpty else { print("无结果"); return }

        let chat = ChatClient(config: cfg, modelOverride: answerModel ?? cfg.answerModel)
        let answer = try await Synthesizer(chat: chat).answer(query: query, hits: hits)
        print(answer)
        print("\n— 来源 —")
        for (i, h) in hits.enumerated() {
            print("[\(i + 1)] \(h.recordingId) @\(Int(h.start))-\(Int(h.end))s")
        }
    }
}

/// resound index --vault <path> —— 从 vault 重建检索索引
struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "index", abstract: "从 vault 重建检索索引（切块 → embedding → SQLite/FTS5/vec）")

    @Option(name: .long, help: "vault 根目录")
    var vault: String

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "contextual 增强（默认开，--no-context 关）")
    var context = true

    @Option(name: .long, help: "上下文生成模型（默认 .env 的 CONTEXT_MODEL=flash）")
    var contextModel: String?

    func run() async throws {
        let cfg = try Config.load()
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        try await IndexPipeline(config: cfg).build(
            vaultRoot: URL(fileURLWithPath: vault), indexPath: indexURL,
            enrichContext: context, contextModel: contextModel)
    }
}

/// resound search "<query>" —— hybrid 检索（FTS5 + 向量 + RRF）
struct Search: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "hybrid 检索：FTS5 关键词 + 向量 + RRF 融合")

    @Argument(help: "查询语句")
    var query: String

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    @Option(name: .long, help: "返回条数")
    var k: Int = 5

    @Flag(name: .long, inversion: .prefixedNo, help: "LLM 重排（默认开，--no-rerank 关）")
    var rerank = true

    @Option(name: .long, help: "重排模型（默认 .env 的 RERANK_MODEL=flash；A/B 时可填 deepseek-v4-pro）")
    var rerankModel: String?

    func run() async throws {
        let cfg = try Config.load()
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        let hits = try await IndexPipeline(config: cfg).search(
            query: query, indexPath: indexURL, topK: k,
            rerank: rerank, rerankModel: rerankModel)
        if hits.isEmpty { print("无结果"); return }
        for (i, h) in hits.enumerated() {
            let ts = String(format: "%.0f-%.0fs", h.start, h.end)
            print("\n[\(i + 1)] \(h.recordingId) @\(ts)")
            print("    \(h.text.prefix(160))")
        }
    }
}

/// resound doctor —— 检查关键依赖（先验证 sqlite-vec）
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "自检：sqlite-vec 等关键依赖是否正常"
    )

    func run() async throws {
        print(try sqliteVecSmokeTest())
    }
}

/// resound transcribe <audio> --vault <path> [...]
struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "把已有音频文件转录并写入 vault"
    )

    @Argument(help: "音频文件路径（任意 AVFoundation 可读格式）")
    var audio: String

    @Option(name: .long, help: "vault 根目录")
    var vault: String

    @Option(name: .long, help: "标题（默认取文件名）")
    var title: String?

    @Option(name: .long, help: "来源类型：meeting/memo/call/lecture…")
    var source: String = "memo"

    @Option(name: .long, parsing: .upToNextOption, help: "标签，空格分隔")
    var tags: [String] = []

    @Option(name: .long, help: "WhisperKit 模型")
    var model: String = "large-v3"

    @Option(name: .long, help: "语言代码（如 zh / en），留空自动检测；中英混杂建议填 zh")
    var language: String?

    @Option(name: .long, parsing: .upToNextOption, help: "临时词表偏置词（叠加 vault 的 glossary.txt）")
    var hint: [String] = []

    @Option(name: .long, help: "温度回退次数（默认 5；调低提速、质量略降）")
    var maxFallback: Int = 5

    @Flag(name: .long, help: "完成后 git commit + push 回 vault")
    var push = false

    func run() async throws {
        let out = try await IngestPipeline(vaultRoot: URL(fileURLWithPath: vault))
            .ingest(
                audioPath: URL(fileURLWithPath: audio),
                title: title,
                source: source,
                tags: tags,
                model: model,
                language: language,
                hints: hint,
                maxFallback: maxFallback,
                push: push
            )
        print("✅ 完成：\(out.id)")
    }
}

/// resound record --vault <path> [...]
struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "从麦克风录音，然后转录并写入 vault"
    )

    @Option(name: .long, help: "vault 根目录")
    var vault: String

    @Option(name: .long, help: "标题")
    var title: String?

    @Option(name: .long, help: "来源类型")
    var source: String = "memo"

    @Option(name: .long, parsing: .upToNextOption, help: "标签")
    var tags: [String] = []

    @Option(name: .long, help: "WhisperKit 模型")
    var model: String = "large-v3"

    @Option(name: .long, help: "最长录音秒数（默认无限，按 Enter 停止）")
    var maxSeconds: Double?

    @Option(name: .long, help: "语言代码（如 zh / en），留空自动检测")
    var language: String?

    @Option(name: .long, parsing: .upToNextOption, help: "临时词表偏置词（叠加 vault 的 glossary.txt）")
    var hint: [String] = []

    @Flag(name: .long, help: "完成后 git commit + push 回 vault")
    var push = false

    func run() async throws {
        let audioURL = try await Recorder().record(maxSeconds: maxSeconds)
        let out = try await IngestPipeline(vaultRoot: URL(fileURLWithPath: vault))
            .ingest(
                audioPath: audioURL,
                title: title,
                source: source,
                tags: tags,
                model: model,
                language: language,
                hints: hint,
                push: push
            )
        print("✅ 完成：\(out.id)")
    }
}
