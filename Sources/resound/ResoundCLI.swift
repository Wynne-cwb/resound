import ArgumentParser
import Foundation
import ResoundCore

@main
struct Resound: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resound",
        abstract: "Resound — 录音 → 转录 → 按数据契约写入 vault",
        subcommands: [Transcribe.self, Record.self, Diarize.self, DiarizeEval.self, SpeakerEval.self, SpeakerCluster.self, SpeakerEnroll.self, SpeakerRecognize.self, SpeakerLabel.self, Normalize.self, IndexCommand.self, Search.self, Ask.self, Doctor.self]
    )
}

/// resound diarize <audio> —— Phase A 冒烟：跑 FluidAudio diarization 看分段
struct Diarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "diarize", abstract: "（冒烟）对音频跑说话人分割，输出分段")

    @Argument(help: "音频文件路径")
    var audio: String

    @Option(name: .long, help: "后端：sortformer / manager")
    var backend: String = "sortformer"

    @Option(name: .long, help: "聚类阈值（manager 用，越高人越少）")
    var threshold: Float = 0.7

    func run() async throws {
        let b = DiarBackend(rawValue: backend) ?? .sortformer
        print(try await diarizeSmoke(audio: URL(fileURLWithPath: audio), backend: b, threshold: threshold))
    }
}

/// resound diarize-eval <audio> <transcript.txt> —— 用 ground truth 评测 diarization
struct DiarizeEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "diarize-eval", abstract: "用带说话人的转录评测 diarization 准确率")

    @Argument(help: "音频文件")
    var audio: String

    @Argument(help: "ground-truth 转录（HH:MM:SS 说话人 格式）")
    var transcript: String

    @Option(name: .long, help: "后端：sortformer / manager")
    var backend: String = "sortformer"

    @Option(name: .long, help: "聚类阈值（manager 用）")
    var threshold: Float = 0.7

    func run() async throws {
        let b = DiarBackend(rawValue: backend) ?? .sortformer
        print(try await diarizeEval(
            audio: URL(fileURLWithPath: audio),
            transcript: URL(fileURLWithPath: transcript),
            backend: b, threshold: threshold))
    }
}

/// resound speaker-eval <audio> <asr.json> <gt.txt> —— 注册式说话人识别评测
struct SpeakerEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "speaker-eval",
        abstract: "注册式说话人识别评测：ASR 边界合并→声纹注册匹配，对 ground truth 算准确率")

    @Argument(help: "音频文件")
    var audio: String

    @Argument(help: "ASR transcript.json（提供分段边界）")
    var asr: String

    @Argument(help: "ground-truth 转录（HH:MM:SS 说话人 格式）")
    var groundTruth: String

    @Option(name: .long, help: "声纹模型 .onnx 路径（CAM++ zh-en advanced）")
    var model: String

    @Option(name: .long, help: "声纹窗口最小时长秒（默认 4）")
    var targetDur: Double = 4.0

    @Option(name: .long, help: "每人注册窗口数（默认 3）")
    var enroll: Int = 3

    func run() async throws {
        print(try await speakerIDEval(
            audio: URL(fileURLWithPath: audio),
            asrJSON: URL(fileURLWithPath: asr),
            groundTruth: URL(fileURLWithPath: groundTruth),
            model: model, targetDur: targetDur, enrollPerSpeaker: enroll))
    }
}

/// resound speaker-cluster —— 冷启动自动分堆（不需预先注册）；带 --ground-truth 则跑闭环评测
struct SpeakerCluster: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "speaker-cluster",
        abstract: "冷启动：把录音自动分成匿名说话人堆（供命名）；带 --ground-truth 跑命名K vs 准确率评测")

    @Argument(help: "音频文件")
    var audio: String

    @Argument(help: "ASR transcript.json")
    var asr: String

    @Option(name: .long, help: "声纹模型 .onnx 路径")
    var model: String

    @Option(name: .long, help: "在线分堆阈值（默认 0.5，越高分越细）")
    var clusterTh: Float = 0.5

    @Option(name: .long, help: "（评测用）ground-truth 转录，提供则跑命名K vs 准确率闭环评测")
    var groundTruth: String?

    @Option(name: .long, help: "（评测用）小堆归并阈值（默认 0.45）")
    var absorbTh: Float = 0.45

    func run() async throws {
        if let gt = groundTruth {
            print(try await coldStartEval(
                audio: URL(fileURLWithPath: audio), asrJSON: URL(fileURLWithPath: asr),
                groundTruth: URL(fileURLWithPath: gt), model: model,
                clusterTh: clusterTh, absorbTh: absorbTh))
            return
        }
        let (clusters, _) = try await clusterRecording(
            audio: URL(fileURLWithPath: audio), asrJSON: URL(fileURLWithPath: asr),
            model: model, clusterThreshold: clusterTh)
        print("自动分出 \(clusters.count) 个说话人堆（按时长排序，命名大的优先）：")
        for (i, c) in clusters.prefix(15).enumerated() {
            print(String(format: "  堆%-2d: %3d 窗, 共 %4.0fs, 样例试听 @%.0f-%.0fs",
                         i + 1, c.count, c.totalDur, c.sampleStart, c.sampleEnd))
        }
    }
}

