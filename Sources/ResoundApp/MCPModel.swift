import SwiftUI
import AppKit
import ResoundCore

/// MCP 双向接入的全部 App 状态（Wave 3 + 4）。
/// 模块 A「外部 MCP 接入」：来源注册表 / OAuth 连接 / 添加自定义源 / 粘贴链接取回入库。
/// 模块 B「Resound MCP」：服务开关 / 内容策略 / 一键安装到 Claude Code·Codex。
/// 外部文档复用现有文档管线（DocumentStore + 索引），与本地导入文档同检索/问答/纪要。
@MainActor
final class MCPModel: ObservableObject {
    weak var app: AppModel?
    weak var documents: DocumentsModel?

    /// OAuth 回调地址（DCR 时注册成 redirect_uri；ASWebAuthenticationSession 的 callbackScheme=resound）。
    private let redirectURI = "resound://oauth/callback"
    private let callbackScheme = "resound"

    // MARK: 模块 A — 来源

    @Published var sources: [MCPSource] = []
    var connectedCount: Int { sources.filter { $0.status == .connected }.count }
    /// 子导航小红点：有过期来源时提醒。
    var sourcesAttention: Bool { sources.contains { $0.status == .expired } }

    // OAuth 连接弹窗
    struct Connecting: Equatable {
        let sourceId: String
        var name: String
        var kind: MCPSourceKind
        var phase: Phase
        var authURL: String = ""
        enum Phase { case redirect, waiting, done }
    }
    @Published var connecting: Connecting?

    // 手动凭证录入（Google：无 DCR，需用户从 Cloud Console 填 client_id + client_secret）
    struct CredsEntry: Equatable {
        let sourceId: String
        var name: String
        var kind: MCPSourceKind
        var clientId: String
        var clientSecret: String = ""
    }
    @Published var credsEntry: CredsEntry?
    /// 进行中的 loopback OAuth 监听（取消时关闭）。
    private var loopbackServer: LoopbackOAuthServer?

    // 添加自定义来源弹窗
    struct EnvVar: Identifiable, Equatable { let id = UUID(); var key: String; var value: String }
    struct AddSourceState {
        var name = ""
        var transport: MCPSourceTransport = .remote
        // remote
        var url = ""
        var auth: MCPSourceAuth = .oauth
        var needsClientId = false
        var clientId = ""
        var token = ""
        // local
        var command = ""
        var args = ""
        var env: [EnvVar] = []
        var envK = ""
        var envV = ""
    }
    @Published var addSource: AddSourceState?

    // 粘贴链接弹窗
    struct LinkResultView: Equatable {
        var title: String
        var sourceName: String
        var url: String
        var kind: MCPSourceKind?
        var imported: Bool
    }
    struct LinkFlow {
        var recId: String
        var recTitle: String
        var url = ""
        var phase: Phase = .input
        var result: LinkResultView?
        var importError: String?
        enum Phase { case input, resolving, resolved, importing, unconnected, unknown, noperm }
    }
    @Published var linkFlow: LinkFlow?
    /// 正在同步的外部文档（按 dir.path），录音详情行内显示转圈。
    @Published var syncingDocs: Set<String> = []
    func isSyncing(_ dir: URL) -> Bool { syncingDocs.contains(dir.path) }
    // resolve 成功后暂存，供「关联到本场录音」确认步骤入库
    private var pendingFetched: FetchedExternalDoc?
    private var pendingSource: MCPSource?

    // MARK: 模块 B — 服务器

    @Published var serverEnabled: Bool
    @Published var contentPolicy: MCPContentPolicy
    @Published var clientDetected: [MCPClientKind: Bool] = [:]
    @Published var clientInstalled: [MCPClientKind: Bool] = [:]
    @Published var installing: MCPClientKind?
    @Published var manualOpen = false

    /// 安装命令里写入的 resound CLI 路径（随包分发优先，回退 PATH）。
    private(set) var resoundPath: String?
    var serverCommand: String {
        let path = resoundPath ?? "resound"
        return "\(shellQuote(path)) mcp serve"
    }

