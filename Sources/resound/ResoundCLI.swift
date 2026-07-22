import ArgumentParser
import Foundation
import ResoundCore

@main
struct Resound: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resound",
        abstract: "Resound — 录音 → 转录 → 按数据契约写入 vault",
        subcommands: [Transcribe.self, Retranscribe.self, Record.self, RecordMeeting.self, WatchMeet.self, Diarize.self, DiarizeEval.self, SpeakerEval.self, SpeakerCluster.self, SpeakerEnroll.self, SpeakerRecognize.self, SpeakerLabel.self, SpeakerIdentify.self, DiarizeCompare.self, Normalize.self, CorrectTranscript.self, Redate.self, NormalizeAudio.self, RecoverMeeting.self, SyncSpeakerNames.self, ExtractDoc.self, ImportDoc.self, RetidyDoc.self, SuggestFolder.self, SuggestTags.self, IndexCommand.self, Search.self, Ask.self, Summarize.self, Mcp.self, Doctor.self]
    )
}

/// resound retranscribe —— 原地重转录一条已入库录音（保 id/目录；换后端如迁 MOSS、或修转录质量）
struct Retranscribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "retranscribe",
        abstract: "原地重转录已入库录音（当前转写后端，如 MOSS）→ 重索引 → 说话人识别 → 重生成摘要")

    @Option(name: .long, help: "vault 根目录")
    var vault: String

    @Option(name: .long, help: "录音 id（yyyy-MM-dd-HHmm-slug）")
    var id: String

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    @Flag(name: .long, help: "跳过重生成摘要")
    var skipSummary = false

    func run() async throws {
        let cfg = try Config.load()
        let vaultURL = URL(fileURLWithPath: vault)
        guard let rec = listRecordings(vaultRoot: vaultURL).first(where: { $0.id == id }) else {
            throw ValidationError("没找到录音：\(id)")
        }
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        print("▶︎ 重转录 \(rec.title)（\(rec.id)）")
        try await IngestPipeline(vaultRoot: vaultURL).retranscribe(recDir: rec.dir)
        print("▶︎ 重建索引…")
        try await IndexPipeline(config: cfg).indexRecording(recDir: rec.dir, indexPath: indexURL, labelSpeakers: false)
        if let model = cfg.speakerModel {
            print("▶︎ 说话人识别…")
            if hasMossDiarStaging(rec.dir) {
                _ = try await nameSpeakersFromMossDiarization(rec, model: model, indexPath: indexURL, embeddingDim: cfg.embeddingDim)
            } else {
                _ = try await identifySpeakersByDiarization(rec, model: model, indexPath: indexURL, embeddingDim: cfg.embeddingDim)
            }
        }
        if !skipSummary {
            print("▶︎ 重生成摘要…")
            _ = try await IndexPipeline(config: cfg).summarizeRecording(recDir: rec.dir, indexPath: indexURL)
        }
        print("✅ 完成（App 里重开该录音即见新转录/说话人/摘要）")
    }
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

/// resound speaker-identify —— 用已注册声纹逐窗识别说话人并写 diarization.json（产品同款，可批量修复旧录音）
struct SpeakerIdentify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "speaker-identify",
        abstract: "用已注册声纹逐窗识别说话人，写 diarization.json + 同步 index 真名（注册新人后批量修复旧录音）")

    @Option(name: .long, help: "vault 根目录")
    var vault: String

    @Option(name: .long, help: "只处理这一条录音 id（缺省=全部）")
    var id: String?

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    func run() async throws {
        let cfg = try Config.load()
        guard let model = cfg.speakerModel else { throw ConfigError.missing("SPEAKER_MODEL") }
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        let recs = listRecordings(vaultRoot: URL(fileURLWithPath: vault)).filter { id == nil || $0.id == id }
        guard !recs.isEmpty else { print("没有匹配的录音"); return }
        for rec in recs {
            print("▶︎ \(rec.id)")
            if hasMossDiarStaging(rec.dir) {
                // MOSS 录音：分段已由联合模型产出，只做「标签→谁」声纹命名
                _ = try await nameSpeakersFromMossDiarization(rec, model: model, indexPath: indexURL, embeddingDim: cfg.embeddingDim)
            } else {
                _ = try await identifySpeakersByDiarization(rec, model: model, indexPath: indexURL, embeddingDim: cfg.embeddingDim)
            }
        }
        print("✅ 完成 \(recs.count) 条")
    }
}

