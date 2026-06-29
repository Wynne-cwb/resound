import Foundation
import Security
import CryptoKit

/// 模块 A 的 OAuth 2.1 + PKCE + DCR 管道（非交互部分）。
/// Token 存 Keychain；PKCE/DCR/code↔token/refresh 都是无 UI 的 URLSession 调用。
/// **交互的浏览器授权（ASWebAuthenticationSession）在 App 层（Wave 3）触发**，拿到 code 后调这里 `exchange`。

// MARK: - Keychain token 存储（按来源 id）

public struct MCPToken: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var clientId: String?
    public var clientSecret: String?   // 手动凭证来源（Google）刷新时需带
    public var tokenEndpoint: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil,
                clientId: String? = nil, clientSecret: String? = nil, tokenEndpoint: String? = nil) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.clientId = clientId
        self.clientSecret = clientSecret; self.tokenEndpoint = tokenEndpoint
    }

    public var isExpired: Bool { expiresAt.map { $0 < Date().addingTimeInterval(60) } ?? false }
}

public enum MCPTokenStore {
    private static let service = "com.resound.mcp.oauth"

    public static func save(_ token: MCPToken, sourceId: String) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: sourceId]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    public static func load(sourceId: String) -> MCPToken? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: sourceId,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let t = try? JSONDecoder().decode(MCPToken.self, from: data) else { return nil }
        return t
    }

    public static func delete(sourceId: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: sourceId]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - PKCE

public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String   // S256

    public init() {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        self.verifier = Data(bytes).base64URLEncodedString()
        let hash = SHA256.hash(data: Data(verifier.utf8))
        self.challenge = Data(hash).base64URLEncodedString()
    }
}

// MARK: - OAuth HTTP（发现 / DCR / token 交换 / 刷新）

public struct OAuthServerMetadata: Decodable, Sendable {
    public let authorization_endpoint: String
    public let token_endpoint: String
    public let registration_endpoint: String?

    public init(authorization_endpoint: String, token_endpoint: String, registration_endpoint: String?) {
        self.authorization_endpoint = authorization_endpoint
        self.token_endpoint = token_endpoint
        self.registration_endpoint = registration_endpoint
    }

    /// Google 已知端点（其 MCP 无 DCR，不依赖发现；scope 由来源显式给定）。
    public static let google = OAuthServerMetadata(
        authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
        token_endpoint: "https://oauth2.googleapis.com/token",
        registration_endpoint: nil)
}

private struct ProtectedResourceMetadata: Decodable { let authorization_servers: [String]? }

public enum MCPOAuth {
    /// 按 MCP 授权规范发现授权服务器元信息，多候选鲁棒探测：
    /// ① RFC 9728 protected-resource metadata（`/.well-known/oauth-protected-resource`，含 path-aware 变体）→ 拿 authorization_servers；
    /// ② 对该 AS（或直接对 MCP endpoint）试 RFC 8414 `oauth-authorization-server` + OIDC `openid-configuration`（origin 与 path-aware 两种）。
    /// 全部失败 → 明确报「未发现 OAuth 配置」（而非抛原始 JSON 解码错误）。
    public static func discover(mcpEndpoint: URL) async throws -> OAuthServerMetadata {
        // ① protected-resource → authorization server
        for prURL in wellKnownCandidates(mcpEndpoint, suffix: "oauth-protected-resource") {
            guard let pr: ProtectedResourceMetadata = try? await fetchJSON(prURL),
                  let asStr = pr.authorization_servers?.first, let asURL = URL(string: asStr) else { continue }
            for metaURL in asMetadataCandidates(asURL) {
                if let meta = await tryASMetadata(metaURL) { return meta }
            }
        }
        // ② 直接对 MCP endpoint 试 AS metadata / OIDC
        for metaURL in asMetadataCandidates(mcpEndpoint) {
            if let meta = await tryASMetadata(metaURL) { return meta }
        }
        throw MCPOAuthError.discoveryFailed
    }

    /// well-known 候选：origin 根 + path-aware（RFC 8414 §3.1，把 `.well-known/<suffix>` 插在 host 与原 path 之间）。
    private static func wellKnownCandidates(_ url: URL, suffix: String) -> [URL] {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = comps.host else { return [] }
        var out: [URL] = []
        let scheme = comps.scheme ?? "https"
        let portPart = comps.port.map { ":\($0)" } ?? ""
        let base = "\(scheme)://\(host)\(portPart)"
        if let u = URL(string: "\(base)/.well-known/\(suffix)") { out.append(u) }   // origin 根
        let path = comps.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty, let u = URL(string: "\(base)/.well-known/\(suffix)/\(path)") { out.append(u) }   // path-aware
        return out
    }

    private static func asMetadataCandidates(_ url: URL) -> [URL] {
        wellKnownCandidates(url, suffix: "oauth-authorization-server") + wellKnownCandidates(url, suffix: "openid-configuration")
    }

