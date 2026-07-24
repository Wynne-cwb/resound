import Foundation
import CryptoKit

public struct FusedHit {
    public let hit: SearchHit
    public let rrf: Double
}

/// 默认索引位置：~/Library/Application Support/Resound/index.sqlite（派生物，不进 vault）。
public func defaultIndexPath() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("Resound/index.sqlite")
}

public struct IndexPipeline {
    public let config: Config
    public init(config: Config) { self.config = config }

    // MARK: 建索引

    public func build(vaultRoot: URL, indexPath: URL,
                      enrichContext: Bool = true, contextModel: String? = nil,
                      log: (String) -> Void = { print($0) }) async throws {
        let index = try Index(path: indexPath, dim: config.embeddingDim)
        try index.setMeta("embedding_model", config.embeddingModel)
        try index.setMeta("embedding_dim", String(config.embeddingDim))
        try index.setMeta("distance", "cosine")

        let recordings = findRecordings(vaultRoot)
        log("🔎 发现 \(recordings.count) 条录音")
        let embedder = EmbeddingClient(config: config)
        let chunker = Chunker()

        var totalChunks = 0
        for recDir in recordings {
            totalChunks += try await indexOneRecording(
                recDir: recDir, index: index, embedder: embedder, chunker: chunker,
                enrichContext: enrichContext, contextModel: contextModel, log: log)
        }

        let documents = findDocuments(vaultRoot)
        var totalDocChunks = 0
        if !documents.isEmpty {
            log("🔎 发现 \(documents.count) 篇文档")
            for docDir in documents {
                totalDocChunks += try await indexOneDocument(
                    docDir: docDir, index: index, embedder: embedder, chunker: chunker,
                    enrichContext: enrichContext, contextModel: contextModel, log: log)
            }
        }
        log("✅ 索引完成：\(recordings.count) 录音 / \(totalChunks) chunks + \(documents.count) 文档 / \(totalDocChunks) chunks → \(indexPath.path)")
    }

    /// 只索引单条录音（录完即用：chunk → 说话人标注 → 上下文 → embed → 入库）。幂等。
    /// `labelSpeakers=false`：跳过逐段声纹标注（导入路径用——随后的 diarization 会重算并覆盖 chunk 说话人，
    /// 此处标注是纯浪费的整段解码+提声纹）。
    public func indexRecording(recDir: URL, indexPath: URL,
                               enrichContext: Bool = true, contextModel: String? = nil,
                               labelSpeakers: Bool = true,
                               log: (String) -> Void = { print($0) }) async throws {
        let index = try Index(path: indexPath, dim: config.embeddingDim)
        try index.setMeta("embedding_model", config.embeddingModel)
        try index.setMeta("embedding_dim", String(config.embeddingDim))
        try index.setMeta("distance", "cosine")
        let n = try await indexOneRecording(
            recDir: recDir, index: index, embedder: EmbeddingClient(config: config),
            chunker: Chunker(), enrichContext: enrichContext, contextModel: contextModel,
            labelSpeakers: labelSpeakers, log: log)
        log("✅ 已索引：\(recDir.lastPathComponent)（\(n) chunks）")
    }

    /// 只索引单篇文档（导入即用）。幂等。
    public func indexDocument(docDir: URL, indexPath: URL,
                              enrichContext: Bool = true, contextModel: String? = nil,
                              log: (String) -> Void = { print($0) }) async throws {
        let index = try Index(path: indexPath, dim: config.embeddingDim)
        try index.setMeta("embedding_model", config.embeddingModel)
        try index.setMeta("embedding_dim", String(config.embeddingDim))
        try index.setMeta("distance", "cosine")
        let n = try await indexOneDocument(
            docDir: docDir, index: index, embedder: EmbeddingClient(config: config),
            chunker: Chunker(), enrichContext: enrichContext, contextModel: contextModel, log: log)
        log("✅ 已索引文档：\(docDir.lastPathComponent)（\(n) chunks）")
    }

    /// 单篇文档的索引逻辑（build 与 indexDocument 共用）。返回 chunk 数。
    /// 文档无时间轴/说话人：start/end=0、person_id=null、recording_date=null（故不参与时间过滤检索）。
    private func indexOneDocument(docDir: URL, index: Index, embedder: EmbeddingClient,
                                  chunker: Chunker, enrichContext: Bool, contextModel: String?,
                                  log: (String) -> Void) async throws -> Int {
        guard let manifest = parseDocumentManifest(docDir) else {
            log("  ⚠️ 跳过（无 document.yaml）：\(docDir.lastPathComponent)"); return 0
        }
        guard let text = documentContent(docDir),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log("  ⚠️ 跳过（无 content.md）：\(manifest.id)"); return 0
        }
        let chunks = chunker.chunk(text: text)
        try index.upsertDocument(id: manifest.id, title: manifest.title, importedAt: manifest.importedAt)
        try index.deleteChunks(docId: manifest.id)   // 幂等重建
        try index.setDocLinks(docId: manifest.id, recordingIds: manifest.linkedRecordingIds)