/// resound diarize-compare —— 离线对比「旧逐窗法」vs「新 diar 优先法(+VAD)」的说话人分布（不落盘）
struct DiarizeCompare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "diarize-compare",
        abstract: "在已入库录音上对比旧逐窗识别 vs 新真-diarization 优先识别(+silero VAD)，打印说话人分布（不写盘）")

    @Option(name: .long, help: "vault 根目录")
    var vault: String

    @Option(name: .long, help: "只处理这一条录音 id（缺省=全部）")
    var id: String?

    @Option(name: .long, help: "diar 后端：offline(任意人数,默认) / sortformer(≤4) / manager")
    var backend: String = "offline"

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    func run() async throws {
        let cfg = try Config.load()
        guard let model = cfg.speakerModel else { throw ConfigError.missing("SPEAKER_MODEL") }
        let be = DiarBackend(rawValue: backend) ?? .offline
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        let recs = listRecordings(vaultRoot: URL(fileURLWithPath: vault)).filter { id == nil || $0.id == id }
        guard !recs.isEmpty else { print("没有匹配的录音"); return }
        for rec in recs {
            let report = try await diarIdCompare(rec, model: model, indexPath: indexURL,
                                                 embeddingDim: cfg.embeddingDim, backend: be)
            print(report); print("")
        }
    }
}

/// resound transcribe-correct —— 对已有 transcript.json 跑一轮 AI 校对（保持原意纠错别字/术语）
struct CorrectTranscript: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "transcribe-correct",
        abstract: "对已有转录跑一轮 AI 校对（DeepSeek，保持原意纠错别字/分词/术语）；改完记得 resound index 重建检索")

    @Option(name: .long, help: "vault 根目录")
    var vault: String

    @Option(name: .long, help: "只处理这一条录音 id（缺省=全部）")
    var id: String?

    func run() async throws {
        let (recs, segs) = try await IngestPipeline(vaultRoot: URL(fileURLWithPath: vault)).correctExisting(id: id)
        print("✅ 校对完成：\(recs) 条录音，改动 \(segs) 段（记得 resound index 重建检索）")
    }
}

