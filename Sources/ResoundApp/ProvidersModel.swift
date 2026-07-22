import SwiftUI
import AppKit
import ResoundCore

/// AI Provider 配置状态：chat / embedding / 转写 三种能力，各管一条 OpenAI 兼容 Provider。
/// 写 App Support `providers.json`，运行时即时生效（`Config.load()` 优先读它）。
@MainActor
final class ProvidersModel: ObservableObject {
    weak var app: AppModel?

    enum Capability: String, CaseIterable, Identifiable {
        case chat, embedding, transcribe
        var id: String { rawValue }
        var providerId: String { "p-\(rawValue)" }
        var title: String { switch self { case .chat: return "对话模型"; case .embedding: return "向量模型"; case .transcribe: return "转写模型" } }
        var subtitle: String {
            switch self {
            case .chat: return "问答、摘要、AI 校对都用它。必填。"
            case .embedding: return "把文稿切块向量化以供检索。必填。"
            case .transcribe: return "把录音转成文字。留空 = 用本地 Whisper（免联网，首次下模型较慢）。"
            }
        }
        var required: Bool { self != .transcribe }
    }

    enum ProbeState: Equatable { case idle, running, ok(String), fail(String) }

    @Published private(set) var config = ProvidersConfig()
    @Published var probe: [Capability: ProbeState] = [:]
    /// 导入配置后自增，通知卡片重新以最新值播种本地草稿。
    @Published private(set) var importToken = 0

    /// 没配齐「chat + embedding」就需要引导（迁移过来的老用户 isComplete=true，不弹）。
    var needsOnboarding: Bool { !config.isComplete }

    func load() {
        ProvidersStore.migrateFromEnvIfNeeded()
        config = ProvidersStore.load() ?? ProvidersConfig()
        restoreProbes()
    }

    // MARK: 验证状态持久化（指纹 = baseURL|apiKey|model；一致即视为已验证）

    private func fp(_ base: String, _ key: String, _ model: String) -> String {
        "\(base.trimmingCharacters(in: .whitespaces))|\(key.trimmingCharacters(in: .whitespaces))|\(model.trimmingCharacters(in: .whitespaces))"
    }
    private func fingerprint(_ cap: Capability) -> String? {
        guard let p = provider(cap) else { return nil }
        return fp(p.baseURL, p.apiKey, model(cap))
    }
    private func restoredDetail(_ cap: Capability) -> String {
        switch cap {
        case .chat: return "Chat 可用 · \(model(cap))"
        case .embedding: return config.embeddingDim.map { "Embedding 可用 · 维度 \($0)" } ?? "Embedding 可用"
        case .transcribe: return "转写可用 · \(model(cap))"
        }
    }
    /// 启动/导入后：指纹与持久化的 verified 一致的能力，恢复成「已验证」。
    private func restoreProbes() {
        for cap in Capability.allCases {
            if let saved = config.verified?[cap.rawValue], let now = fingerprint(cap), saved == now {
                probe[cap] = .ok(restoredDetail(cap))
            }
        }
    }
    private func markVerified(_ cap: Capability, _ fingerprint: String, dim: Int? = nil) {
        var c = config
        if let dim { c.embeddingDim = dim }
        var v = c.verified ?? [:]
        v[cap.rawValue] = fingerprint
        c.verified = v
        commit(c)
    }

    // MARK: 读取某能力当前配置

    func provider(_ cap: Capability) -> AIProvider? { ref(cap).flatMap { config.provider($0.providerId) } }
    func model(_ cap: Capability) -> String { ref(cap)?.model ?? "" }
    private func ref(_ cap: Capability) -> ModelRef? {
        switch cap { case .chat: return config.chat; case .embedding: return config.embedding; case .transcribe: return config.transcribe }
    }

    // MARK: 写入

    /// 写某能力（upsert 该能力专属 provider + 设 ref），并落盘。
    func set(_ cap: Capability, baseURL: String, apiKey: String, model: String, presetId: String?) {
        var c = config
        let name = presetId.flatMap { pid in ProviderPreset.all.first { $0.id == pid }?.name } ?? "自定义"
        let p = AIProvider(id: cap.providerId, name: name,
                           baseURL: baseURL.trimmingCharacters(in: .whitespaces),
                           apiKey: apiKey.trimmingCharacters(in: .whitespaces), presetId: presetId)
        c.providers.removeAll { $0.id == cap.providerId }
        c.providers.append(p)
        let r = ModelRef(providerId: cap.providerId, model: model.trimmingCharacters(in: .whitespaces))
        switch cap { case .chat: c.chat = r; case .embedding: c.embedding = r; case .transcribe: c.transcribe = r }
        // 改了 Provider/BaseURL/Key/模型 → 指纹变化 → 验证失效
        let newFp = fp(baseURL, apiKey, model)
        if c.verified?[cap.rawValue] != newFp { c.verified?[cap.rawValue] = nil }
        commit(c)
        if config.verified?[cap.rawValue] != newFp { probe[cap] = .idle }
    }

    // MARK: 转录后 AI 校对（跑在 chat 服务商上）

    var correctionEnabled: Bool { config.transcribeCorrect ?? true }
    var correctionModel: String { config.correctModel ?? "" }   // 空 = 跟随 chat.model

    func setCorrection(enabled: Bool, model: String) {
        var c = config
        c.transcribeCorrect = enabled
        let m = model.trimmingCharacters(in: .whitespaces)
        c.correctModel = m.isEmpty ? nil : m
        commit(c)
    }

