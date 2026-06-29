import Foundation

/// 模块 A：外部知识源（MCP connector）注册表。
/// 「机器/账号级配置」——存 App Support `mcp-sources.json`（不进 vault）；**密钥不在这里**，在 Keychain（见 MCPOAuth）。

public enum MCPSourceKind: String, Codable, Sendable, CaseIterable {
    case notion, atlassian, google, figma, custom
}

public enum MCPSourceTransport: String, Codable, Sendable {
    case remote   // HTTP / SSE
    case local    // stdio 子进程（Wave 4 接通连接，本期可存配置）
}

public enum MCPSourceAuth: String, Codable, Sendable {
    case oauth, token, none
}

public enum MCPSourceStatus: String, Codable, Sendable {
    case connected, expired, disconnected
}

public struct MCPSource: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var kind: MCPSourceKind
    public var name: String
    public var transport: MCPSourceTransport
    // remote
    public var url: String?
    public var auth: MCPSourceAuth
    public var needsClientId: Bool
    public var clientId: String?
    /// 需手动 client_id + client_secret + loopback redirect（如 Google：无 DCR，Desktop OAuth）。
    public var needsClientSecret: Bool?
    /// 显式申请的 OAuth scope（Google 等需指定；DCR 来源留空）。
    public var oauthScopes: [String]?
    // local (stdio)
    public var command: String?
    public var args: [String]?
    public var env: [String: String]?
    // 运行态 / 展示
    public var status: MCPSourceStatus
    public var account: String?
    public var scope: String?
    public var lastSync: String?
    public var hostPatterns: [String]
    public var builtin: Bool

    public init(id: String, kind: MCPSourceKind, name: String, transport: MCPSourceTransport = .remote,
                url: String? = nil, auth: MCPSourceAuth = .oauth, needsClientId: Bool = false, clientId: String? = nil,
                needsClientSecret: Bool? = nil, oauthScopes: [String]? = nil,
                command: String? = nil, args: [String]? = nil, env: [String: String]? = nil,
                status: MCPSourceStatus = .disconnected, account: String? = nil, scope: String? = nil,
                lastSync: String? = nil, hostPatterns: [String] = [], builtin: Bool = false) {
        self.id = id; self.kind = kind; self.name = name; self.transport = transport
        self.url = url; self.auth = auth; self.needsClientId = needsClientId; self.clientId = clientId
        self.needsClientSecret = needsClientSecret; self.oauthScopes = oauthScopes
        self.command = command; self.args = args; self.env = env
        self.status = status; self.account = account; self.scope = scope
        self.lastSync = lastSync; self.hostPatterns = hostPatterns; self.builtin = builtin
    }

    /// host 是否归这个来源管（粘贴链接路由用）。匹配 host 后缀（`atlassian.net` 命中 `acme.atlassian.net`）。
    public func matchesHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return hostPatterns.contains { p in
            let pat = p.lowercased()
            return h == pat || h.hasSuffix("." + pat) || h.hasSuffix(pat)
        }
    }
}

public enum MCPSourcePresets {
    /// 内置远程来源（OAuth + DCR）。URL 以各家最新文档为准，此处为预填默认。
    public static func builtins() -> [MCPSource] {
        [
            MCPSource(id: "src_notion", kind: .notion, name: "Notion",
                      url: "https://mcp.notion.com/mcp", auth: .oauth,
                      scope: "Notion 工作区", hostPatterns: ["notion.so", "notion.site"], builtin: true),
            MCPSource(id: "src_atlassian", kind: .atlassian, name: "Jira / Confluence",
                      url: "https://mcp.atlassian.com/v1/mcp", auth: .oauth,
                      scope: "Jira + Confluence", hostPatterns: ["atlassian.net"], builtin: true),
            // Google Drive 预设已移除（企业账号普遍无法自建 OAuth 客户端，且 Drive MCP API 需 Workspace
            // Developer Preview 资格——非代码问题）。手动凭证 + loopback OAuth 骨架（needsClientSecret /
            // MCPLoopbackOAuth / credsModal）保留待用，IT 配合后恢复此预设即可。详见 DECISIONS 2026-06-29。
        ]
    }
}

/// `mcp-sources.json` 读写：用户配置（自定义来源 + 内置来源的状态）落盘；内置缺省自动补齐。
public struct MCPSourceStore {
    public static func fileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Resound/mcp-sources.json")
    }

    /// 加载：磁盘里的来源 ∪ 内置预设（内置以磁盘存的状态为准，缺失则补默认）。内置在前、自定义在后。
    public static func load() -> [MCPSource] {
        let saved: [MCPSource] = (try? Data(contentsOf: fileURL())).flatMap {
            try? JSONDecoder().decode([MCPSource].self, from: $0)
        } ?? []
        var byId = Dictionary(uniqueKeysWithValues: saved.map { ($0.id, $0) })
        var out: [MCPSource] = []
        for b in MCPSourcePresets.builtins() {
            if let s = byId[b.id] {                 // 用存的运行态（status/account/clientId/lastSync），配置字段以预设为准（防漂移）
                var merged = s
                merged.url = b.url; merged.hostPatterns = b.hostPatterns
                merged.kind = b.kind; merged.builtin = true; merged.name = b.name
                merged.auth = b.auth; merged.needsClientId = b.needsClientId
                merged.needsClientSecret = b.needsClientSecret; merged.oauthScopes = b.oauthScopes
                merged.scope = b.scope
                out.append(merged); byId.removeValue(forKey: b.id)
            } else { out.append(b) }
        }
        out.append(contentsOf: saved.filter { byId[$0.id] != nil && !$0.builtin })   // 自定义来源
        return out
    }

    public static func save(_ sources: [MCPSource]) {
        let url = fileURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(sources) { try? data.write(to: url) }
    }

    public static func upsert(_ source: MCPSource) {
        var all = load()
        if let i = all.firstIndex(where: { $0.id == source.id }) { all[i] = source } else { all.append(source) }
        save(all)
    }

    /// 把一个 URL 路由到管它的来源（按 host 匹配）。
    public static func source(forURL urlString: String, in sources: [MCPSource]? = nil) -> MCPSource? {
        guard let host = URL(string: urlString)?.host else { return nil }
        return (sources ?? load()).first { $0.matchesHost(host) }
    }
}