/// resound redate —— 从标题解析真实会议日期，修正已有录音的 recorded_at（排序/详情/Ask 口径）。默认 dry-run。
struct Redate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "redate",
        abstract: "从标题里的日期修正已有录音的会议日期（recording.yaml + 索引，不重嵌入）。默认只预览，--apply 才落盘")

    @Option(name: .long, help: "vault 根目录（缺省取 .env 的 VAULT_PATH）")
    var vault: String?

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    @Flag(name: .long, help: "真正写入（缺省只预览将改动的录音）")
    var apply = false

    func run() async throws {
        let cfg = try? Config.load()
        guard let vaultPath = vault ?? cfg?.vaultPath, !vaultPath.isEmpty else {
            throw ConfigError.missing("vault 路径（--vault 或 .env 的 VAULT_PATH）")
        }
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        let dim = cfg?.embeddingDim ?? 4096
        let changes = redateFromTitles(vaultRoot: URL(fileURLWithPath: vaultPath),
                                       indexPath: indexURL, embeddingDim: dim, dryRun: !apply)
        if changes.isEmpty { print("没有需要修正的录音（标题无日期或日期已一致）"); return }
        print(apply ? "✏️ 已修正 \(changes.count) 条：" : "🔍 预览（\(changes.count) 条将修正，加 --apply 落盘）：")
        for c in changes {
            print("  \(String(c.old.prefix(10))) → \(String(c.new.prefix(10)))   \(c.title)")
        }
        if !apply { print("\n确认无误后重跑：resound redate --apply") }
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

    @Flag(name: .long, inversion: .prefixedNo, help: "查询规划：抽时间范围+判定汇总/问答（默认开，--no-plan 关）")
    var plan = true

    func run() async throws {
        let cfg = try Config.load()
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        let result = try await IndexPipeline(config: cfg).answer(
            question: query, indexPath: indexURL, topK: k, usePlanner: plan, answerModel: answerModel)

        // 调试 chip：让用户看见路由器怎么理解了问题（形状 / 过滤 / 近因）。
        let p = result.plan
        var chips = ["🧭 \(p.shape.rawValue)"]
        if let r = p.dateRange { chips.append("🗓 \(r.from)~\(r.to)") }
        if let sp = p.speakers, !sp.isEmpty { chips.append("👤 \(sp.joined(separator: "/"))") }
        if p.source != .both { chips.append("📂 \(p.source.rawValue)") }
        if p.recency { chips.append("🆕 近因") }
        print(chips.joined(separator: "　") + "\n")
        print(result.text)

        if !result.digestRecordings.isEmpty {
            print("\n— 涉及录音 —")
            for r in result.digestRecordings {
                print("· \(String(r.recordedAt.prefix(10))) \(r.title)（\(r.id)）\(r.summary == nil ? " ⚠️无摘要" : "")")
            }
        } else if !result.hits.isEmpty {
            print("\n— 来源 —")
            for (i, h) in result.hits.enumerated() {
                if h.isDocument {
                    print("[\(i + 1)] 📄 \(h.docTitle ?? h.docId ?? "未命名文档")")
                } else {
                    let who = h.personId.map { " 👤\($0)" } ?? ""
                    let date = h.recordingDate.map { "\($0) " } ?? ""
                    print("[\(i + 1)] 🎙️ \(date)\(h.recordingId) @\(Int(h.start))-\(Int(h.end))s\(who)")
                }
            }
        }
    }
}

/// resound summarize —— 为录音生成 AI 摘要（模板可选）
struct Summarize: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "summarize",
        abstract: "为录音生成 AI 摘要：写 summary.md + 入索引（模板见 summary-templates.json）")

    @Option(name: .long, help: "单条录音目录（含 recording.yaml）；与 --vault 二选一")
    var rec: String?

    @Option(name: .long, help: "vault 根目录：对全部录音批量摘要")
    var vault: String?

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    @Option(name: .long, help: "模板 id（general/one-on-one/team-meeting/brainstorm…默认 general）")
    var template: String?

    @Flag(name: .long, help: "已有 summary.md 也重做")
    var force = false

    func run() async throws {
        let cfg = try Config.load()
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        let pipeline = IndexPipeline(config: cfg)

        var dirs: [URL] = []
        if let rec { dirs = [URL(fileURLWithPath: rec)] }
        else if let vault { dirs = listRecordings(vaultRoot: URL(fileURLWithPath: vault)).map { $0.dir } }
        else { print("需 --rec <目录> 或 --vault <根目录>"); return }

        print("📋 模板：\(SummaryTemplateStore.template(id: template).name)　共 \(dirs.count) 条")
        for dir in dirs {
            if !force, FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.md").path) {
                print("  ⏭ 已有摘要，跳过：\(dir.lastPathComponent)（--force 重做）"); continue
            }
            do {
                _ = try await pipeline.summarizeRecording(recDir: dir, indexPath: indexURL, templateId: template)
            } catch {
                print("  ⚠️ 失败：\(dir.lastPathComponent) — \(error)")
            }
        }
        print("✅ 摘要完成")
    }
}

/// resound normalize-audio <file> —— 对音频跑分窗自适应响度归一，输出归一后 m4a 路径（无头调试）
struct NormalizeAudio: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "normalize-audio",
        abstract: "分窗自适应响度归一（调试用；与转录前归一同一实现，输出临时 m4a 路径）")

    @Argument(help: "音频文件路径")
    var file: String

    @Option(name: .long, help: "输出文件路径（默认打印临时文件路径）")
    var out: String?

    func run() async throws {
        guard let url = try await AudioNormalizer.normalizedM4A(of: URL(fileURLWithPath: file)) else {
            print("✅ 整条已够响，无需归一（转录会直接用原文件）")
            return
        }
        if let out {
            let dst = URL(fileURLWithPath: out)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: url, to: dst)
            print("✅ 已归一 → \(out)")
        } else {
            print("✅ 已归一 → \(url.path)")
        }
    }
}