        var contexts: [Int: String] = [:]
        if enrichContext {
            contexts = try await enrichAll(chunks: chunks, document: text, index: index,
                model: contextModel ?? config.contextModel, log: log)
        }
        for batch in chunks.chunked(into: 32) {
            let texts = batch.map { c -> String in
                if let ctx = contexts[c.index] { return "\(ctx)\n\(c.text)" }
                return c.text
            }
            let vecs = try await embedAll(texts: texts, index: index, embedder: embedder, log: log)
            for (chunk, vec) in zip(batch, vecs) {
                try index.insertChunk(recordingId: nil, idx: chunk.index,
                    text: chunk.text, context: contexts[chunk.index],
                    start: 0, end: 0, personId: nil, recordingDate: nil, embedding: vec,
                    sourceKind: "document", docId: manifest.id)
            }
        }
        log("  ✓ \(manifest.id)：\(chunks.count) chunks（文档）")
        return chunks.count
    }

    /// 单条录音的索引逻辑（build 与 indexRecording 共用）。返回 chunk 数。
    private func indexOneRecording(recDir: URL, index: Index, embedder: EmbeddingClient,
                                   chunker: Chunker, enrichContext: Bool, contextModel: String?,
                                   labelSpeakers: Bool = true,
                                   log: (String) -> Void) async throws -> Int {
        let manifest = try parseManifest(recDir.appendingPathComponent("recording.yaml"))
        let tURL = recDir.appendingPathComponent("transcript.json")
        guard let tData = try? Data(contentsOf: tURL),
              let transcript = try? JSONDecoder().decode(Transcript.self, from: tData) else {
            log("  ⚠️ 跳过（无 transcript.json）：\(manifest.id)")
            return 0
        }
        let chunks = chunker.chunk(transcript)
        try index.upsertRecording(id: manifest.id, title: manifest.title,
            recordedAt: manifest.recordedAt, durationSec: manifest.durationSec,
            source: manifest.source, language: manifest.language)
        try index.deleteChunks(recordingId: manifest.id)   // 幂等重建

        // 说话人标注：配置了声纹模型 + index 已有注册声纹时，逐段识别填 person_id（缺一则跳过，不影响检索）
        var personSpans: [(start: Double, end: Double, name: String)] = []
        if labelSpeakers, let spkModel = config.speakerModel {
            let refs = index.loadSpeakerRefs()
            let audioURL = recDir.appendingPathComponent(manifest.audioFile)
            if !refs.isEmpty, FileManager.default.fileExists(atPath: audioURL.path) {
                let matcher = SpeakerMatcher(); matcher.setRefs(refs)
                let spkEmbedder = try SpeakerEmbedder(model: spkModel)
                personSpans = try recognizeSpansFromFile(
                    audio: audioURL,
                    segments: transcript.segments.map { (start: $0.start, end: $0.end) },
                    matcher: matcher, embedder: spkEmbedder)
                let who = Set(personSpans.map { $0.name }).subtracting(["unknown"]).sorted()
                log("  🗣 说话人标注：\(who.isEmpty ? "无匹配" : who.joined(separator: "/"))")
            }
        }

        var contexts: [Int: String] = [:]
        if enrichContext {
            let docText = transcript.segments.map { $0.text }.joined()
            contexts = try await enrichAll(chunks: chunks, document: docText, index: index,
                model: contextModel ?? config.contextModel, log: log)
        }

        let recDate = localDate(fromISO: manifest.recordedAt)
        for batch in chunks.chunked(into: 32) {
            let texts = batch.map { c -> String in
                if let ctx = contexts[c.index] { return "\(ctx)\n\(c.text)" }
                return c.text
            }
            let vecs = try await embedAll(texts: texts, index: index, embedder: embedder, log: log)
            for (chunk, vec) in zip(batch, vecs) {
                let person = personSpans.isEmpty ? nil : personFor(personSpans, start: chunk.start, end: chunk.end)
                try index.insertChunk(recordingId: manifest.id, idx: chunk.index,
                    text: chunk.text, context: contexts[chunk.index],
                    start: chunk.start, end: chunk.end, personId: person,
                    recordingDate: recDate, embedding: vec)
            }
        }
        log("  ✓ \(manifest.id)：\(chunks.count) chunks\(enrichContext ? "（含上下文）" : "")")
        return chunks.count
    }

    // MARK: 就地重打说话人标签（不重嵌入；注册新声纹后调用）

    public func labelExisting(vaultRoot: URL, indexPath: URL,
                              log: (String) -> Void = { print($0) }) async throws {
        guard let spkModel = config.speakerModel else { throw ConfigError.missing("SPEAKER_MODEL") }
        let index = try Index(path: indexPath, dim: config.embeddingDim)
        let refs = index.loadSpeakerRefs()
        guard !refs.isEmpty else { log("⚠️ 声纹库为空，先 speaker-enroll"); return }
        log("🗣 声纹库：\(refs.map { $0.name }.joined(separator: "/"))")
        let embedder = try SpeakerEmbedder(model: spkModel)
        var dirById: [String: URL] = [:]
        for d in findRecordings(vaultRoot) {
            if let m = try? parseManifest(d.appendingPathComponent("recording.yaml")) { dirById[m.id] = d }
        }
        var done = 0
        for recId in index.allRecordingIds() {
            guard let dir = dirById[recId] else { log("  ⚠️ 找不到目录：\(recId)"); continue }
            let manifest = try parseManifest(dir.appendingPathComponent("recording.yaml"))
            let audioURL = dir.appendingPathComponent(manifest.audioFile)
            let tURL = dir.appendingPathComponent("transcript.json")
            guard FileManager.default.fileExists(atPath: audioURL.path),
                  let tData = try? Data(contentsOf: tURL),
                  let transcript = try? JSONDecoder().decode(Transcript.self, from: tData) else {
                log("  ⚠️ 跳过（缺音频/转录）：\(recId)"); continue
            }
            let matcher = SpeakerMatcher(); matcher.setRefs(refs)
            let spans = try recognizeSpansFromFile(
                audio: audioURL, segments: transcript.segments.map { (start: $0.start, end: $0.end) },
                matcher: matcher, embedder: embedder)
            var labeled = 0
            for c in index.chunkTimes(recordingId: recId) {
                let p = personFor(spans, start: c.start, end: c.end)
                try index.setChunkPerson(id: c.id, person: p)
                if p != nil { labeled += 1 }
            }
            let who = Set(spans.map { $0.name }).subtracting(["unknown"]).sorted()
            log("  ✓ \(recId)：\(who.isEmpty ? "无匹配" : who.joined(separator: "/"))（\(labeled) chunk 打标）")
            done += 1
        }
        log("✅ 重打标完成：\(done) 条录音")
    }

    // MARK: 检索（hybrid + RRF；rerank 留待下一步）

    public func search(query: String, indexPath: URL, topK: Int = 5, pool: Int = 40,
                       rerank: Bool = false, rerankModel: String? = nil,
                       rerankCandidates: Int = 15,
                       filters: Index.Filters = .init()) async throws -> [SearchHit] {
        let index = try Index(path: indexPath, dim: config.embeddingDim)
        let qvec = try await EmbeddingClient(config: config).embedQuery(query)
        let vHits = try index.vectorSearch(qvec, k: pool, filters: filters)
        let fHits = try index.ftsSearch(query, k: pool, filters: filters)
        let fused = rrf([vHits, fHits], topK: rerank ? rerankCandidates : topK).map { $0.hit }
        guard rerank else { return Array(fused.prefix(topK)) }

        let chat = ChatClient(config: config, modelOverride: rerankModel ?? config.rerankModel)
        return try await Reranker(chat: chat).rerank(query: query, candidates: fused, topK: topK)
    }

    /// 从 Plan 的过滤条件（时间/说话人/来源）构造检索过滤器。`source=.both` 不过滤来源。
    private func filters(from plan: QueryPlanner.Plan, includeDate: Bool = true) -> Index.Filters {
        Index.Filters(
            dateRange: includeDate ? plan.dateRange : nil,
            speakers: plan.speakers,
            sourceKind: plan.source == .both ? nil : plan.source.rawValue)
    }

    // MARK: 摘要

    /// 为单条录音生成 AI 摘要：读转录+说话人+录音时间 → 模板 → 写 summary.md +（可选）入索引。
    @discardableResult
    public func summarizeRecording(recDir: URL, indexPath: URL? = nil, templateId: String? = nil,
                                   log: (String) -> Void = { print($0) }) async throws -> String {
        let manifest = try parseManifest(recDir.appendingPathComponent("recording.yaml"))
        guard let t = loadTranscript(recDir.appendingPathComponent("transcript.json")) else {
            throw ConfigError.missing("transcript.json")
        }
        let transcriptText = t.segments.map { $0.text }.joined(separator: "\n")
        var speakers: [String] = []
        if let diar = loadDiarization(recDir) {
            speakers = Array(Set(diar.map { $0.speaker })).filter { $0 != "?" }.sorted()
        }
        let tmpl = SummaryTemplateStore.template(id: templateId)
        // 关联文档当背景：从 vault 反查本场关联的文档全文（P2）。无关联 / 无 vault 路径 → 空数组，行为同现状。
        let refDocs = config.vaultPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            .map { linkedDocumentTexts(vaultRoot: $0, recordingId: manifest.id) } ?? []
        if !refDocs.isEmpty { log("📎 纳入 \(refDocs.count) 篇关联文档作为背景") }
        log("📝 生成摘要（模板：\(tmpl.name)）…")
        let summary = try await Summarizer(chat: ChatClient(config: config, modelOverride: config.summaryModel))
            .summarize(transcript: transcriptText,
                       meta: .init(title: manifest.title, recordedAt: manifest.recordedAt, speakers: speakers),
                       template: tmpl, referenceDocs: refDocs)
        try summary.data(using: .utf8)?.write(to: recDir.appendingPathComponent("summary.md"))
        if let indexPath {
            let idx = try Index(path: indexPath, dim: config.embeddingDim)
            try idx.setRecordingSummary(id: manifest.id, summary: summary, template: tmpl.id)
        }
        log("   ✓ summary.md")
        return summary
    }

    // MARK: 问答编排（查询规划 → digest / qa）

    public struct AnswerResult {
        public let text: String
        public let plan: QueryPlanner.Plan
        public let hits: [SearchHit]                       // qa 模式引用
        public let digestRecordings: [Index.RecordingRow]  // digest 模式涉及的录音
    }

    // 检索宽度常量（随 shape 自适应；保守默认，实测再调）。
    private enum W {
        static let digestPool = 120           // digest 召回放大，目的=找全相关录音（非只挑 8 段）
        static let digestCandidates = 60      // RRF 后保留更多候选进重排
        static let digestChunkTopK = 40       // 重排后保留的片段（按录音聚合成主题子集）
        static let maxDigestRecordings = 60   // 主题子集最多纳入多少条录音
        static let excerptsPerRec = 2         // 每条录音附带的命中片段条数
        static let longRangeDays = 40         // 超此天数=长跨度主题回顾；否则=小窗口概览（零回归走 summaries）
        static let mapReduceRecCap = 12       // 录音数超此 / 字数超预算 → map-reduce
        static let mapReduceCharBudget = 24000
    }

    public func answer(question: String, indexPath: URL, topK: Int = 8,
                       usePlanner: Bool = true, answerModel: String? = nil,
                       history: [ChatTurn] = []) async throws -> AnswerResult {
        let chat = ChatClient(config: config, modelOverride: answerModel ?? config.answerModel)
        let plan: QueryPlanner.Plan = usePlanner
            ? await QueryPlanner(chat: ChatClient(config: config, modelOverride: config.rerankModel)).plan(question, history: history)
            : .init(query: question, dateFrom: nil, dateTo: nil)

        // compare：两组材料各自检索 → 对比综合（⑧）。判不出两个集合则落 qa 兜底。
        if plan.shape == .compare {
            if let r = try await compareAnswer(question: question, plan: plan, indexPath: indexPath,
                                               chat: chat, history: history) {
                return r
            }
        }

        // digest / timeline：主题子集（录音摘要 + 命中片段）综合，量大走 map-reduce。
        if plan.shape == .digest || plan.shape == .timeline {
            if let r = try await digestAnswer(question: question, plan: plan, indexPath: indexPath,
                                              chat: chat, history: history) {
                return r
            }
            // 子集为空 → 落到 qa 兜底（放宽过滤），绝不空手挡死。
        }

        // qa（默认 / 各形状兜底）：带过滤的碎片检索 + 综合；过滤到空则自动放宽；recency 时近因加权。
        let hits = try await qaSearchWithFallback(query: plan.query, plan: plan,
                                                  indexPath: indexPath, topK: topK)
        let text = try await Synthesizer(chat: chat).answer(query: question, hits: hits, history: history)
        return AnswerResult(text: text, plan: plan, hits: hits, digestRecordings: [])
    }

    /// qa 检索 + 安全兜底：带过滤检索为空时，按 speaker→time→source 顺序逐步放宽再试。绝不空手挡死。
    /// recency=true 时多取候选并按"相关度×近因"重排，让最近的讨论优先（③现状）。
    private func qaSearchWithFallback(query: String, plan: QueryPlanner.Plan,
                                      indexPath: URL, topK: Int) async throws -> [SearchHit] {
        let fetchK = plan.recency ? max(topK, 24) : topK   // 近因需更大候选池供重排
        func fetch(_ f: Index.Filters) async throws -> [SearchHit] {
            try await search(query: query, indexPath: indexPath, topK: fetchK, rerank: true, filters: f)
        }
        let f0 = filters(from: plan)
        var hits = try await fetch(f0)
        if hits.isEmpty && f0.isActive {
            // 放宽①：去说话人　②：再去时间　③：彻底无过滤
            if plan.speakers?.isEmpty == false {
                var f1 = f0; f1.speakers = nil
                hits = try await fetch(f1)
            }
            if hits.isEmpty {
                var f2 = f0; f2.speakers = nil; f2.dateRange = nil
                if f2.isActive { hits = try await fetch(f2) }
            }
            if hits.isEmpty { hits = try await fetch(Index.Filters()) }
        }
        return plan.recency ? applyRecency(hits, topK: topK) : hits
    }

    /// 近因加权重排：把 rerank 名次（相关度）与录音日期的时间衰减融合，取前 topK。
    /// 文档无日期 → 中性权重，不被惩罚也不被偏好。半衰期 120 天。
    private func applyRecency(_ hits: [SearchHit], topK: Int, now: Date = Date()) -> [SearchHit] {
        guard hits.count > 1 else { return hits }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        let n = Double(hits.count)
        let scored = hits.enumerated().map { (i, h) -> (SearchHit, Double) in
            let rel = Double(hits.count - i) / n          // rerank 名次 → 相关度
            var rec = 0.5
            if let ds = h.recordingDate, let d = f.date(from: ds) {
                let ageDays = max(0, now.timeIntervalSince(d) / 86400)
                rec = pow(2.0, -ageDays / 120.0)
            }
            return (h, 0.6 * rel + 0.4 * rec)
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(topK).map { $0.0 }
    }

    // MARK: compare 引擎（两组材料各自检索 → 对比综合）

    private func compareAnswer(question: String, plan: QueryPlanner.Plan, indexPath: URL,
                               chat: ChatClient, history: [ChatTurn]) async throws -> AnswerResult? {
        guard let sets = plan.compareSets, sets.count == 2 else { return nil }
        var allHits: [SearchHit] = []
        var blocks: [String] = []
        for set in sets {
            let f = Index.Filters(dateRange: set.dateRange,
                                  speakers: set.speakers ?? plan.speakers,
                                  sourceKind: plan.source == .both ? nil : plan.source.rawValue)
            let hits = try await search(query: plan.query, indexPath: indexPath, topK: 10, pool: 60,
                                        rerank: true, rerankCandidates: 30, filters: f)
            allHits += hits
            let label = set.label + (set.dateRange.map { "（\($0.from)~\($0.to)）" } ?? "")
            let ex = hits.prefix(8).map { "  - \(excerpt($0.text))" }.joined(separator: "\n")
            blocks.append("## \(label)\n\(ex.isEmpty ? "（无命中）" : ex)")
        }
        guard !allHits.isEmpty else { return nil }
        let system = """
        你基于两组材料做对比回答：先分两栏分别概述各自要点，再用一段点明两者的差异/变化。\(todayAnchor())
        - 只用提供的材料，不臆造；某组无命中就如实说明。
        - 如有对话历史，用它理解指代并接着上文说。
        \(zhWritingStyle)
        """
        let hist = renderHistory(history)
        let histBlock = hist.isEmpty ? "" : "对话历史：\n\(hist)\n\n"
        let text = try await chat.complete(system: system,
            user: "\(histBlock)用户问题：\(question)\n\n\(blocks.joined(separator: "\n\n"))", maxTokens: 3000)
        return AnswerResult(text: text, plan: plan, hits: allHits, digestRecordings: [])
    }

    /// 「向本场提问」：检索严格限定在单条录音内 + 综合带引用。
    /// 不走 QueryPlanner（单录音无需时间范围/digest 判定），直接 hybrid+rerank 后交 Synthesizer。
    public func answerInRecording(question: String, recordingId: String, indexPath: URL,
                                  topK: Int = 6, answerModel: String? = nil,
                                  history: [ChatTurn] = []) async throws -> (text: String, hits: [SearchHit]) {
        let chat = ChatClient(config: config, modelOverride: answerModel ?? config.answerModel)
        // 检索用「借历史改写成可独立检索」的查询（追问如"那么时间线呢"才能命中）；综合仍用原问 + 全量历史。
        let retrievalQuery = await condensedQuery(question, history: history)
        // 单录音提问也纳入「关联文档」：scope = 本录音 chunk ∪ 关联文档 chunk（无关联时同以前，严格限本录音）。
        let linkedDocIds = (try? Index(path: indexPath, dim: config.embeddingDim))
            .map { $0.documentsLinked(toRecording: recordingId).map(\.id) } ?? []
        let hits = try await search(query: retrievalQuery, indexPath: indexPath, topK: topK,
                                    rerank: true,
                                    filters: .init(recordingId: recordingId,
                                                   linkedDocIds: linkedDocIds.isEmpty ? nil : linkedDocIds))
        let text = try await Synthesizer(chat: chat).answer(query: question, hits: hits, history: history)
        return (text, hits)
    }

    /// 把可能含指代的追问借对话历史改写成可独立检索的查询；无历史则原样返回。
    /// 与全局 answer() 一致复用 QueryPlanner 的历史感知改写，只取其 query——
    /// scope 已被 recordingId/docId 锁定，故忽略 plan 的 shape/filters，仅借它把"那么时间线呢"补全成完整查询。
    private func condensedQuery(_ question: String, history: [ChatTurn]) async -> String {
        guard !history.isEmpty else { return question }
        let plan = await QueryPlanner(chat: ChatClient(config: config, modelOverride: config.rerankModel))
            .plan(question, history: history)
        let q = plan.query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? question : q
    }

    /// 「向本文档提问」：检索严格限定在单篇文档内 + 综合带引用（answerInRecording 的文档镜像）。
    public func answerInDocument(question: String, documentId: String, indexPath: URL,
                                 topK: Int = 6, answerModel: String? = nil,
                                 history: [ChatTurn] = []) async throws -> (text: String, hits: [SearchHit]) {
        let chat = ChatClient(config: config, modelOverride: answerModel ?? config.answerModel)
        let retrievalQuery = await condensedQuery(question, history: history)
        let hits = try await search(query: retrievalQuery, indexPath: indexPath, topK: topK,
                                    rerank: true, filters: .init(docId: documentId))
        let text = try await Synthesizer(chat: chat).answer(query: question, hits: hits, history: history)
        return (text, hits)
    }

    // MARK: digest / timeline 引擎（主题子集 + 混合数据源 + map-reduce）

    /// 返回 nil 表示子集为空（调用方落 qa 兜底）。
    private func digestAnswer(question: String, plan: QueryPlanner.Plan, indexPath: URL,
                              chat: ChatClient, history: [ChatTurn]) async throws -> AnswerResult? {
        let index = try Index(path: indexPath, dim: config.embeddingDim)
        var recs: [Index.RecordingRow]
        var hits: [SearchHit] = []

        if let range = plan.dateRange {
            recs = index.recordingsInRange(range)
            // 短跨度（这周/这个月）= 纯概览，只喂摘要（零回归）；长跨度=主题回顾，附命中片段佐证。
            if daySpan(range) > W.longRangeDays {
                hits = try await search(query: plan.query, indexPath: indexPath,
                                        topK: W.digestChunkTopK, pool: W.digestPool, rerank: true,
                                        rerankCandidates: W.digestCandidates, filters: filters(from: plan))
            }
        } else {
            // 无时间范围 → 主题检索定子集（②的主路径）
            hits = try await search(query: plan.query, indexPath: indexPath,
                                    topK: W.digestChunkTopK, pool: W.digestPool, rerank: true,
                                    rerankCandidates: W.digestCandidates,
                                    filters: filters(from: plan, includeDate: false))
            recs = index.recordings(ids: orderedRecordingIds(hits, limit: W.maxDigestRecordings))
        }
        guard !recs.isEmpty else { return nil }
        let text = try await synthesizeDigest(question: question, recs: recs, hits: hits,
                                              chat: chat, history: history, timeline: plan.shape == .timeline)
        return AnswerResult(text: text, plan: plan, hits: hits, digestRecordings: recs)
    }

    /// 从命中片段里按排序提取去重的录音 id（仅录音、跳过文档/空），保序、限量。
    private func orderedRecordingIds(_ hits: [SearchHit], limit: Int) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for h in hits where h.sourceKind != "document" {
            let id = h.recordingId
            if id.isEmpty || seen.contains(id) { continue }
            seen.insert(id); out.append(id)
            if out.count >= limit { break }
        }
        return out
    }

    private func synthesizeDigest(question: String, recs: [Index.RecordingRow], hits: [SearchHit],
                                  chat: ChatClient, history: [ChatTurn], timeline: Bool) async throws -> String {
        let byRec = Dictionary(grouping: hits.filter { $0.sourceKind != "document" }, by: { $0.recordingId })
        let docHits = hits.filter { $0.sourceKind == "document" }
        func block(_ r: Index.RecordingRow) -> String {
            let date = String(r.recordedAt.prefix(10))
            var s = "## \(date) · \(r.title)（\(r.id)）\n\(r.summary ?? "（该条暂无摘要）")\n"
            if let hs = byRec[r.id], !hs.isEmpty {
                let ex = hs.prefix(W.excerptsPerRec).map { "  - \(excerpt($0.text))" }.joined(separator: "\n")
                s += "相关片段：\n\(ex)\n"
            }
            return s
        }
        var blocks = recs.map(block)
        if !docHits.isEmpty {
            let ex = docHits.prefix(6).map { "  - 〔\($0.docTitle ?? "文档")〕\(excerpt($0.text))" }.joined(separator: "\n")
            blocks.append("## 相关文档片段\n\(ex)\n")
        }
        let total = blocks.reduce(0) { $0 + $1.count }
        if recs.count <= W.mapReduceRecCap && total <= W.mapReduceCharBudget {
            return try await digestLLM(question: question, source: blocks.joined(separator: "\n"),
                                       chat: chat, history: history, timeline: timeline, partial: false)
        }
        // map：按字数分批各出局部要点；reduce：合并成终答。
        var partials: [String] = []
        for batch in batchByChars(blocks, budget: W.mapReduceCharBudget) {
            partials.append(try await digestLLM(question: question, source: batch.joined(separator: "\n"),
                                                chat: chat, history: [], timeline: timeline, partial: true))
        }
        let reduceSrc = partials.enumerated()
            .map { "【部分 \($0.offset + 1)】\n\($0.element)" }.joined(separator: "\n\n")
        return try await digestLLM(question: question, source: reduceSrc,
                                   chat: chat, history: history, timeline: timeline, partial: false, reducing: true)
    }

    private func digestLLM(question: String, source: String, chat: ChatClient, history: [ChatTurn],
                           timeline: Bool, partial: Bool, reducing: Bool = false) async throws -> String {
        let organize = timeline
            ? "按时间先后串成『谁在何时推动了什么 → 如何演变到现在』的叙事，标注关键日期节点"
            : "按主题/时间组织，简洁清楚"
        let role: String
        if partial {
            role = "下面是若干会议的摘要与片段中的一部分。只就这部分材料，整理出与用户问题相关的要点（带日期/会议标记），供后续合并。不要写开场白或最终结论。"
        } else if reducing {
            role = "下面是同一问题在多批材料上各自整理出的要点。把它们合并去重，\(organize)，形成完整回答。"
        } else {
            role = "你基于若干会议的摘要与相关片段回答用户的汇总类问题。\(organize)。"
        }
        let system = """
        \(role)
        - 只用提供的材料，不要臆造；某条没有摘要就注明"该条暂无摘要"。\(todayAnchor())
        - 如有对话历史，用它理解指代并接着上文说。
        \(zhWritingStyle)
        """
        let hist = renderHistory(history)
        let histBlock = hist.isEmpty ? "" : "对话历史：\n\(hist)\n\n"
        return try await chat.complete(system: system,
            user: "\(histBlock)用户问题：\(question)\n\n材料：\n\(source)", maxTokens: 3000)
    }

    /// 把片段正文压到 max 字以内（去换行），避免 digest 材料过度膨胀。
    private func excerpt(_ t: String, _ max: Int = 240) -> String {
        let s = t.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return s.count <= max ? s : String(s.prefix(max)) + "…"
    }

    private func batchByChars(_ blocks: [String], budget: Int) -> [[String]] {
        var out: [[String]] = []; var cur: [String] = []; var n = 0
        for b in blocks {
            if !cur.isEmpty && n + b.count > budget { out.append(cur); cur = []; n = 0 }
            cur.append(b); n += b.count
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private func daySpan(_ range: Index.DateRange) -> Int {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        guard let a = f.date(from: range.from), let b = f.date(from: range.to) else { return 0 }
        return Int(b.timeIntervalSince(a) / 86400) + 1
    }

    // MARK: contextual 增强（带缓存 + 限并发）

    private func enrichAll(chunks: [Chunk], document: String, index: Index,
                           model: String, log: (String) -> Void) async throws -> [Int: String] {
        let enricher = ContextualEnricher(chat: ChatClient(config: config, modelOverride: model))
        var out: [Int: String] = [:]
        var todo: [Chunk] = []
        for c in chunks {
            if let cached = index.cachedContext(hash: chunkHash(model: model, text: c.text)) {
                out[c.index] = cached
            } else {
                todo.append(c)
            }
        }
        guard !todo.isEmpty else { return out }
        log("  🧠 生成上下文 \(todo.count)/\(chunks.count) chunk（\(model)）…")

        for slice in todo.chunked(into: 4) {   // 限并发 4，文档 prefix 命中 DeepSeek 缓存
            try await withThrowingTaskGroup(of: (Int, String, String).self) { group in
                for c in slice {
                    let text = c.text
                    let idx = c.index
                    group.addTask {
                        let ctx = try await enricher.context(document: document, chunk: text)
                        return (idx, ctx, text)
                    }
                }
                for try await (idx, ctx, text) in group {
                    out[idx] = ctx
                    try? index.setCachedContext(
                        hash: chunkHash(model: model, text: text), context: ctx, model: model)
                }
            }
        }
        return out
    }

    // MARK: embedding（带缓存）—— 只对未命中的入向量文本调 API，省「改个错字重嵌全场」的钱

    private func embedAll(texts: [String], index: Index, embedder: EmbeddingClient,
                          log: (String) -> Void) async throws -> [[Float]] {
        let model = config.embeddingModel
        var out = [[Float]?](repeating: nil, count: texts.count)
        var todoIdx: [Int] = []
        var todoTexts: [String] = []
        for (i, t) in texts.enumerated() {
            if let v = index.cachedEmbedding(hash: chunkHash(model: model, text: t)) {
                out[i] = v
            } else {
                todoIdx.append(i); todoTexts.append(t)
            }
        }
        if !todoTexts.isEmpty {
            log("  🔢 embedding \(todoTexts.count)/\(texts.count) chunk（\(model)）…")
            let vecs = try await embedder.embedDocuments(todoTexts)
            for (j, v) in vecs.enumerated() {
                out[todoIdx[j]] = v
                try? index.setCachedEmbedding(hash: chunkHash(model: model, text: todoTexts[j]), vec: v, model: model)
            }
        }
        return out.map { $0 ?? [] }
    }

    /// 清掉索引里已不在 vault 的录音（归档/手动删目录后 `index` 增量重建不会删，
    /// 残留 chunk 会污染检索且点击跳转是死链）。返回清理的录音 id。CLI `index-prune` 用。
    public func pruneOrphanRecordings(
        vaultRoot: URL, indexPath: URL, log: (String) -> Void = { print($0) }
    ) throws -> [String] {
        let index = try Index(path: indexPath, dim: config.embeddingDim)
        var onDisk = Set<String>()
        for d in findRecordings(vaultRoot) {
            if let m = try? parseManifest(d.appendingPathComponent("recording.yaml")) { onDisk.insert(m.id) }
        }
        var pruned: [String] = []
        for recId in index.allRecordingIds() where !onDisk.contains(recId) {
            try index.deleteRecording(id: recId)
            pruned.append(recId)
            log("  🧹 已清理索引残留：\(recId)")
        }
        return pruned
    }
}

func chunkHash(model: String, text: String) -> String {
    let digest = SHA256.hash(data: Data("\(model)\u{1}\(text)".utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - helpers

struct Manifest {
    let id: String, title: String, recordedAt: String
    let durationSec: Int, source: String, language: String
    let audioFile: String
}

func parseManifest(_ url: URL) throws -> Manifest {
    let s = try String(contentsOf: url, encoding: .utf8)
    var m: [String: String] = [:]
    for line in s.split(whereSeparator: \.isNewline) {
        if line.first == " " || line.first == "\t" { continue }   // 跳过 provenance 嵌套
        let t = String(line)
        guard let r = t.range(of: ":") else { continue }
        let k = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        var v = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
        m[k] = v
    }
    return Manifest(
        id: m["id"] ?? url.deletingLastPathComponent().lastPathComponent,
        title: m["title"] ?? "",
        recordedAt: m["recorded_at"] ?? "",
        durationSec: Int(m["duration_sec"] ?? "0") ?? 0,
        source: m["source"] ?? "",
        language: m["language"] ?? "",
        audioFile: m["audio_file"] ?? "audio.m4a")
}

/// 递归找 recordings/ 下所有含 recording.yaml 的目录。
func findRecordings(_ vaultRoot: URL) -> [URL] {
    let recRoot = vaultRoot.appendingPathComponent("recordings")
    guard let en = FileManager.default.enumerator(at: recRoot,
        includingPropertiesForKeys: nil) else { return [] }
    var dirs: [URL] = []
    for case let f as URL in en where f.lastPathComponent == "recording.yaml" {
        dirs.append(f.deletingLastPathComponent())
    }
    return dirs.sorted { $0.path < $1.path }
}

/// Reciprocal Rank Fusion。
func rrf(_ lists: [[SearchHit]], K: Double = 60, topK: Int) -> [FusedHit] {
    var score: [Int64: Double] = [:]
    var info: [Int64: SearchHit] = [:]
    for list in lists {
        for (i, h) in list.enumerated() {
            score[h.rowid, default: 0] += 1.0 / (K + Double(i + 1))
            info[h.rowid] = h
        }
    }
    return score.sorted { $0.value > $1.value }.prefix(topK).map {
        FusedHit(hit: info[$0.key]!, rrf: $0.value)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
