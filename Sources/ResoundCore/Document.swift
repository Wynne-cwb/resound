import Foundation

/// document.yaml — schema: resound.document/1
/// 导入的外部文档（P1：markdown / txt）。人可编辑，手写 YAML（依赖少，仿 RecordingManifest）。
public struct DocumentManifest {
    public let id: String
    public var title: String
    public var sourceFormat: String     // markdown | txt（P3 起扩展 pdf/docx/…）
    public var importedAt: String       // ISO8601，带时区
    public var tags: [String]
    public var links: [String]          // 关联，如 "recording:2026-06-18-1430-standup"

    public init(id: String, title: String, sourceFormat: String,
                importedAt: String, tags: [String] = [], links: [String] = []) {
        self.id = id
        self.title = title
        self.sourceFormat = sourceFormat
        self.importedAt = importedAt
        self.tags = tags
        self.links = links
    }

    /// 关联的录音 id（解析 "recording:<id>" 前缀）。
    public var linkedRecordingIds: [String] {
        links.compactMap { $0.hasPrefix("recording:") ? String($0.dropFirst("recording:".count)) : nil }
    }

    public func yaml() -> String {
        let tagList = tags.map { yamlQuote($0) }.joined(separator: ", ")
        let linkList = links.map { yamlQuote($0) }.joined(separator: ", ")
        return """
        schema: resound.document/1
        id: \(yamlQuote(id))
        title: \(yamlQuote(title))
        source_format: \(yamlQuote(sourceFormat))
        imported_at: \(importedAt)
        tags: [\(tagList)]
        links: [\(linkList)]

        """
    }
}

// MARK: - 解析 / 扫描（自由函数，索引管线无需持有 vaultRoot 即可用）

/// 解析单个文档目录下的 document.yaml。容错：缺字段用默认值。
public func parseDocumentManifest(_ dir: URL) -> DocumentManifest? {
    let url = dir.appendingPathComponent("document.yaml")
    guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    var m: [String: String] = [:]
    for line in s.split(whereSeparator: \.isNewline) {
        if line.first == " " || line.first == "\t" { continue }
        let t = String(line)
        guard let r = t.range(of: ":") else { continue }
        let k = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        var v = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
        m[k] = v
    }
    return DocumentManifest(
        id: m["id"] ?? dir.lastPathComponent,
        title: m["title"] ?? dir.lastPathComponent,
        sourceFormat: m["source_format"] ?? "markdown",
        importedAt: m["imported_at"] ?? "",
        tags: parseYamlInlineList(m["tags"]),
        links: parseYamlInlineList(m["links"]))
}

/// 解析行内 YAML 列表 `[a, "b c", d]`。
func parseYamlInlineList(_ raw: String?) -> [String] {
    guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s != "[]" else { return [] }
    if s.hasPrefix("[") { s.removeFirst() }
    if s.hasSuffix("]") { s.removeLast() }
    return s.split(separator: ",").map {
        var e = $0.trimmingCharacters(in: .whitespaces)
        if e.count >= 2, e.hasPrefix("\""), e.hasSuffix("\"") { e = String(e.dropFirst().dropLast()) }
        return e
    }.filter { !$0.isEmpty }
}

/// 读文档正文（content.md）。
public func documentContent(_ dir: URL) -> String? {
    try? String(contentsOf: dir.appendingPathComponent("content.md"), encoding: .utf8)
}

/// 文档列表项（轻量，扫盘构建；仿 RecordingSummary）。
public struct DocumentSummary: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let sourceFormat: String
    public let importedAt: String        // ISO8601
    public let tags: [String]
    public let dir: URL
    public let linkedRecordingIds: [String]

    public init(id: String, title: String, sourceFormat: String, importedAt: String,
                tags: [String], dir: URL, linkedRecordingIds: [String]) {
        self.id = id; self.title = title; self.sourceFormat = sourceFormat
        self.importedAt = importedAt; self.tags = tags; self.dir = dir
        self.linkedRecordingIds = linkedRecordingIds
    }
}

public func loadDocumentSummary(dir: URL) -> DocumentSummary? {
    guard let m = parseDocumentManifest(dir) else { return nil }
    return DocumentSummary(id: m.id, title: m.title, sourceFormat: m.sourceFormat,
                           importedAt: m.importedAt, tags: m.tags, dir: dir,
                           linkedRecordingIds: m.linkedRecordingIds)
}

public func listDocuments(vaultRoot: URL) -> [DocumentSummary] {
    findDocuments(vaultRoot).compactMap { loadDocumentSummary(dir: $0) }
        .sorted { $0.importedAt < $1.importedAt }
}

/// 反查关联到某录音的文档正文（生成纪要时把文档当背景用）。
/// 事实源是各 document.yaml 的 links；读不到/空正文的文档跳过。按导入时间排序。
public func linkedDocumentTexts(vaultRoot: URL, recordingId: String) -> [(title: String, text: String)] {
    listDocuments(vaultRoot: vaultRoot)
        .filter { $0.linkedRecordingIds.contains(recordingId) }
        .compactMap { doc in
            guard let text = documentContent(doc.dir),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (doc.title, text)
        }
}