/// resound extract-doc <file> —— 只解析富格式 → markdown，打印结果（无头调试，不建索引/不需配置）
struct ExtractDoc: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "extract-doc",
        abstract: "解析文档为 markdown 并打印（调试用；支持 pdf/docx/pptx/html/图片/md/txt）")

    @Argument(help: "文档文件路径")
    var file: String

    @Flag(name: .long, help: "只打印元信息（格式/字数/告警），不打印正文")
    var brief = false

    @Flag(name: .long, help: "用快速模型整理排版（仅 PDF/图片生效，需配置 chat key）")
    var tidy = false

    @Option(name: .long, help: "整理排版用的模型（默认 correctModel；调试可指定更强模型）")
    var model: String?

    func run() async throws {
        var r = extractDocument(url: URL(fileURLWithPath: file))
        if tidy {
            let before = r.markdown.count
            r = await tidiedExtraction(r, config: try? Config.load(), model: model) { print($0) }
            print("🪄 排版整理：\(before) → \(r.markdown.count) 字")
        }
        print("== 格式: \(r.sourceFormat) | 正文 \(r.markdown.count) 字 | 告警 \(r.warnings.count) 条 ==")
        for w in r.warnings { print("⚠️ \(w)") }
        if !brief {
            print("---- markdown ----")
            print(r.markdown)
        }
    }
}

/// resound import-doc <file> --vault <path> —— 导入文档并建索引（文档模块 P1）
struct ImportDoc: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "import-doc",
        abstract: "导入本地文档到 vault + 建索引（md/txt/pdf/docx/pptx/html/图片，与录音一起参与问答）")

    @Argument(help: "文档文件路径（.md/.txt/.pdf/.docx/.pptx/.html/图片）")
    var file: String

    @Option(name: .long, help: "vault 根目录")
    var vault: String

    @Option(name: .long, help: "标题（默认取文件名）")
    var title: String?

    @Option(name: .long, help: "标签，逗号分隔")
    var tags: String?

    @Option(name: .long, help: "关联录音 id（可重复 --link a --link b）")
    var link: [String] = []

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    @Flag(name: .long, inversion: .prefixedNo, help: "contextual 增强（默认开，--no-context 关）")
    var context = true

    func run() async throws {
        let cfg = try Config.load()
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        let fileURL = URL(fileURLWithPath: file)
        // PDF/图片 OCR 排版乱 → v4-flash 保语义整理（其它格式原样）
        let result = await tidiedExtraction(extractDocument(url: fileURL), config: cfg) { print($0) }
        for w in result.warnings { FileHandle.standardError.write(Data("⚠️ \(w)\n".utf8)) }
        let tagList = (tags ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let links = link.map { "recording:\($0)" }
        let titleArg = title ?? fileURL.deletingPathExtension().lastPathComponent

        let store = DocumentStore(vaultRoot: URL(fileURLWithPath: vault))
        let (manifest, dir) = try store.importDocument(
            title: titleArg, text: result.markdown, sourceFormat: result.sourceFormat,
            tags: tagList, links: links, originalFileURL: fileURL)
        print("📄 导入：\(manifest.id)（\(result.sourceFormat)，正文 \(result.markdown.count) 字）→ \(dir.path)")
        try await IndexPipeline(config: cfg).indexDocument(docDir: dir, indexPath: indexURL, enrichContext: context)
    }
}

