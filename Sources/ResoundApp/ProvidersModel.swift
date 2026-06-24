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
        commit(c)
    }

    /// 转写改用本地 WhisperKit：清掉在线转写 provider + ref。
    func useLocalTranscribe() {
        var c = config
        c.transcribe = nil
        c.providers.removeAll { $0.id == Capability.transcribe.providerId }
        commit(c)
        probe[.transcribe] = .idle
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
        probe[cap] = .running
        Task {
            switch cap {
            case .chat:
                let r = await ProviderProbe.chat(baseURL: base, key: key, model: m)
                probe[cap] = r.isOK ? .ok(r.detail) : .fail(r.detail)
            case .embedding:
                let (r, dim) = await ProviderProbe.embedding(baseURL: base, key: key, model: m)
                if r.isOK, let dim {
                    var c = config; c.embeddingDim = dim; commit(c)   // 维度落盘，否则 Config.load 回退 4096
                }
                probe[cap] = r.isOK ? .ok(r.detail) : .fail(r.detail)
            case .transcribe:
                let r = await ProviderProbe.transcribe(baseURL: base, key: key, model: m)
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
                importToken &+= 1
                app?.toast("已导入 AI 配置")
            } catch { app?.toast("导入失败：\(error.localizedDescription)") }
        }
    }
}
