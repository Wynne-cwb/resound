import Foundation
import MCP

/// 模块 B：把 Resound 会议知识库作为 MCP 服务器（stdio）暴露给 coding agent（Claude Code / Codex）。
/// 只读共享 index.sqlite + vault；被 agent 作为子进程拉起，GUI 开不开都不影响、零 IPC。
/// 暴露**检索原语**（非高层 ask 黑盒）：search_meetings / get_recording / get_document / list_recordings。
///
/// 工具逻辑放在可独立调用的方法上（`searchMeetings`/`getRecording`/…），CallTool handler 与
/// `mcp-selftest` 都走它们——后者免起真实传输即可无头验证。
public struct MCPServerRunner: Sendable {
    let config: Config
    let indexPath: URL

    public init(config: Config, indexPath: URL) {
        self.config = config
        self.indexPath = indexPath
    }

    // MARK: 启动（stdio）

    public func run() async throws {
        let server = Server(
            name: "resound",
            version: "0.1.0",
            instructions: """
            Resound 是用户的个人会议知识库（录音转录 + 导入文档）。\
            先用 search_meetings 找相关片段，再用 get_recording / get_document 取全文。\
            list_recordings 可浏览全部会议。
            """,
            capabilities: .init(tools: .init(listChanged: false)))

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: MCPServerRunner.toolList)
        }
        await server.withMethodHandler(CallTool.self) { params in
            do {
                let json = try await self.dispatch(name: params.name, args: params.arguments)
                return CallTool.Result(content: [.text(json)], isError: false)
            } catch {
                return CallTool.Result(content: [.text("错误：\(error)")], isError: true)
            }
        }

        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }

    /// 无头自检（`resound mcp selftest` 用）：列工具 + 跑 list/search + 打印安装命令，返回可读报告。
    /// 不起真实传输，直接调工具逻辑——验证检索/取文/内容策略全链路。
    public func runSelftest(query: String) async -> String {
        var out = "== 已注册工具 ==\n"
        for t in Self.toolList { out += "· \(t.name) — \(t.description)\n" }
        out += "\n== list_recordings (limit 5) ==\n"
        out += (try? listRecordingsTool(["limit": 5])) ?? "(失败)"
        out += "\n\n== search_meetings(\"\(query)\") ==\n"
        do { out += try await searchMeetings(["query": .string(query), "top_k": 5]) }
        catch { out += "(失败：\(error))" }
        out += "\n\n== 安装命令（手动兜底）==\n"
        let path = MCPInstall.resoundExecutablePath()
        for k in MCPClientKind.allCases {
            out += "· \(k.displayName)\(MCPInstall.isClientDetected(k) ? "（已检测到）" : "（未检测到）"): "
                + "\(MCPInstall.installCommand(k, resoundPath: path))\n"
        }
        return out
    }

    func dispatch(name: String, args: [String: Value]?) async throws -> String {
        let a = args ?? [:]
        switch name {
        case "search_meetings":  return try await searchMeetings(a)
        case "get_recording":    return try await getRecording(a)
        case "get_document":     return try await getDocument(a)
        case "list_recordings":  return try listRecordingsTool(a)
        default: throw MCPServerError.unknownTool(name)
        }
    }

    // MARK: 工具定义（snake_case；swift-sdk 要求）

    static let toolList: [Tool] = [
        Tool(name: "search_meetings",
             description: "在所有会议录音与导入文档里做混合检索，返回最相关的片段及出处。先用它定位，再用 get_recording/get_document 取全文。",
             inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "检索词或自然语言问题"],
                    "speaker": ["type": "string", "description": "可选：按说话人 person_id 过滤"],
                    "source": ["type": "string", "description": "可选：限定来源", "enum": ["recording", "document"]],
                    "date_from": ["type": "string", "description": "可选：录音日期下界 yyyy-MM-dd"],
                    "date_to": ["type": "string", "description": "可选：录音日期上界 yyyy-MM-dd"],
                    "top_k": ["type": "integer", "description": "返回条数（默认 8）"],
                ],
                "required": ["query"],
             ]),
        Tool(name: "get_recording",
             description: "按 id 取一场录音的全文（摘要 / 逐句转录 / 两者）。id 来自 search_meetings 或 list_recordings。",
             inputSchema: [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "录音 id"],
                    "include": ["type": "string", "description": "返回哪部分（默认 both）", "enum": ["transcript", "summary", "both"]],
                ],
                "required": ["id"],
             ]),
        Tool(name: "get_document",
             description: "按 id 取一篇导入文档的正文。外部来源（Notion/Jira 等）文档的内容多少受服务器「内容策略」约束。",
             inputSchema: [
                "type": "object",
                "properties": ["id": ["type": "string", "description": "文档 id"]],
                "required": ["id"],
             ]),
        Tool(name: "list_recordings",
             description: "列出全部会议录音（最新在前），可选按日期范围过滤。用于浏览与拿 id。",
             inputSchema: [
                "type": "object",
                "properties": [
                    "date_from": ["type": "string", "description": "可选 yyyy-MM-dd"],
                    "date_to": ["type": "string", "description": "可选 yyyy-MM-dd"],
                    "limit": ["type": "integer", "description": "最多返回条数（默认 50）"],
                ],
             ]),
    ]

    // MARK: 工具实现

    func searchMeetings(_ args: [String: Value]) async throws -> String {
        guard let query = args["query"]?.stringValue, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw MCPServerError.badArgs("query 必填")
        }
        let topK = args["top_k"]?.intValue ?? 8
        var filters = Index.Filters()
        if let sp = args["speaker"]?.stringValue, !sp.isEmpty { filters.speakers = [sp] }
        if let src = args["source"]?.stringValue, src == "recording" || src == "document" { filters.sourceKind = src }
        let from = args["date_from"]?.stringValue
        let to = args["date_to"]?.stringValue
        if from != nil || to != nil {
            filters.dateRange = (from: from ?? "0000-01-01", to: to ?? "9999-12-31")
        }

        let hits = try await IndexPipeline(config: config).search(
            query: query, indexPath: indexPath, topK: topK, rerank: true, filters: filters)

        // 录音命中补标题（一次批量查）。
        let recIds = Array(Set(hits.filter { !$0.isDocument }.map { $0.recordingId }))
        var titleById: [String: String] = [:]
        if !recIds.isEmpty {
            let index = try Index(path: indexPath, dim: config.embeddingDim)
            for r in index.recordings(ids: recIds) { titleById[r.id] = r.title }
        }

        let results: [[String: Any]] = hits.map { h in
            var o: [String: Any] = [
                "type": h.isDocument ? "document" : "recording",
                "snippet": h.text,
            ]
            if h.isDocument {
                o["id"] = h.docId ?? ""
                o["title"] = h.docTitle ?? h.docId ?? "未命名文档"
            } else {
                o["id"] = h.recordingId
                o["title"] = titleById[h.recordingId] ?? h.recordingId
                if let d = h.recordingDate { o["date"] = d }
                if let p = h.personId { o["speaker"] = p }
                o["time"] = "\(fmtTime(h.start))-\(fmtTime(h.end))"
            }
            return o
        }
        return jsonString(["count": results.count, "results": results])
    }

    func getRecording(_ args: [String: Value]) async throws -> String {
        guard let id = args["id"]?.stringValue else { throw MCPServerError.badArgs("id 必填") }
        let include = args["include"]?.stringValue ?? "both"
        let vault = try vaultURL()
        guard let rec = listRecordings(vaultRoot: vault).first(where: { $0.id == id }) else {
            throw MCPServerError.notFound("录音 \(id)")
        }
        var parts: [String] = ["# \(rec.title)", "日期：\(String(rec.recordedAt.prefix(10)))  时长：\(rec.durationSec)s"]
        if include != "transcript" {
            if let s = try? String(contentsOf: rec.dir.appendingPathComponent("summary.md"), encoding: .utf8),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append("## 摘要\n\n\(s)")
            }
        }
        if include != "summary" {
            if let t = loadTranscript(rec.transcriptURL) {
                let body = t.segments.map { "[\(fmtTime($0.start))] \($0.text)" }.joined(separator: "\n")
                parts.append("## 逐句转录\n\n\(body)")
            }
        }
        return parts.joined(separator: "\n\n")
    }

    func getDocument(_ args: [String: Value]) throws -> String {
        guard let id = args["id"]?.stringValue else { throw MCPServerError.badArgs("id 必填") }
        let vault = try vaultURL()
        guard let doc = listDocuments(vaultRoot: vault).first(where: { $0.id == id }) else {
            throw MCPServerError.notFound("文档 \(id)")
        }
        let ext = parseExternalBlock(doc.dir)
        let content = documentContent(doc.dir) ?? ""
        let policy = MCPServerSettings.load().contentPolicy
        return renderDocument(title: doc.title, content: content, external: ext, policy: policy)
    }

    func listRecordingsTool(_ args: [String: Value]) throws -> String {
        let vault = try vaultURL()
        let limit = args["limit"]?.intValue ?? 50
        let from = args["date_from"]?.stringValue
        let to = args["date_to"]?.stringValue
        var recs = listRecordings(vaultRoot: vault).reversed().map { $0 }   // 最新在前
        if from != nil || to != nil {
            let lo = from ?? "0000-01-01", hi = to ?? "9999-12-31"
            recs = recs.filter { let d = String($0.recordedAt.prefix(10)); return d >= lo && d <= hi }
        }
        let out: [[String: Any]] = recs.prefix(limit).map {
            ["id": $0.id, "title": $0.title, "date": String($0.recordedAt.prefix(10)), "duration_sec": $0.durationSec]
        }
        return jsonString(["count": out.count, "recordings": out])
    }

    // MARK: helpers

    private func vaultURL() throws -> URL {
        guard let v = config.vaultPath, !v.isEmpty else { throw MCPServerError.noVault }
        return URL(fileURLWithPath: v)
    }

    /// 外部文档按内容策略裁剪；本地文档恒返回全文；form:link 恒只给链接。
    func renderDocument(title: String, content: String, external: ExternalDocInfo?, policy: MCPContentPolicy) -> String {
        guard let ext = external else { return "# \(title)\n\n\(content)" }          // 本地文档：全文
        if ext.isLinkOnly { return "# \(title)\n\n链接：\(ext.url)\n（仅链接引用，无可检索正文）" }
        switch policy {
        case .full:    return "# \(title)\n\n\(content)\n\n来源：\(ext.url)"
        case .link:    return "# \(title)\n\n链接：\(ext.url)\n（服务器内容策略=仅链接；用你自己接入的 MCP 取实时正文）"
        case .summary:
            let snip = String(content.prefix(600))
            let more = content.count > 600 ? "…" : ""
            return "# \(title)\n\n\(snip)\(more)\n\n来源：\(ext.url)\n（服务器内容策略=片段+链接；如需全文用你自己接入的 MCP 取）"
        }
    }
}

public enum MCPServerError: Error, CustomStringConvertible {
    case unknownTool(String)
    case badArgs(String)
    case notFound(String)
    case noVault
    public var description: String {
        switch self {
        case .unknownTool(let n): return "未知工具：\(n)"
        case .badArgs(let m): return "参数错误：\(m)"
        case .notFound(let w): return "未找到：\(w)"
        case .noVault: return "未配置录音库（vault）路径"
        }
    }
}

func fmtTime(_ sec: Double) -> String {
    let s = Int(sec.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
}

/// 把 JSON 兼容对象序列化成紧凑字符串（不转义斜杠，URL 更干净）。
func jsonString(_ obj: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
          let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}
