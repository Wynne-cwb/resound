import Foundation

/// 对外提供「外部 MCP 接入」来源文档时给多少内容（全局开关）。
/// 录音/转录/摘要永远 full（agent 别处拿不到）；本配置只管**外部文档**。
public enum MCPContentPolicy: String, Codable, Sendable, CaseIterable {
    case full       // 完整内容
    case link       // 仅链接
    case summary    // 片段+链接（默认）
}

/// Resound MCP 服务器设置，存 App Support `mcp-server.json`（派生/机器级，不进 vault）。
/// 模块 B 服务器读 `contentPolicy`；`enabled` 供 App UI（Wave 3）。
public struct MCPServerSettings: Codable, Sendable {
    public var enabled: Bool
    public var contentPolicy: MCPContentPolicy

    public init(enabled: Bool = false, contentPolicy: MCPContentPolicy = .summary) {
        self.enabled = enabled
        self.contentPolicy = contentPolicy
    }

    public static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Resound/mcp-server.json")
    }

    public static func load() -> MCPServerSettings {
        guard let data = try? Data(contentsOf: fileURL()),
              let s = try? JSONDecoder().decode(MCPServerSettings.self, from: data) else {
            return MCPServerSettings()
        }
        return s
    }

    public func save() {
        let url = Self.fileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url) }
    }
}

/// 外部文档元信息（document.yaml 的 `external:` 块）。Wave 2 写入；本类型现在就位，
/// 让内容策略一旦有外部文档即生效。`form`: "imported"（有正文）| "link"（仅链接）。
public struct ExternalDocInfo: Sendable, Equatable, Hashable {
    public var sourceId: String?
    public var kind: String?
    public var url: String
    public var form: String         // imported | link
    public var contentVersion: String?
    public var lastSync: String?

    public var isLinkOnly: Bool { form == "link" }
}

/// 解析某文档目录 document.yaml 里的 `external:` 缩进块。无此块（普通本地文档）→ nil。
/// 简易缩进解析（与 parseDocumentManifest 同风格，依赖少）。
public func parseExternalBlock(_ dir: URL) -> ExternalDocInfo? {
    let url = dir.appendingPathComponent("document.yaml")
    guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    var inBlock = false
    var kv: [String: String] = [:]
    for raw in s.split(whereSeparator: \.isNewline) {
        let line = String(raw)
        if !inBlock {
            if line.trimmingCharacters(in: .whitespaces) == "external:" { inBlock = true }
            continue
        }
        // 块内：缩进行；遇到顶格非空行即结束。
        if let first = line.first, first != " ", first != "\t" { break }
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: ":") else { continue }
        let k = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        var v = String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
        kv[k] = v
    }
    guard let u = kv["url"], !u.isEmpty else { return nil }
    return ExternalDocInfo(sourceId: kv["source_id"], kind: kv["kind"], url: u,
                           form: kv["form"] ?? "imported",
                           contentVersion: kv["content_version"], lastSync: kv["last_sync"])
}
