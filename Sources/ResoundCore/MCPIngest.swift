import Foundation

/// 把外部链接落成 vault 文档：imported（取回正文→入库+索引）/ link-only（只存 URL，不索引）。
/// 复用现有文档管线（DocumentStore + IndexPipeline.indexDocument），与本地导入文档同一套检索/问答/纪要。
public enum MCPIngest {
    /// 已索引外部文档：写 content.md + external 块 + 关联录音 → 建索引。返回 doc id。
    @discardableResult
    public static func ingestImported(_ doc: FetchedExternalDoc, source: MCPSource, url: String,
                                      recordingId: String?, vaultRoot: URL, indexPath: URL,
                                      config: Config, enrichContext: Bool = true,
                                      log: (String) -> Void = { _ in }) async throws -> String {
        let ext = ExternalDocInfo(sourceId: source.id, kind: source.kind.rawValue, url: url,
                                  form: "imported", contentVersion: doc.version, lastSync: iso8601(Date()))
        let store = DocumentStore(vaultRoot: vaultRoot)
        let links = recordingId.map { ["recording:\($0)"] } ?? []
        let (manifest, dir) = try store.importDocument(
            title: doc.title, text: doc.markdown, sourceFormat: "external",
            links: links, external: ext)
        log("📄 入库：\(manifest.id)（\(doc.markdown.count) 字）")
        try await IndexPipeline(config: config).indexDocument(docDir: dir, indexPath: indexPath, enrichContext: enrichContext)
        return manifest.id
    }

    /// 仅链接引用：存标题 + URL，不取正文、不进索引（降级态）。返回 doc id。
    @discardableResult
    public static func saveLinkOnly(url: String, source: MCPSource?, title: String?,
                                    recordingId: String?, vaultRoot: URL) throws -> String {
        let ext = ExternalDocInfo(sourceId: source?.id, kind: source?.kind.rawValue, url: url,
                                  form: "link", contentVersion: nil, lastSync: nil)
        let store = DocumentStore(vaultRoot: vaultRoot)
        let links = recordingId.map { ["recording:\($0)"] } ?? []
        let (m, _) = try store.importDocument(
            title: title ?? SourceAdapter.titleFromURL(url), text: "",
            sourceFormat: "external", links: links, external: ext)
        return m.id
    }

    /// 同步一篇已索引外部文档：重新取回正文 → 重写 content.md → 重建该文档索引。
    /// （版本戳短路——戳没变就跳过——待适配器能返回版本后再加；当前无条件重取，靠 embedding_cache 摊薄。）
    @discardableResult
    public static func resync(docDir: URL, vaultRoot: URL, indexPath: URL, config: Config,
                              bearer: (MCPSource) async -> String?,
                              log: (String) -> Void = { _ in }) async throws -> Bool {
        guard let m = parseDocumentManifest(docDir), let ext = m.external, ext.form == "imported" else { return false }
        let sources = MCPSourceStore.load()
        guard let src = sources.first(where: { $0.id == ext.sourceId }) ?? MCPSourceStore.source(forURL: ext.url, in: sources),
              src.status == .connected else { return false }
        let token = await bearer(src)
        guard let session = MCPClientSession.make(for: src, bearer: token) else { return false }
        try await session.connect()
        let doc = try await SourceAdapter.fetchContent(url: ext.url, kind: src.kind, session: session)
        await session.disconnect()
        // 重写 content.md（保留 manifest，更新 external.lastSync/version）
        try doc.markdown.data(using: .utf8)?.write(to: docDir.appendingPathComponent("content.md"))
        var newExt = ext; newExt.contentVersion = doc.version; newExt.lastSync = iso8601(Date())
        let store = DocumentStore(vaultRoot: vaultRoot)
        try? store.writeExternalManifest(dir: docDir, manifest: m, external: newExt)
        try await IndexPipeline(config: config).indexDocument(docDir: docDir, indexPath: indexPath, enrichContext: false)
        log("🔄 已同步：\(m.id)")
        return true
    }
}

extension DocumentStore {
    /// 就地重写带 external 块的 document.yaml（同步时更新 lastSync/version 用）。
    func writeExternalManifest(dir: URL, manifest: DocumentManifest, external: ExternalDocInfo) throws {
        let m = DocumentManifest(id: manifest.id, title: manifest.title, sourceFormat: manifest.sourceFormat,
                                 importedAt: manifest.importedAt, tags: manifest.tags, links: manifest.links,
                                 external: external)
        try m.yaml().data(using: .utf8)?.write(to: dir.appendingPathComponent("document.yaml"))
    }
}