/// resound speaker-enroll —— 从标注音频注册声纹（跨录音重复调用累积变准）
struct SpeakerEnroll: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "speaker-enroll",
        abstract: "从标注转录(HH:MM:SS 说话人)注册声纹，增量累积。--index 写检索索引（产品路径）/ --store 写 JSON（实验）")

    @Argument(help: "音频文件")
    var audio: String

    @Argument(help: "标注转录(HH:MM:SS 说话人 格式)")
    var labels: String

    @Option(name: .long, help: "写入检索索引的声纹库（默认 App Support）；与 --store 二选一")
    var index: String?

    @Option(name: .long, help: "写入 JSON 声纹库（实验用）；与 --index 二选一")
    var store: String?

    @Option(name: .long, help: "声纹模型 .onnx 路径（默认 .env 的 SPEAKER_MODEL）")
    var model: String?

    @Option(name: .long, help: "每人取最长几条轮次窗口（默认 5）")
    var per: Int = 5

    func run() async throws {
        let cfg = try Config.load()
        guard let spk = model ?? cfg.speakerModel else {
            throw ConfigError.missing("SPEAKER_MODEL（或用 --model 指定声纹模型路径）")
        }
        if let store {
            print(try await enrollFromLabeled(
                audio: URL(fileURLWithPath: audio), labels: URL(fileURLWithPath: labels),
                store: URL(fileURLWithPath: store), model: spk, per: per))
        } else {
            let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
            print(try await enrollToIndex(
                audio: URL(fileURLWithPath: audio), labels: URL(fileURLWithPath: labels),
                indexPath: indexURL, embeddingDim: cfg.embeddingDim, model: spk, per: per))
        }
    }
}

/// resound speaker-recognize —— 用声纹库给录音的 ASR 段打说话人标签
struct SpeakerRecognize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "speaker-recognize",
        abstract: "用声纹库识别一段录音的说话人（ASR 段→合并→提声纹→匹配）")

    @Argument(help: "音频文件")
    var audio: String

    @Argument(help: "ASR transcript.json")
    var asr: String

    @Option(name: .long, help: "声纹库 JSON 路径")
    var store: String

    @Option(name: .long, help: "声纹模型 .onnx 路径")
    var model: String

    @Option(name: .long, help: "开集拒识阈值 τ_abs（默认 0.35）")
    var tau: Float = 0.35

    @Option(name: .long, help: "相对 margin 门 s1-s2（默认 0）")
    var margin: Float = 0.0

    func run() async throws {
        print(try await recognizeWithStore(
            audio: URL(fileURLWithPath: audio), asrJSON: URL(fileURLWithPath: asr),
            store: URL(fileURLWithPath: store), model: model, tauAbs: tau, tauMargin: margin))
    }
}

/// resound speaker-label —— 用声纹库给已建好的索引就地填 person_id（不重嵌入）
struct SpeakerLabel: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "speaker-label",
        abstract: "用声纹库给已有索引就地打说话人标签（注册新声纹后调用，免重建索引）")

    @Option(name: .long, help: "vault 根目录（取音频/转录）")
    var vault: String

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    func run() async throws {
        let cfg = try Config.load()
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        try await IndexPipeline(config: cfg).labelExisting(
            vaultRoot: URL(fileURLWithPath: vault), indexPath: indexURL)
    }
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
            let who = h.personId.map { " 👤\($0)" } ?? ""
            print("[\(i + 1)] \(h.recordingId) @\(Int(h.start))-\(Int(h.end))s\(who)")
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
            let who = h.personId.map { " 👤\($0)" } ?? ""
            print("\n[\(i + 1)] \(h.recordingId) @\(ts)\(who)")
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