/// resound retidy-doc <docDir> —— 对已导入文档：从 original.* 重新提取+排版整理→重写 content.md→重建该文档索引
/// （给 P3 排版整理上线前导入的旧文档补整理；只动这一篇，不碰其它）
struct RetidyDoc: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "retidy-doc",
        abstract: "重排版已导入文档（从原件重提取→LLM 整理→重写 content.md→重建索引）")

    @Argument(help: "文档目录（含 document.yaml + original.<ext>）")
    var dir: String

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    @Option(name: .long, help: "整理用模型（默认 correctModel）")
    var model: String?

    func run() async throws {
        let cfg = try Config.load()
        let docDir = URL(fileURLWithPath: dir)
        let files = (try? FileManager.default.contentsOfDirectory(at: docDir, includingPropertiesForKeys: nil)) ?? []
        guard let original = files.first(where: { $0.lastPathComponent.hasPrefix("original.") }) else {
            throw ValidationError("该目录没有 original.<ext> 原件：\(docDir.path)")
        }
        let before = (try? String(contentsOf: docDir.appendingPathComponent("content.md"), encoding: .utf8))?.count ?? 0
        let r = await tidiedExtraction(extractDocument(url: original), config: cfg, model: model) { print($0) }
        for w in r.warnings { FileHandle.standardError.write(Data("⚠️ \(w)\n".utf8)) }
        try r.markdown.data(using: .utf8)?.write(to: docDir.appendingPathComponent("content.md"))
        print("📝 content.md：\(before) → \(r.markdown.count) 字")
        try await IndexPipeline(config: cfg).indexDocument(
            docDir: docDir, indexPath: index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath())
        print("✅ 已重排版并重建索引：\(docDir.lastPathComponent)")
    }
}

/// resound suggest-folder <recDir> —— 调试：给一条录音推算文件夹建议（验证 prompt 质量）
struct SuggestFolder: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "suggest-folder",
        abstract: "调试：给一条录音推算文件夹建议（读 summary.md + 现有 library.json folders）")

    @Argument(help: "录音目录（含 recording.yaml / summary.md）")
    var recDir: String

    @Option(name: .long, help: "vault 根目录（取现有文件夹列表，默认 VAULT_PATH）")
    var vault: String?

    @Option(name: .long, help: "分类模型（默认 correctModel）")
    var model: String?

    func run() async throws {
        let cfg = try Config.load()
        let dir = URL(fileURLWithPath: recDir)
        let yaml = (try? String(contentsOf: dir.appendingPathComponent("recording.yaml"), encoding: .utf8)) ?? ""
        let title = yaml.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("title:") }
            .map { String($0.dropFirst("title:".count)).trimmingCharacters(in: .whitespaces) } ?? dir.lastPathComponent
        let summary = (try? String(contentsOf: dir.appendingPathComponent("summary.md"), encoding: .utf8)) ?? ""
        guard let vaultRoot = (vault ?? cfg.vaultPath).map({ URL(fileURLWithPath: $0) }) else {
            print("⚠️ 无 vault 路径（--vault 或 VAULT_PATH）"); return
        }
        let folders = LibraryStore.load(vaultRoot: vaultRoot).folders
        print("现有文件夹：\(folders.map { $0.name }.joined(separator: "、").ifEmpty("（无）"))")
        let s = try await AutoClassifier(config: cfg, model: model).suggestFolder(
            summary: summary, title: title, existingFolders: folders)
        switch s {
        case .some(let r) where r.existingId != nil:
            print("✅ 归入现有：\(folders.first { $0.id == r.existingId }?.name ?? r.existingId!)")
        case .some(let r) where r.newName != nil:
            print("🆕 提议新建：\(r.newName!)")
        default:
            print("— 无建议（不打扰）")
        }
    }
}