    /// 取并校验 AS metadata：HTTP 200 + 能解出 authorization/token endpoint 才算数。
    private static func tryASMetadata(_ url: URL) async -> OAuthServerMetadata? {
        guard let meta: OAuthServerMetadata = try? await fetchJSON(url),
              !meta.authorization_endpoint.isEmpty, !meta.token_endpoint.isEmpty else { return nil }
        return meta
    }

    /// GET + 校验 200 + 解 JSON（非 2xx 或非 JSON → 抛错由调用方吞掉转候选）。
    private static func fetchJSON<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MCPOAuthError.discoveryFailed
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 动态客户端注册（RFC 7591）。返回 client_id。
    public static func registerClient(registrationEndpoint: String, redirectURI: String,
                                      clientName: String = "Resound") async throws -> String {
        guard let url = URL(string: registrationEndpoint) else { throw MCPOAuthError.badEndpoint }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "client_name": clientName,
            "redirect_uris": [redirectURI],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cid = obj["client_id"] as? String else { throw MCPOAuthError.registrationFailed }
        return cid
    }

    /// 构造授权 URL（App 用 ASWebAuthenticationSession 打开它）。
    public static func authorizeURL(metadata: OAuthServerMetadata, clientId: String,
                                    redirectURI: String, pkce: PKCE, scope: String? = nil,
                                    state: String, extraParams: [String: String] = [:]) -> URL? {
        guard var comps = URLComponents(string: metadata.authorization_endpoint) else { return nil }
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        if let scope { items.append(URLQueryItem(name: "scope", value: scope)) }
        for (k, v) in extraParams { items.append(URLQueryItem(name: k, value: v)) }   // 如 Google access_type=offline & prompt=consent
        comps.queryItems = items
        return comps.url
    }

    /// 用 authorization code 换 token。`clientSecret` 仅手动凭证来源（Google）需要。
    public static func exchange(tokenEndpoint: String, code: String, clientId: String,
                                redirectURI: String, verifier: String,
                                clientSecret: String? = nil) async throws -> MCPToken {
        try await tokenRequest(tokenEndpoint: tokenEndpoint, clientId: clientId, clientSecret: clientSecret, form: [
            "grant_type": "authorization_code", "code": code,
            "redirect_uri": redirectURI, "client_id": clientId, "code_verifier": verifier,
        ])
    }

    /// 用 refresh token 续期（client_secret 取自存的 token）。
    public static func refresh(token: MCPToken, clientId: String) async throws -> MCPToken {
        guard let rt = token.refreshToken, let te = token.tokenEndpoint else { throw MCPOAuthError.noRefresh }
        var t = try await tokenRequest(tokenEndpoint: te, clientId: clientId, clientSecret: token.clientSecret, form: [
            "grant_type": "refresh_token", "refresh_token": rt, "client_id": clientId,
        ])
        if t.refreshToken == nil { t.refreshToken = rt }   // 部分服务器不轮换 refresh token
        if t.clientSecret == nil { t.clientSecret = token.clientSecret }
        return t
    }

    private static func tokenRequest(tokenEndpoint: String, clientId: String, clientSecret: String? = nil,
                                     form: [String: String]) async throws -> MCPToken {
        guard let url = URL(string: tokenEndpoint) else { throw MCPOAuthError.badEndpoint }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var fields = form
        if let clientSecret { fields["client_secret"] = clientSecret }   // client_secret_post（Google 等）
        req.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = obj["access_token"] as? String else { throw MCPOAuthError.tokenFailed }
        let expiresIn = (obj["expires_in"] as? Double) ?? (obj["expires_in"] as? Int).map(Double.init)
        return MCPToken(accessToken: at,
                        refreshToken: obj["refresh_token"] as? String,
                        expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
                        clientId: clientId, clientSecret: clientSecret, tokenEndpoint: tokenEndpoint)
    }

    /// 取某来源的有效 access token（过期则用 refresh 续，写回 Keychain）。无 token 返回 nil。
    public static func validAccessToken(sourceId: String, clientId: String?) async -> String? {
        guard let token = MCPTokenStore.load(sourceId: sourceId) else { return nil }
        if !token.isExpired { return token.accessToken }
        guard let cid = clientId ?? token.clientId,
              let refreshed = try? await refresh(token: token, clientId: cid) else { return token.accessToken }
        MCPTokenStore.save(refreshed, sourceId: sourceId)
        return refreshed.accessToken
    }
}

public enum MCPOAuthError: Error, CustomStringConvertible, LocalizedError {
    case badEndpoint, registrationFailed, tokenFailed, noRefresh, discoveryFailed
    case authFailed(String)
    public var errorDescription: String? { description }
    public var description: String {
        switch self {
        case .badEndpoint: return "OAuth 端点无效"
        case .registrationFailed: return "动态客户端注册失败"
        case .tokenFailed: return "token 获取失败"
        case .noRefresh: return "无 refresh token"
        case .discoveryFailed: return "未发现该来源的 OAuth 授权配置（确认地址是有效的 MCP 服务器）"
        case .authFailed(let e): return "授权被拒绝：\(e)"
        }
    }
}

extension Data {
    /// base64url（无填充），PKCE / JWT 用。
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()
}
