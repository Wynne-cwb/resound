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
            let manifest = try parseManifest(recDir.appendingPathComponent("recording.yaml"))
            let tURL = recDir.appendingPathComponent("transcript.json")
            guard let tData = try? Data(contentsOf: tURL),
                  let transcript = try? JSONDecoder().decode(Transcript.self, from: tData) else {
                log("  ⚠️ 跳过（无 transcript.json）：\(manifest.id)")
                continue
            }
            let chunks = chunker.chunk(transcript)
            try index.upsertRecording(id: manifest.id, title: manifest.title,
                recordedAt: manifest.recordedAt, durationSec: manifest.durationSec,
                source: manifest.source, language: manifest.language)
            try index.deleteChunks(recordingId: manifest.id)   // 幂等重建

            var contexts: [Int: String] = [:]
            if enrichContext {
                let docText = transcript.segments.map { $0.text }.joined()
                contexts = try await enrichAll(chunks: chunks, document: docText, index: index,
                    model: contextModel ?? config.contextModel, log: log)
            }

            for batch in chunks.chunked(into: 32) {
                let texts = batch.map { c -> String in
                    if let ctx = contexts[c.index] { return "\(ctx)\n\(c.text)" }
                    return c.text
                }
                let vecs = try await embedder.embedDocuments(texts)
                for (chunk, vec) in zip(batch, vecs) {
                    try index.insertChunk(recordingId: manifest.id, idx: chunk.index,
                        text: chunk.text, context: contexts[chunk.index],
                        start: chunk.start, end: chunk.end, personId: nil, embedding: vec)
                }
            }
            totalChunks += chunks.count
            log("  ✓ \(manifest.id)：\(chunks.count) chunks\(enrichContext ? "（含上下文）" : "")")
        }
        log("✅ 索引完成：\(recordings.count) 录音 / \(totalChunks) chunks → \(indexPath.path)")
    }

    // MARK: 检索（hybrid + RRF；rerank 留待下一步）

    public func search(query: String, indexPath: URL, topK: Int = 5, pool: Int = 40,
                       rerank: Bool = false, rerankModel: String? = nil,
                       rerankCandidates: Int = 15) async throws -> [SearchHit] {
        let index = try Index(path: indexPath, dim: config.embeddingDim)
        let qvec = try await EmbeddingClient(config: config).embedQuery(query)
        let vHits = try index.vectorSearch(qvec, k: pool)
        let fHits = try index.ftsSearch(query, k: pool)
        let fused = rrf([vHits, fHits], topK: rerank ? rerankCandidates : topK).map { $0.hit }
        guard rerank else { return Array(fused.prefix(topK)) }

        let chat = ChatClient(config: config, modelOverride: rerankModel ?? config.rerankModel)
        return try await Reranker(chat: chat).rerank(query: query, candidates: fused, topK: topK)
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
        language: m["language"] ?? "")
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