/// resound suggest-tags <docDir> —— 调试：给一篇文档推算 tag 建议（验证 prompt 质量）
struct SuggestTags: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "suggest-tags",
        abstract: "调试：给一篇文档推算 tag 建议（读 content.md + 全库现有 tags）")

    @Argument(help: "文档目录（含 document.yaml / content.md）")
    var docDir: String

    @Option(name: .long, help: "vault 根目录（取现有 tag 列表，默认 VAULT_PATH）")
    var vault: String?

    @Option(name: .long, help: "分类模型（默认 correctModel）")
    var model: String?

    func run() async throws {
        let cfg = try Config.load()
        let dir = URL(fileURLWithPath: docDir)
        let title = parseDocumentManifest(dir)?.title ?? dir.lastPathComponent
        let content = documentContent(dir) ?? ""
        let vaultRoot = (vault ?? cfg.vaultPath).map { URL(fileURLWithPath: $0) } ?? dir.deletingLastPathComponent()
        let existing = Array(Set(listDocuments(vaultRoot: vaultRoot).flatMap { $0.tags })).sorted()
        print("现有 tag：\(existing.joined(separator: "、").ifEmpty("（无）"))")
        let tags = try await AutoClassifier(config: cfg, model: model).suggestTags(
            content: content, title: title, existingTags: existing)
        if tags.isEmpty { print("— 无建议（不打扰）") }
        else { print("✅ 建议 tag：\(tags.map { $0.isNew ? "\($0.tag)(新)" : $0.tag }.joined(separator: "、"))") }
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
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

/// resound mcp —— 把会议知识库作为 MCP 服务器提供给 coding agent（模块 B）
struct Mcp: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Resound 作为 MCP 服务器（stdio）：供 Claude Code / Codex 检索你的会议与文档",
        subcommands: [McpServe.self, McpSelftest.self, McpSources.self, McpFetch.self, McpSync.self])
}

/// resound mcp sources —— 列出已配置的外部知识源（模块 A 调试）
struct McpSources: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sources",
        abstract: "列出外部 MCP 接入来源（内置 + 自定义）及连接状态")

    func run() async throws {
        let sources = MCPSourceStore.load()
        if sources.isEmpty { print("（无来源）"); return }
        for s in sources {
            let badge = s.builtin ? "内置" : "自定义"
            let host = s.hostPatterns.joined(separator: ", ")
            print("· [\(s.status.rawValue)] \(s.name)（\(badge)，\(s.transport.rawValue)）")
            print("    id=\(s.id)  kind=\(s.kind.rawValue)  auth=\(s.auth.rawValue)")
            if let u = s.url { print("    url=\(u)") }
            if !host.isEmpty { print("    hosts=\(host)") }
        }
    }
}

/// resound mcp fetch <url> —— 粘贴链接路由调试：识别来源→取回正文/降级，打印四路结果
struct McpFetch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "fetch",
        abstract: "对一个外部 URL 走 URL 路由（识别来源→取正文/降级），打印结果")

    @Argument(help: "外部文档 URL")
    var url: String

    @Option(name: .long, help: "Bearer token（无头测试用，绕过 Keychain/OAuth）")
    var token: String?

    @Option(name: .long, help: "若取回成功，入库并关联到该录音 id")
    var link: String?

    func run() async throws {
        let cfg = try Config.load()
        let res = await ExternalLinkResolver.resolve(url: url) { src in
            if let token { return token }
            return await MCPOAuth.validAccessToken(sourceId: src.id, clientId: src.clientId)
        }
        switch res {
        case .imported(let doc, let src):
            print("✅ 已取回（来源：\(src.name)）  标题：\(doc.title)  正文 \(doc.markdown.count) 字")
            print("---\n\(doc.markdown.prefix(500))\(doc.markdown.count > 500 ? "…" : "")\n---")
            if let rec = link, let vault = cfg.vaultPath {
                let id = try await MCPIngest.ingestImported(doc, source: src, url: url, recordingId: rec,
                    vaultRoot: URL(fileURLWithPath: vault), indexPath: defaultIndexPath(), config: cfg) { print($0) }
                print("📄 已入库并索引：\(id)，关联录音 \(rec)")
            }
        case .unconnected(let src):
            print("🔌 链接来自「\(src.name)」，但未连接——去设置里连接后才能取正文（否则只能仅链接保存）")
        case .unknown:
            print("❓ 无法识别来源/不支持/不可达——可作为「仅链接」保存")
        case .noPermission(let src):
            print("🔒 已连「\(src.name)」但取不到这条（多半无权限）——可仅链接保存或重试")
        }
    }
}