    /// 等待中的 OAuth 回调（state 校验 + 续约）。`resound://oauth/callback` 经 App `.onOpenURL` 路由到 handleCallback。
    private var pendingOAuth: (state: String, cont: CheckedContinuation<String, Error>)?

    init() {
        let s = MCPServerSettings.load()
        serverEnabled = s.enabled
        contentPolicy = s.contentPolicy
    }

    // MARK: 启动加载

    func load() {
        sources = MCPSourceStore.load()
        let macOSDir = Bundle.main.executableURL?.deletingLastPathComponent()
        Task { [weak self] in
            let probe = await Task.detached(priority: .utility) { () -> (String?, [MCPClientKind: Bool], [MCPClientKind: Bool]) in
                let path = MCPInstall.appResoundPath(bundleMacOSDir: macOSDir)
                var detected: [MCPClientKind: Bool] = [:]
                var installed: [MCPClientKind: Bool] = [:]
                for k in MCPClientKind.allCases {
                    let d = MCPInstall.isClientDetected(k)
                    detected[k] = d
                    installed[k] = d ? MCPInstall.isServerInstalled(k) : false
                }
                return (path, detected, installed)
            }.value
            guard let self else { return }
            self.resoundPath = probe.0
            self.clientDetected = probe.1
            self.clientInstalled = probe.2
        }
    }

