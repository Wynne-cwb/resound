import Foundation
import MCP

/// 从外部来源取回的文档。
public struct FetchedExternalDoc: Sendable, Equatable {
    public var title: String
    public var markdown: String
    public var version: String?    // 版本戳（last_edited_time/updated/modifiedTime），判变更用
}

/// 模块 A 客户端封装：连一个 MCP server，列/调工具、读资源。
/// 远程来源走 HTTP（Bearer token 经 requestModifier 注入）；本地来源走子进程 stdio（Wave 4）。
public actor MCPClientSession {
    private let client: Client
    private let transport: any Transport

    /// 远程 HTTP 来源。
    public init(endpoint: URL, bearer: String?) {
        let token = bearer
        self.transport = HTTPClientTransport(
            endpoint: endpoint,
            streaming: false,
            requestModifier: { req in
                guard let token else { return req }
                var r = req
                r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                return r
            })
        self.client = Client(name: "resound", version: "0.1.0")
    }

    /// 本地 stdio 来源（起子进程）。
    public init(command: String, arguments: [String], environment: [String: String]) {
        self.transport = StdioProcessTransport(command: command, arguments: arguments, environment: environment)
        self.client = Client(name: "resound", version: "0.1.0")
    }

    /// 按来源构造会话（远程/本地自动分流）。`bearer` 仅远程用。
    public static func make(for source: MCPSource, bearer: String?) -> MCPClientSession? {
        switch source.transport {
        case .remote:
            guard let endpoint = source.url.flatMap(URL.init(string:)) else { return nil }
            return MCPClientSession(endpoint: endpoint, bearer: bearer)
        case .local:
            guard let cmd = source.command, !cmd.isEmpty else { return nil }
            return MCPClientSession(command: cmd, arguments: source.args ?? [], environment: source.env ?? [:])
        }
    }

    public func connect() async throws { _ = try await client.connect(transport: transport) }
    public func disconnect() async { await client.disconnect() }

    public func toolNames() async throws -> [String] {
        let (tools, _) = try await client.listTools()
        return tools.map { $0.name }
    }

    /// 列工具（含其 input schema 的参数名/必填项），供适配器按真实参数名调取回工具。
    public func tools() async throws -> [MCPToolInfo] {
        let (tools, _) = try await client.listTools()
        return tools.map { t in
            var params: [String] = []
            var required: [String] = []
            if case let .object(schema) = t.inputSchema {
                if case let .object(props)? = schema["properties"] { params = Array(props.keys) }
                if case let .array(req)? = schema["required"] {
                    required = req.compactMap { if case let .string(s) = $0 { return s } else { return nil } }
                }
            }
            return MCPToolInfo(name: t.name, paramNames: params, required: required)
        }
    }

    public func callToolText(_ name: String, arguments: [String: Value]) async throws -> String {
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        if isError == true { throw MCPClientError.toolError(name) }
        return content.compactMap { if case .text(let s) = $0 { return s } else { return nil } }
            .joined(separator: "\n")
    }

    public func readResourceText(_ uri: String) async throws -> String? {
        let contents = try await client.readResource(uri: uri)
        let texts = contents.compactMap { $0.text }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }
}

public enum MCPClientError: Error, CustomStringConvertible, LocalizedError {
    case toolError(String)
    case noContent
    case noFetchTool
    case notConnected
    public var errorDescription: String? { description }
    public var description: String {
        switch self {
        case .toolError(let n): return "工具调用出错：\(n)"
        case .noContent: return "未取到内容"
        case .noFetchTool: return "该来源未提供按链接取回文档的工具"
        case .notConnected: return "来源未连接"
        }
    }
}

/// MCP 工具的精简描述（名字 + input schema 参数名/必填项）。
public struct MCPToolInfo: Sendable {
    public let name: String
    public let paramNames: [String]
    public let required: [String]
    public init(name: String, paramNames: [String], required: [String]) {
        self.name = name; self.paramNames = paramNames; self.required = required
    }
}

/// 通用适配器：先试 MCP Resources（`resources/read` by URI），再**按工具真实 schema** 选取回工具并用其声明的参数名调用。
/// 关键：不同 server 取回工具名各异（Notion=`notion-fetch`、Atlassian=`fetch`），参数名也不同（多为 `id`，部分 `url`），
/// 且有的 server `additionalProperties:false`——所以只传它 schema 里声明的那一个键，URL 当值。
public enum SourceAdapter {
    /// 取回类工具名关键字（按优先级；命中越靠前越优先）。排除写操作/搜索。
    static let fetchKeywords = ["fetch", "retrieve", "get_page", "getpage", "get_document", "getdocument", "read_page", "read", "get"]
    static let urlishKeys = ["url", "uri", "link", "page_url", "pageurl", "href"]
    static let idishKeys = ["id", "page_id", "pageid", "uid", "entity_id", "ari", "uuid"]