/// resound mcp sync <docDir> —— 重新同步一篇已索引外部文档（重取正文→重建索引）
struct McpSync: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync",
        abstract: "重新同步一篇外部文档目录（重取正文 + 重建索引）")

    @Argument(help: "文档目录（含 document.yaml）")
    var docDir: String

    @Option(name: .long, help: "Bearer token（无头测试用）")
    var token: String?

    func run() async throws {
        let cfg = try Config.load()
        guard let vault = cfg.vaultPath else { print("未配置 vault"); return }
        let ok = try await MCPIngest.resync(
            docDir: URL(fileURLWithPath: docDir), vaultRoot: URL(fileURLWithPath: vault),
            indexPath: defaultIndexPath(), config: cfg,
            bearer: { src in
                if let token { return token }
                return await MCPOAuth.validAccessToken(sourceId: src.id, clientId: src.clientId)
            }) { print($0) }
        print(ok ? "完成" : "跳过（非已索引外部文档 / 来源未连接）")
    }
}

/// resound mcp serve —— stdio MCP 服务器主循环（被 coding agent 作为子进程拉起）
struct McpServe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve",
        abstract: "启动 stdio MCP 服务器（阻塞运行；通常由编码助手拉起，不手动跑）")

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    func run() async throws {
        let cfg = try Config.load()
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        try await MCPServerRunner(config: cfg, indexPath: indexURL).run()
    }
}

/// resound mcp selftest —— 无头自检：直接调四个工具逻辑打印结果（不起真实传输）
struct McpSelftest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest",
        abstract: "无头自检：对四个工具各调一次并打印（验证检索/取文/内容策略）")

    @Argument(help: "检索用的测试问题")
    var query: String = "本季度的规划"

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    func run() async throws {
        let cfg = try Config.load()
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        print(await MCPServerRunner(config: cfg, indexPath: indexURL).runSelftest(query: query))
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

/// resound watch-meet —— 监听 Chrome 开 Google Meet（轮询 URL + 麦克风占用），命中打印（App 里改弹窗）
struct WatchMeet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "watch-meet",
        abstract: "监听 Chrome 是否在开 Google Meet，检测到则提示（需自动化权限控制 Chrome）")

    @Option(name: .long, help: "轮询间隔秒（默认 4）")
    var interval: Double = 4

    @Flag(name: .long, inversion: .prefixedNo, help: "需麦克风占用才算在通话（默认开，--no-require-mic 仅看标签）")
    var requireMic = true

    func run() async throws {
        let watcher = MeetWatcher()
        print("👀 监听 Google Meet…（首次会请求「控制 Google Chrome」权限）  按 Enter 停止")
        let task = Task {
            await watcher.watch(intervalSec: interval, requireMic: requireMic) { ev in
                switch ev {
                case .started(let url, let title, let mic):
                    print("\n🔔 检测到 Google Meet：\(url)  会议名：\(title ?? "(未知)")  麦克风：\(mic ? "占用中" : "空闲")")
                    print("   → App 里这里会弹窗：「检测到会议，开始录音?」")
                case .ended:
                    print("\n—— 会议结束")
                }
            }
        }
        _ = readLine()
        task.cancel()
        print("⏹  停止监听")
    }
}

/// resound record-meeting --vault <path> —— 录会议（麦克风 + 系统/对方音）→ 转录入库
struct RecordMeeting: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "record-meeting",
        abstract: "录会议：麦克风 + 系统音频(对方声音)双路 → 混音 → 转录写入 vault。需屏幕录制+麦克风权限")

    @Option(name: .long, help: "vault 根目录")
    var vault: String

    @Option(name: .long, help: "标题")
    var title: String?

    @Option(name: .long, help: "来源类型")
    var source: String = "meeting"

    @Option(name: .long, parsing: .upToNextOption, help: "标签")
    var tags: [String] = []

    @Option(name: .long, help: "WhisperKit 模型")
    var model: String = "large-v3"

    @Option(name: .long, help: "最长录音秒数（默认无限，按 Enter 停止）")
    var maxSeconds: Double?

    @Option(name: .long, help: "语言代码（如 zh / en），中英混杂建议 zh")
    var language: String?

    @Option(name: .long, parsing: .upToNextOption, help: "临时词表偏置词")
    var hint: [String] = []

    @Flag(name: .long, help: "完成后 git commit + push 回 vault")
    var push = false

    func run() async throws {
        let cap = try await MeetingRecorder().record(maxSeconds: maxSeconds)
        let tracks: (mic: URL, sys: URL)? = { if let m = cap.mic, let s = cap.sys { return (m, s) }; return nil }()
        let out = try await IngestPipeline(vaultRoot: URL(fileURLWithPath: vault))
            .ingest(audioPath: cap.mixed, tracks: tracks, title: title, source: source, tags: tags,
                    model: model, language: language, hints: hint, push: push)
        for u in [cap.mixed, cap.mic, cap.sys].compactMap({ $0 }) { try? FileManager.default.removeItem(at: u) }
        print("✅ 完成：\(out.id)")
    }
}