/// 递归找 documents/ 下所有含 document.yaml 的目录。
public func findDocuments(_ vaultRoot: URL) -> [URL] {
    let root = vaultRoot.appendingPathComponent("documents")
    guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
    var dirs: [URL] = []
    for case let f as URL in en where f.lastPathComponent == "document.yaml" {
        dirs.append(f.deletingLastPathComponent())
    }
    return dirs.sorted { $0.path < $1.path }
}

// MARK: - DocumentStore（vault 读写）

public struct DocumentStore {
    public let vaultRoot: URL
    public init(vaultRoot: URL) { self.vaultRoot = vaultRoot }

    /// documents/YYYY/MM/<id>/
    public func documentDir(id: String, date: Date) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy"
        let year = f.string(from: date)
        f.dateFormat = "MM"
        let month = f.string(from: date)
        return vaultRoot
            .appendingPathComponent("documents")
            .appendingPathComponent(year)
            .appendingPathComponent(month)
            .appendingPathComponent(id)
    }

    public func allDocumentDirs() -> [URL] { findDocuments(vaultRoot) }

    /// 导入：生成 id → 写 document.yaml + content.md + original.<ext>，返回 manifest 与目录。
    /// `originalFileURL` 非 nil（P3 富格式）→ 原样拷贝真实原件为 original.<真实扩展名>；
    /// nil（P1 md/txt、粘贴文本）→ 沿用旧逻辑按 content 写 original.<ext>（与现状逐字节一致）。
    @discardableResult
    public func importDocument(title rawTitle: String, text: String, sourceFormat: String,
                               tags: [String] = [], links: [String] = [],
                               date: Date = Date(),
                               originalFileURL: URL? = nil) throws -> (manifest: DocumentManifest, dir: URL) {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? firstLineTitle(text) : rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let (id, dir) = uniqueIdAndDir(title: title, date: date)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let manifest = DocumentManifest(
            id: id, title: title, sourceFormat: sourceFormat,
            importedAt: iso8601(date), tags: tags, links: links)
        try manifest.yaml().data(using: .utf8)?.write(to: dir.appendingPathComponent("document.yaml"))
        let data = text.data(using: .utf8)
        try data?.write(to: dir.appendingPathComponent("content.md"))
        // 原件留档
        if let src = originalFileURL {
            let srcExt = src.pathExtension.isEmpty ? "bin" : src.pathExtension.lowercased()
            let dest = dir.appendingPathComponent("original.\(srcExt)")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: src, to: dest)
        } else {
            let ext = sourceFormat == "txt" ? "txt" : "md"
            try data?.write(to: dir.appendingPathComponent("original.\(ext)"))
        }
        return (manifest, dir)
    }

    /// 删除整篇文档目录。
    public func deleteDocument(id: String, date: Date) throws {
        try? FileManager.default.removeItem(at: documentDir(id: id, date: date))
    }

    /// 就地重写某目录的 document.yaml（编辑标题/标签/关联用）。保留 id/source_format/imported_at。
    /// 返回新的 manifest（nil = 该目录不是合法文档）。
    @discardableResult
    public func updateManifest(dir: URL, title: String? = nil, tags: [String]? = nil,
                               links: [String]? = nil) throws -> DocumentManifest? {
        guard let old = parseDocumentManifest(dir) else { return nil }
        let m = DocumentManifest(
            id: old.id,
            title: title ?? old.title,
            sourceFormat: old.sourceFormat,
            importedAt: old.importedAt,
            tags: tags ?? old.tags,
            links: links ?? old.links)
        try m.yaml().data(using: .utf8)?.write(to: dir.appendingPathComponent("document.yaml"))
        return m
    }

    // 生成稳定 id：yyyy-MM-dd-<slug>，目录冲突则追加 -2/-3…
    private func uniqueIdAndDir(title: String, date: Date) -> (String, URL) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: date)
        let base = "\(day)-\(String(slugify(title).prefix(60)))"
        var id = base
        var n = 2
        while FileManager.default.fileExists(atPath: documentDir(id: id, date: date).path) {
            id = "\(base)-\(n)"; n += 1
        }
        return (id, documentDir(id: id, date: date))
    }
}

// MARK: - helpers
// 复用 IngestPipeline 的 slugify(_:) / iso8601(_:)（保留字母数字+CJK，转 '-' 合并）。

func firstLineTitle(_ text: String) -> String {
    for raw in text.split(whereSeparator: \.isNewline) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        while line.hasPrefix("#") { line.removeFirst() }
        line = line.trimmingCharacters(in: .whitespaces)
        if !line.isEmpty { return String(line.prefix(80)) }
    }
    return "未命名文档"
}