    private func cfg() -> Config? { try? Config.load() }
    private func vaultURL() -> URL? { cfg()?.vaultPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } }

    // MARK: 来源持久化 helper

    private func persistSources() { MCPSourceStore.save(sources) }
    private func updateSource(_ id: String, _ mutate: (inout MCPSource) -> Void) {
        guard let i = sources.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sources[i]); persistSources()
    }

    /// 取某来源的有效 bearer：OAuth 来源走 Keychain（过期自动刷新），token 来源取存的 token。
    private func bearer(for source: MCPSource) async -> String? {
        switch source.auth {
        case .none: return nil
        case .oauth, .token:
            return await MCPOAuth.validAccessToken(sourceId: source.id, clientId: source.clientId)
        }
    }

    // MARK: 模块 A — 连接 / 断开（OAuth）

    func connect(_ source: MCPSource) {
        if source.auth == .token {   // token 型来源无需 OAuth，已在添加时存好
            updateSource(source.id) { $0.status = .connected }
            return
        }
        if source.needsClientSecret == true {   // Google 等：先收集手动凭证，再走 loopback OAuth
            credsEntry = CredsEntry(sourceId: source.id, name: source.name, kind: source.kind, clientId: source.clientId ?? "")
            return
        }
        startConnect(source)
    }

    /// DCR / 自定义 scheme 的标准 OAuth 流程（Notion / Atlassian / 自定义远程来源）。
    private func startConnect(_ source: MCPSource) {
        connecting = Connecting(sourceId: source.id, name: source.name, kind: source.kind, phase: .redirect)
        Task {
            do {
                try await runOAuth(source)
                updateSource(source.id) { $0.status = .connected; $0.account = $0.account ?? "已连接" }
                connecting?.phase = .done
                // 粘贴链接流程里「去连接」过来的：连上后自动重解析
                if let lf = linkFlow, lf.phase == .unconnected { resolveLink() }
            } catch is CancellationError {
                // 用户主动取消：cancelConnecting 已清状态，不弹失败提示
            } catch {
                app?.toast("连接失败：\(shortErr(error))")
                connecting = nil
            }
        }
    }

    // MARK: 手动凭证（Google）

    func cancelCreds() { credsEntry = nil }

    func submitCreds() {
        guard let e = credsEntry else { return }
        let cid = e.clientId.trimmingCharacters(in: .whitespaces)
        let secret = e.clientSecret.trimmingCharacters(in: .whitespaces)
        guard !cid.isEmpty, !secret.isEmpty, let source = sources.first(where: { $0.id == e.sourceId }) else { return }
        credsEntry = nil
        connecting = Connecting(sourceId: source.id, name: source.name, kind: source.kind, phase: .redirect)
        Task {
            do {
                try await runManualLoopbackOAuth(source, clientId: cid, clientSecret: secret)
                updateSource(source.id) { $0.status = .connected; $0.account = $0.account ?? "已连接" }
                connecting?.phase = .done
                if let lf = linkFlow, lf.phase == .unconnected { resolveLink() }
            } catch is CancellationError {
            } catch {
                app?.toast("连接失败：\(shortErr(error))")
                connecting = nil
            }
        }
    }

    func cancelConnecting() {
        pendingOAuth?.cont.resume(throwing: CancellationError())
        pendingOAuth = nil
        loopbackServer?.cancelWaiting(); loopbackServer = nil
        connecting = nil
    }

    func disconnect(_ source: MCPSource) {
        MCPTokenStore.delete(sourceId: source.id)
        updateSource(source.id) { $0.status = .disconnected; $0.account = nil; $0.lastSync = nil }
        app?.toast("已断开 \(source.name)")
    }

    /// 真 OAuth 2.1 + PKCE + DCR：发现 → 注册（或用已填 client_id）→ 浏览器授权 → 换 token → 存 Keychain。
    private func runOAuth(_ source: MCPSource) async throws {
        guard let endpoint = source.url.flatMap(URL.init(string:)) else { throw MCPOAuthError.badEndpoint }
        let meta = try await MCPOAuth.discover(mcpEndpoint: endpoint)
        let clientId: String
        if let cid = source.clientId, !cid.isEmpty {
            clientId = cid
        } else if let reg = meta.registration_endpoint {
            clientId = try await MCPOAuth.registerClient(registrationEndpoint: reg, redirectURI: redirectURI)
        } else {
            throw MCPOAuthError.registrationFailed
        }
        let pkce = PKCE()
        let state = UUID().uuidString
        guard let authURL = MCPOAuth.authorizeURL(metadata: meta, clientId: clientId,
                                                  redirectURI: redirectURI, pkce: pkce,
                                                  scope: nil, state: state) else {
            throw MCPOAuthError.badEndpoint
        }
        connecting?.authURL = authURL.absoluteString
        let code = try await presentWebAuth(url: authURL, expectedState: state)
        var token = try await MCPOAuth.exchange(tokenEndpoint: meta.token_endpoint, code: code,
                                                clientId: clientId, redirectURI: redirectURI,
                                                verifier: pkce.verifier)
        token.clientId = clientId
        MCPTokenStore.save(token, sourceId: source.id)
        updateSource(source.id) { $0.clientId = clientId }
    }

    /// 手动凭证 + loopback OAuth（Google：无 DCR，redirect 必须是 http://127.0.0.1:<port>，token 交换带 client_secret）。
    /// 用已知端点（不依赖发现），显式申请来源声明的 scope，并请求离线刷新（access_type=offline & prompt=consent）。
    private func runManualLoopbackOAuth(_ source: MCPSource, clientId: String, clientSecret: String) async throws {
        let meta: OAuthServerMetadata = .google   // 目前仅 Google 走手动凭证 + loopback
        let server = LoopbackOAuthServer()
        loopbackServer = server
        defer { loopbackServer = nil }
        let redirect = try await server.start()
        let pkce = PKCE()
        let state = UUID().uuidString
        let scope = (source.oauthScopes ?? []).joined(separator: " ")
        guard let authURL = MCPOAuth.authorizeURL(metadata: meta, clientId: clientId, redirectURI: redirect,
                                                  pkce: pkce, scope: scope.isEmpty ? nil : scope, state: state,
                                                  extraParams: ["access_type": "offline", "prompt": "consent"]) else {
            server.stop(); throw MCPOAuthError.badEndpoint
        }
        connecting?.authURL = authURL.absoluteString
        connecting?.phase = .waiting
        NSWorkspace.shared.open(authURL)   // 默认浏览器（带 Chrome 登录态）
        let code = try await server.waitForCode(expectedState: state)
        var token = try await MCPOAuth.exchange(tokenEndpoint: meta.token_endpoint, code: code,
                                                clientId: clientId, redirectURI: redirect,
                                                verifier: pkce.verifier, clientSecret: clientSecret)
        token.clientId = clientId
        token.clientSecret = clientSecret
        MCPTokenStore.save(token, sourceId: source.id)
        updateSource(source.id) { $0.clientId = clientId }
    }

    /// 在**用户默认浏览器**（Chrome 等，带现有登录态）打开授权页；回调经自定义 scheme 路由回 App。
    /// 旧版用 ASWebAuthenticationSession，但它走系统 Safari/WebKit 独立会话，拿不到 Chrome 登录态。
    private func presentWebAuth(url: URL, expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            pendingOAuth = (expectedState, cont)
            connecting?.phase = .waiting
            NSWorkspace.shared.open(url)   // 默认浏览器打开
        }
    }

    /// 处理 `resound://oauth/callback?code=…&state=…` 回调（App `.onOpenURL` → 这里）。
    func handleCallback(_ url: URL) {
        guard url.scheme == callbackScheme else { return }
        guard let pending = pendingOAuth else { return }
        pendingOAuth = nil
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let err = comps?.queryItems?.first(where: { $0.name == "error" })?.value {
            pending.cont.resume(throwing: MCPOAuthError.authFailed(err)); return
        }
        guard let code = comps?.queryItems?.first(where: { $0.name == "code" })?.value else {
            pending.cont.resume(throwing: MCPOAuthError.tokenFailed); return
        }
        if let returned = comps?.queryItems?.first(where: { $0.name == "state" })?.value, returned != pending.state {
            pending.cont.resume(throwing: MCPOAuthError.tokenFailed); return
        }
        pending.cont.resume(returning: code)
    }

    // MARK: 模块 A — 同步来源（重取其所有已导入外部文档）

    func syncSource(_ source: MCPSource) {
        updateSource(source.id) { $0.lastSync = nil }
        Task {
            guard let vault = vaultURL(), let cfg = cfg() else { return }
            let dirs = DocumentStore(vaultRoot: vault).allDocumentDirs()
            var n = 0
            for dir in dirs {
                guard let m = parseDocumentManifest(dir), let ext = m.external,
                      ext.form == "imported", ext.sourceId == source.id else { continue }
                let ok = (try? await MCPIngest.resync(docDir: dir, vaultRoot: vault, indexPath: defaultIndexPath(),
                                                      config: cfg, bearer: { await self.bearer(for: $0) })) ?? false
                if ok { n += 1 }
            }
            updateSource(source.id) { $0.lastSync = relativeNow() }
            documents?.refresh()
            app?.toast(n > 0 ? "已同步 \(n) 篇 \(source.name) 文档" : "\(source.name) 无可同步内容")
        }
    }

    // MARK: 模块 A — 添加自定义来源

    func openAddSource() { addSource = AddSourceState() }
    func cancelAddSource() { addSource = nil }

    func addEnvVar() {
        guard var a = addSource else { return }
        let k = a.envK.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return }
        a.env.append(EnvVar(key: k, value: a.envV)); a.envK = ""; a.envV = ""
        addSource = a
    }
    func removeEnvVar(_ id: UUID) {
        guard var a = addSource else { return }
        a.env.removeAll { $0.id == id }; addSource = a
    }

    var addSourceValid: Bool {
        guard let a = addSource else { return false }
        switch a.transport {
        case .remote:
            guard let u = URL(string: a.url.trimmingCharacters(in: .whitespaces)), u.scheme != nil else { return false }
            if a.auth == .token { return !a.token.trimmingCharacters(in: .whitespaces).isEmpty }
            return true
        case .local:
            return !a.command.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    func submitAddSource() {
        guard let a = addSource, addSourceValid else { return }
        let name = a.name.trimmingCharacters(in: .whitespaces).isEmpty ? "自定义来源" : a.name.trimmingCharacters(in: .whitespaces)
        let id = "src_custom_\(UUID().uuidString.prefix(8))"
        switch a.transport {
        case .remote:
            let url = a.url.trimmingCharacters(in: .whitespaces)
            let host = URL(string: url)?.host
            var src = MCPSource(id: id, kind: .custom, name: name, transport: .remote,
                                url: url, auth: a.auth, needsClientId: a.needsClientId,
                                clientId: a.clientId.isEmpty ? nil : a.clientId,
                                status: .disconnected, scope: "自定义 MCP 服务器",
                                hostPatterns: host.map { [$0] } ?? [], builtin: false)
            if a.auth == .token {                      // token 即时可用：存 Keychain + 标记已连接
                let tok = a.token.trimmingCharacters(in: .whitespaces)
                MCPTokenStore.save(MCPToken(accessToken: tok), sourceId: id)
                src.status = .connected; src.account = "API Token"
            }
            sources.append(src); persistSources()
            addSource = nil
            if src.auth == .oauth { connect(src) } else { app?.toast("已添加来源「\(name)」") }
        case .local:
            let cmd = a.command.trimmingCharacters(in: .whitespaces)
            let args = a.args.split(separator: " ").map(String.init)
            let env = Dictionary(a.env.map { ($0.key, $0.value) }, uniquingKeysWith: { _, b in b })
            let src = MCPSource(id: id, kind: .custom, name: name, transport: .local,
                                auth: .none, command: cmd, args: args, env: env,
                                status: .connected, account: "本地进程", scope: "本地 MCP · stdio",
                                builtin: false)
            sources.append(src); persistSources()
            addSource = nil
            app?.toast("已添加本地来源「\(name)」")
        }
    }

    // MARK: 模块 A — 粘贴链接关联到录音

    func openLink(recId: String, recTitle: String) {
        linkFlow = LinkFlow(recId: recId, recTitle: recTitle)
        pendingFetched = nil; pendingSource = nil
    }
    func cancelLink() { linkFlow = nil; pendingFetched = nil; pendingSource = nil }

    func resolveLink() {
        guard var lf = linkFlow else { return }
        let url = lf.url.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty else { return }
        lf.phase = .resolving; linkFlow = lf
        Task {
            let res = await ExternalLinkResolver.resolve(url: url, sources: sources,
                                                         bearer: { await self.bearer(for: $0) })
            guard var lf = linkFlow else { return }
            switch res {
            case .imported(let doc, let src):
                pendingFetched = doc; pendingSource = src
                lf.result = LinkResultView(title: doc.title, sourceName: src.name, url: url, kind: src.kind, imported: true)
                lf.phase = .resolved
            case .unconnected(let src):
                pendingSource = src
                lf.result = LinkResultView(title: SourceAdapter.titleFromURL(url), sourceName: src.name, url: url, kind: src.kind, imported: false)
                lf.phase = .unconnected
            case .unknown:
                lf.result = LinkResultView(title: SourceAdapter.titleFromURL(url), sourceName: "未知来源", url: url, kind: nil, imported: false)
                lf.phase = .unknown
            case .noPermission(let src):
                pendingSource = src
                lf.result = LinkResultView(title: SourceAdapter.titleFromURL(url), sourceName: src.name, url: url, kind: src.kind, imported: false)
                lf.phase = .noperm
            }
            linkFlow = lf
        }
    }

    /// 确认把已取回内容入库并关联到本场录音。入库期间保持弹窗显示进度，失败留在弹窗显示原因（并落盘日志）。
    func confirmLink() {
        guard let lf = linkFlow, let doc = pendingFetched, let src = pendingSource else { return }
        guard let vault = vaultURL(), let cfg = cfg() else { app?.toast("未设置录音库路径，无法入库"); return }
        let url = lf.result?.url ?? lf.url
        let recId = lf.recId
        linkFlow?.phase = .importing
        linkFlow?.importError = nil
        Task {
            do {
                _ = try await MCPIngest.ingestImported(doc, source: src, url: url, recordingId: recId,
                                                       vaultRoot: vault, indexPath: defaultIndexPath(), config: cfg,
                                                       enrichContext: false)   // 外部大文档跳过逐 chunk LLM 增强（慢且脆）
                await documents?.refreshAndWait()   // 等刷新完成
                app?.reloadLibrary()                // 强制录音页重渲 → 相关文档即时出现（不必重启）
                cancelLink()
                app?.toast("已关联「\(doc.title)」并纳入检索")
            } catch {
                AppLog.log("外部文档入库失败 \(url) → \(error)")
                await documents?.refreshAndWait()   // 正文已写盘但建索引失败：让 UI 反映磁盘真实状态
                app?.reloadLibrary()
                linkFlow?.importError = shortErr(error)
                linkFlow?.phase = .resolved          // 回到结果卡，可重试
                app?.toast("入库失败：\(shortErr(error))")
            }
        }
    }

    /// 以「仅链接」保存（无正文、不索引）。
    func saveLinkOnly() {
        guard let lf = linkFlow, let vault = vaultURL() else { return }
        let url = lf.result?.url ?? lf.url
        let recId = lf.recId
        let src = pendingSource
        let title = lf.result?.title
        cancelLink()
        Task {
            do {
                _ = try MCPIngest.saveLinkOnly(url: url, source: src, title: title, recordingId: recId, vaultRoot: vault)
                await documents?.refreshAndWait()
                app?.reloadLibrary()                // 强制录音页重渲 → 仅链接引用即时出现
                app?.toast("已以仅链接保存")
            } catch {
                app?.toast("保存失败：\(shortErr(error))")
            }
        }
    }

    /// 链接来自未连接来源 → 先连，连上后自动重解析（见 connect()）。
    func connectThenLink() {
        guard let src = pendingSource else { return }
        connect(src)
    }

    // MARK: 录音详情 — 外部文档行操作

    func openExternal(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 同步单篇外部文档（重取正文 → 重建索引）。
    func syncExternalDoc(dir: URL) {
        guard !syncingDocs.contains(dir.path) else { return }
        guard let vault = vaultURL(), let cfg = cfg() else { app?.toast("未设置录音库路径"); return }
        syncingDocs.insert(dir.path)
        Task {
            defer { syncingDocs.remove(dir.path) }
            do {
                let ok = try await MCPIngest.resync(docDir: dir, vaultRoot: vault, indexPath: defaultIndexPath(),
                                                    config: cfg, bearer: { await self.bearer(for: $0) })
                await documents?.refreshAndWait()
                app?.reloadLibrary()
                app?.toast(ok ? "已同步最新内容" : "无法同步（来源未连接？）")
            } catch {
                AppLog.log("外部文档同步失败 \(dir.lastPathComponent) → \(error)")
                app?.toast("同步失败：\(shortErr(error))")
            }
        }
    }

    // MARK: 模块 B — 服务器开关 / 内容策略 / 安装

    func toggleServer(_ on: Bool) {
        serverEnabled = on
        MCPServerSettings(enabled: on, contentPolicy: contentPolicy).save()
        app?.toast(on ? "已开启 Resound MCP 服务" : "已停止 Resound MCP 服务")
    }
    func setContentPolicy(_ p: MCPContentPolicy) {
        contentPolicy = p
        MCPServerSettings(enabled: serverEnabled, contentPolicy: p).save()
        app?.toast("已更新对外内容设置")
    }

    func install(_ kind: MCPClientKind) {
        guard installing == nil else { return }
        installing = kind
        let path = resoundPath
        Task { [weak self] in
            let result: String? = await Task.detached(priority: .userInitiated) {
                do { try MCPInstall.install(kind, resoundPath: path); return nil }
                catch { return String(describing: error) }
            }.value
            guard let self else { return }
            self.installing = nil
            if result == nil { self.clientInstalled[kind] = true; self.app?.toast("\(kind.displayName) 已安装 Resound MCP") }
            else { self.app?.toast("安装失败：\(self.shortErr(NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: result ?? ""])))") }
        }
    }

    func uninstall(_ kind: MCPClientKind) {
        Task { [weak self] in
            await Task.detached(priority: .userInitiated) { try? MCPInstall.uninstall(kind) }.value
            guard let self else { return }
            self.clientInstalled[kind] = false
            self.app?.toast("已从 \(kind.displayName) 移除")
        }
    }

    func manualCommand(_ kind: MCPClientKind) -> String {
        MCPInstall.installCommand(kind, resoundPath: resoundPath ?? "resound")
    }
    func copyCommand(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        app?.toast("已复制命令")
    }

    // MARK: helpers

    private func shortErr(_ error: Error) -> String {
        let s = (error as NSError).localizedDescription
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }
    private func relativeNow() -> String { "刚刚" }
}
