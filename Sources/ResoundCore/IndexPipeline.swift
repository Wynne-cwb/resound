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
            let vecs = try await embedder.embedDocuments(texts)
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
            let vecs = try await embedder.embedDocuments(texts)
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
                       dateRange: Index.DateRange? = nil,
                       recordingId: String? = nil, docId: String? = nil) async throws -> [SearchHit] {
        let index = try Index(path: indexPath, dim: config.embeddingDim)
        let qvec = try await EmbeddingClient(config: config).embedQuery(query)
        let vHits = try index.vectorSearch(qvec, k: pool, dateRange: dateRange, recordingId: recordingId, docId: docId)
        let fHits = try index.ftsSearch(query, k: pool, dateRange: dateRange, recordingId: recordingId, docId: docId)
        let fused = rrf([vHits, fHits], topK: rerank ? rerankCandidates : topK).map { $0.hit }
        guard rerank else { return Array(fused.prefix(topK)) }

        let chat = ChatClient(config: config, modelOverride: rerankModel ?? config.rerankModel)
        return try await Reranker(chat: chat).rerank(query: query, candidates: fused, topK: topK)
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

    public func answer(question: String, indexPath: URL, topK: Int = 8,
                       usePlanner: Bool = true, answerModel: String? = nil,
                       history: [ChatTurn] = []) async throws -> AnswerResult {
        let chat = ChatClient(config: config, modelOverride: answerModel ?? config.answerModel)
        let plan: QueryPlanner.Plan = usePlanner
            ? await QueryPlanner(chat: ChatClient(config: config, modelOverride: config.rerankModel)).plan(question, history: history)
            : .init(query: question, dateFrom: nil, dateTo: nil, mode: .qa)

        // digest：取范围内录音的摘要合并回答（"汇总昨天的会议"）
        if plan.mode == .digest, let range = plan.dateRange {
            let recs = try Index(path: indexPath, dim: config.embeddingDim).recordingsInRange(range)
            if !recs.isEmpty {
                let text = try await digestAnswer(question: question, recs: recs, chat: chat, history: history)
                return AnswerResult(text: text, plan: plan, hits: [], digestRecordings: recs)
            }
        }

        // qa：（可带日期过滤的）碎片检索 + 综合
        let hits = try await search(query: plan.query, indexPath: indexPath, topK: topK,
                                    rerank: true, dateRange: plan.dateRange)
        let text = try await Synthesizer(chat: chat).answer(query: question, hits: hits, history: history)
        return AnswerResult(text: text, plan: plan, hits: hits, digestRecordings: [])
    }

    /// 「向本场提问」：检索严格限定在单条录音内 + 综合带引用。
    /// 不走 QueryPlanner（单录音无需时间范围/digest 判定），直接 hybrid+rerank 后交 Synthesizer。
    public func answerInRecording(question: String, recordingId: String, indexPath: URL,
                                  topK: Int = 6, answerModel: String? = nil,
                                  history: [ChatTurn] = []) async throws -> (text: String, hits: [SearchHit]) {
        let chat = ChatClient(config: config, modelOverride: answerModel ?? config.answerModel)
        let hits = try await search(query: question, indexPath: indexPath, topK: topK,
                                    rerank: true, recordingId: recordingId)
        let text = try await Synthesizer(chat: chat).answer(query: question, hits: hits, history: history)
        return (text, hits)
    }

    /// 「向本文档提问」：检索严格限定在单篇文档内 + 综合带引用（answerInRecording 的文档镜像）。
    public func answerInDocument(question: String, documentId: String, indexPath: URL,
                                 topK: Int = 6, answerModel: String? = nil,
                                 history: [ChatTurn] = []) async throws -> (text: String, hits: [SearchHit]) {
        let chat = ChatClient(config: config, modelOverride: answerModel ?? config.answerModel)
        let hits = try await search(query: question, indexPath: indexPath, topK: topK,
                                    rerank: true, docId: documentId)
        let text = try await Synthesizer(chat: chat).answer(query: question, hits: hits, history: history)
        return (text, hits)
    }

    private func digestAnswer(question: String, recs: [Index.RecordingRow], chat: ChatClient,
                              history: [ChatTurn] = []) async throws -> String {
        var src = ""
        for r in recs {
            let date = String(r.recordedAt.prefix(10))
            src += "## \(date) · \(r.title)（\(r.id)）\n\(r.summary ?? "（该条暂无摘要）")\n\n"
        }
        let system = """
        你基于若干场会议的摘要回答用户的汇总类问题。规则：
        - 按时间/会议组织，简洁清楚，用中文。\(todayAnchor())
        - 只用提供的摘要内容，不要臆造；某条没有摘要就注明"该条暂无摘要"。
        - 如有对话历史，用它理解指代并接着上文说。
        \(zhWritingStyle)
        """
        let hist = renderHistory(history)
        let histBlock = hist.isEmpty ? "" : "对话历史：\n\(hist)\n\n"
        return try await chat.complete(system: system,
            user: "\(histBlock)用户问题：\(question)\n\n相关会议摘要：\n\(src)", maxTokens: 3000)
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