    /// 转写改用本地 WhisperKit：清掉在线转写 provider + ref。
    func useLocalTranscribe() {
        var c = config
        c.transcribe = nil
        c.transcribeBackend = nil
        c.providers.removeAll { $0.id == Capability.transcribe.providerId }
        c.verified?[Capability.transcribe.rawValue] = nil
        commit(c)
        probe[.transcribe] = .idle
    }

    // MARK: MOSS 云端转写（端到端转录+说话人，自部署 Modal）

    enum TranscribeBackendChoice { case moss, online, local }
    var transcribeBackendChoice: TranscribeBackendChoice {
        if config.transcribeBackend == "moss" { return .moss }
        return config.transcribe != nil ? .online : .local
    }
    /// MOSS endpoint 已配置（部署过）。选没选 MOSS 看 transcribeBackendChoice。
    var mossDeployed: Bool {
        !(config.mossSubmitURL ?? "").isEmpty && !(config.mossResultURL ?? "").isEmpty
    }
    var mossSubmitURL: String { config.mossSubmitURL ?? "" }

    @Published var mossDeploying = false
    @Published var mossDeployLog: [String] = []
    @Published var mossProbe: ProbeState = .idle

    /// 选 MOSS 后端（在线 whisper 配置保留作为回退，不清）。
    func useMossBackend() {
        var c = config
        c.transcribeBackend = "moss"
        commit(c)
    }
    /// 切回 whisper（在线）。MOSS endpoint 配置保留，再切回来免重部署。
    func useWhisperBackend() {
        var c = config
        c.transcribeBackend = nil
        commit(c)
    }

    /// 一键部署：MossDeployer 全流程（登录→Secret→deploy→验证），进度逐行进 mossDeployLog。
    func deployMoss() {
        guard !mossDeploying else { return }
        mossDeploying = true
        mossDeployLog = []
        Task {
            do {
                let d = try await MossDeployer.deploy { line in
                    Task { @MainActor in self.mossDeployLog.append(line) }
                }
                var c = config
                c.transcribeBackend = "moss"
                c.mossSubmitURL = d.submitURL
                c.mossResultURL = d.resultURL
                c.mossAPIKey = d.apiKey
                commit(c)
                mossProbe = .ok("已部署并验证 · GPU 推理可用")
                app?.toast("MOSS 部署完成 🎉")
            } catch {
                mossDeployLog.append("❌ \(error)")
                mossProbe = .fail(String(describing: error))
                app?.toast("MOSS 部署失败，详见部署日志")
            }
            mossDeploying = false
        }
    }

    /// 轻量测试连接（不动 GPU）：验证 endpoint 可达 + 密钥有效。
    func testMoss() {
        guard mossDeployed else { mossProbe = .fail("还没部署"); return }
        mossProbe = .running
        let (s, r, k) = (config.mossSubmitURL ?? "", config.mossResultURL ?? "", config.mossAPIKey ?? "")
        Task {
            let res = await MossDeployer.probe(submitURL: s, resultURL: r, apiKey: k)
            mossProbe = res.ok ? .ok(res.detail) : .fail(res.detail)
        }
    }

    private func commit(_ c: ProvidersConfig) {
        var c = c
        let used = Set([c.chat?.providerId, c.embedding?.providerId, c.transcribe?.providerId].compactMap { $0 })
        c.providers.removeAll { !used.contains($0.id) }
        config = c
        do { try ProvidersStore.save(c) }
        catch { app?.toast("保存失败：\(error.localizedDescription)") }
    }

    // MARK: 验证

    func test(_ cap: Capability, baseURL: String, apiKey: String, model: String) {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        let m = model.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, !m.isEmpty else { probe[cap] = .fail("Base URL 和模型名都要填"); return }
        let testedFp = fp(base, key, m)
        probe[cap] = .running
        Task {
            switch cap {
            case .chat:
                let r = await ProviderProbe.chat(baseURL: base, key: key, model: m)
                if r.isOK { markVerified(cap, testedFp) }
                probe[cap] = r.isOK ? .ok(r.detail) : .fail(r.detail)
            case .embedding:
                let (r, dim) = await ProviderProbe.embedding(baseURL: base, key: key, model: m)
                if r.isOK { markVerified(cap, testedFp, dim: dim) }   // 维度也落盘，否则 Config.load 回退 4096
                probe[cap] = r.isOK ? .ok(r.detail) : .fail(r.detail)
            case .transcribe:
                let r = await ProviderProbe.transcribe(baseURL: base, key: key, model: m)
                if r.isOK { markVerified(cap, testedFp) }
                probe[cap] = r.isOK ? .ok(r.detail) : .fail(r.detail)
            }
        }
    }

    // MARK: 导入 / 导出 providers.json

    func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "resound-providers.json"
        panel.message = "导出 AI 配置（含密钥，作为本机备份/迁移用，勿外发）"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                try enc.encode(config).write(to: url); app?.toast("AI 配置已导出")
            } catch { app?.toast("导出失败：\(error.localizedDescription)") }
        }
    }

    func importConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]; panel.prompt = "导入"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data = try Data(contentsOf: url)
                let imported = try JSONDecoder().decode(ProvidersConfig.self, from: data)
                commit(imported)
                probe.removeAll()
                restoreProbes()
                importToken &+= 1
                app?.toast("已导入 AI 配置")
            } catch { app?.toast("导入失败：\(error.localizedDescription)") }
        }
    }
}