/// resound sync-speaker-names —— 把已注册说话人名字回填进 vault 的 glossary.txt 偏置词表
struct SyncSpeakerNames: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sync-speaker-names",
        abstract: "把索引里已注册的说话人名字加入 glossary.txt 偏置词表（去重）；命名说话人时也会自动加入")

    @Option(name: .long, help: "vault 根目录")
    var vault: String

    @Option(name: .long, help: "索引文件路径（默认 App Support）")
    var index: String?

    func run() async throws {
        let cfg = try Config.load()
        let indexURL = index.map { URL(fileURLWithPath: $0) } ?? defaultIndexPath()
        let names = (try? Index(path: indexURL, dim: cfg.embeddingDim))?.loadSpeakerRefs().map { $0.name } ?? []
        guard !names.isEmpty else { print("索引里没有已注册说话人"); return }
        let added = Glossary.syncSpeakerNames(vaultRoot: URL(fileURLWithPath: vault), names: names)
        print(added.isEmpty ? "✅ 词表已包含全部 \(names.count) 个说话人，无需新增"
                            : "✅ 已加入 \(added.count) 个说话人到词表偏置：\(added.joined(separator: "、"))")
    }
}

/// resound recover-meeting —— 从残留的 mic/sys 临时轨流式混音抢救一场卡死未落盘的会议
struct RecoverMeeting: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "recover-meeting",
        abstract: "从残留 mic/sys 临时文件流式混音（内存安全）→（可选）转录入库，抢救卡死丢失的会议")

    @Option(name: .long, help: "麦克风轨文件（如 T/resound-mic-*.caf）")
    var mic: String

    @Option(name: .long, help: "系统音频轨文件（如 T/resound-sys-*.m4a）")
    var sys: String

    @Option(name: .long, help: "vault 根目录；给了就转录入库，不给只输出混音 wav 路径（先验证不爆内存）")
    var vault: String?

    @Option(name: .long, help: "标题")
    var title: String?

    @Option(name: .long, help: "语言代码（中英混杂建议 zh）")
    var language: String?

    func run() async throws {
        let micURL = URL(fileURLWithPath: mic), sysURL = URL(fileURLWithPath: sys)
        print("🔀 流式混音抢救中（边读边重采样，不整读进内存）…")
        // 卡死录音的起点已随进程丢失 → 不加前导静音（两轨录制起点本就近同时），按 0 对齐。
        let r = try StreamingMix.mixTo16k(mic: micURL, sys: sysURL, micStartHost: nil, sysStartHost: nil) { print($0) }
        print("🎧 混音输出：\(r.mixed.path)")
        guard let vault else {
            print("（未给 --vault，仅验证混音；要入库请加 --vault）")
            return
        }
        let tracks: (mic: URL, sys: URL)? = { if let m = r.mic, let s = r.sys { return (m, s) }; return nil }()
        let out = try await IngestPipeline(vaultRoot: URL(fileURLWithPath: vault))
            .ingest(audioPath: r.mixed, tracks: tracks, title: title, source: "meeting", tags: [],
                    model: "large-v3", language: language, hints: [], push: false)
        for u in [r.mixed, r.mic, r.sys].compactMap({ $0 }) { try? FileManager.default.removeItem(at: u) }
        print("✅ 抢救完成并入库：\(out.id)")
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
