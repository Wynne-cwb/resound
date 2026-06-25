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
    @discardableResult
    public func importDocument(title rawTitle: String, text: String, sourceFormat: String,
                               tags: [String] = [], links: [String] = [],
                               date: Date = Date()) throws -> (manifest: DocumentManifest, dir: URL) {
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
        // 原件留档（P1：与 content 同源；P3 起为真实原件）
        let ext = sourceFormat == "txt" ? "txt" : "md"
        try data?.write(to: dir.appendingPathComponent("original.\(ext)"))
        return (manifest, dir)
    }

    /// 删除整篇文档目录。
    public func deleteDocument(id: String, date: Date) throws {
        try? FileManager.default.removeItem(at: documentDir(id: id, date: date))
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