    public static func fetchContent(url: String, kind: MCPSourceKind, session: MCPClientSession) async throws -> FetchedExternalDoc {
        // 1) Resources（部分 server 支持 resources/read by URI）
        if let text = try? await session.readResourceText(url), !text.isEmpty {
            return FetchedExternalDoc(title: titleFromURL(url), markdown: text, version: nil)
        }
        // 2) 按真实 schema 选取回工具，用其声明的参数名调
        let tools = (try? await session.tools()) ?? []
        guard let tool = bestFetchTool(tools) else { throw MCPClientError.noFetchTool }
        let key = argKey(for: tool) ?? "id"
        let text = try await session.callToolText(tool.name, arguments: [key: .string(url)])
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPClientError.noContent }
        return normalize(text, url: url)
    }

    /// 把取回的原始文本规整成可读文档：很多 server（如 Notion `notion-fetch`）返回的是 JSON 包裹
    /// `{title,url,text,...}`，正文在 `text` 字段且带一句「Here is the result …」前言——拆出正文 + 真实标题。
    static func normalize(_ raw: String, url: String) -> FetchedExternalDoc {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var body = (obj["text"] as? String) ?? (obj["content"] as? String)
                ?? (obj["markdown"] as? String) ?? (obj["body"] as? String) ?? raw
            body = stripFetchPreamble(body)
            if NotionMarkdown.looksLikeEnhanced(body) { body = NotionMarkdown.clean(body) }
            let titleRaw = (obj["title"] as? String) ?? ((obj["metadata"] as? [String: Any])?["title"] as? String)
            let title = titleRaw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 } ?? titleFromURL(url)
            let version = (obj["last_edited_time"] as? String) ?? (obj["updated"] as? String) ?? (obj["modifiedTime"] as? String)
            return FetchedExternalDoc(title: title, markdown: body, version: version)
        }
        var body = stripFetchPreamble(raw)
        if NotionMarkdown.looksLikeEnhanced(body) { body = NotionMarkdown.clean(body) }
        return FetchedExternalDoc(title: titleFromURL(url), markdown: body, version: nil)
    }

    /// 去掉部分 server 在正文前加的一句机器前言（如 Notion：`Here is the result of "view" for the Page with URL … as of …:`）。
    static func stripFetchPreamble(_ s: String) -> String {
        if s.hasPrefix("Here is the result"), let nl = s.firstIndex(of: "\n") {
            return String(s[s.index(after: nl)...])
        }
        return s
    }

    /// 从工具表里挑最合适的「按 URL/ID 取单条」工具。
    static func bestFetchTool(_ tools: [MCPToolInfo]) -> MCPToolInfo? {
        var best: (tool: MCPToolInfo, rank: Int)?
        for t in tools {
            let l = t.name.lowercased()
            if l.contains("create") || l.contains("update") || l.contains("delete") || l.contains("search") { continue }
            guard let rank = fetchKeywords.firstIndex(where: { l.contains($0) }) else { continue }
            if best == nil || rank < best!.rank { best = (t, rank) }
        }
        return best?.tool
    }

    /// 选该工具接收 URL 的参数名：优先 url 类，其次 id 类，再退化到唯一必填/唯一参数。
    static func argKey(for tool: MCPToolInfo) -> String? {
        let pairs = tool.paramNames.map { ($0, $0.lowercased()) }
        if let m = pairs.first(where: { urlishKeys.contains($0.1) }) { return m.0 }
        if let m = pairs.first(where: { idishKeys.contains($0.1) }) { return m.0 }
        if tool.required.count == 1 { return tool.required.first }
        if tool.paramNames.count == 1 { return tool.paramNames.first }
        return nil
    }

    public static func titleFromURL(_ url: String) -> String {
        guard let u = URL(string: url) else { return url }
        let last = u.lastPathComponent
        return last.isEmpty || last == "/" ? (u.host ?? url) : last
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}

/// 粘贴链接的四路结果（与设计稿 resolved/unconnected/unknown/noperm 对应）。
public enum LinkResolution: Sendable {
    case imported(FetchedExternalDoc, source: MCPSource)
    case unconnected(MCPSource)
    case unknown
    case noPermission(MCPSource)
}

/// URL 路由：host → 来源 → 取回/降级。`bearer` 由 OAuth/Keychain 提供（Wave 2 OAuth / Wave 3 触发）。
public enum ExternalLinkResolver {
    public static func resolve(url: String, sources: [MCPSource]? = nil,
                               bearer: (MCPSource) async -> String?) async -> LinkResolution {
        let all = sources ?? MCPSourceStore.load()
        guard let src = MCPSourceStore.source(forURL: url, in: all) else { return .unknown }
        guard src.status == .connected else { return .unconnected(src) }
        let token = await bearer(src)
        guard let session = MCPClientSession.make(for: src, bearer: token) else { return .unknown }
        do {
            try await session.connect()
            defer { Task { await session.disconnect() } }
            let doc = try await SourceAdapter.fetchContent(url: url, kind: src.kind, session: session)
            return .imported(doc, source: src)
        } catch {
            // 真实原因落盘便于排查（GUI 的 print 不进系统日志）。
            AppLog.log("MCP 取回失败 [\(src.kind.rawValue)] \(url) → \(error)")
            // 没有取回工具 / 取到空 → 不是权限问题，归为「无法取回」(unknown)；其余（连上但工具报错）→ 多半权限。
            if let e = error as? MCPClientError {
                switch e { case .noFetchTool, .noContent: return .unknown; default: break }
            }
            return .noPermission(src)
        }
    }
}
