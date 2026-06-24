import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics
import ResoundCore

/// 设置页状态：就绪状态 / 权限 / 通用开关 / 摘要模板 CRUD / 专有词表 CRUD。
@MainActor
final class SettingsModel: ObservableObject {
    weak var app: AppModel?

    struct EditTpl: Identifiable { var id: String { tplId ?? "__new__" }; var tplId: String?; var name: String; var prompt: String; var aiIntent: String = "" }
    struct EditVocab: Identifiable { var id: String { vocabId ?? "__new__" }; var vocabId: String?; var canonical: String; var variants: [String]; var draft: String }
    struct PermRow: Identifiable { let id = UUID(); let label: String; let desc: String; let granted: Bool }

    @Published var templates: [SummaryTemplate] = []
    @Published var defaultTplId: String { didSet { UserDefaults.standard.set(defaultTplId, forKey: Self.defKey) } }
    @Published var vocab: [GlossaryEntry] = []
    @Published var vocabFilter = ""             // 词表搜索（按规范词/变体过滤），词条多时免长滚动
    var filteredVocab: [GlossaryEntry] {
        let q = vocabFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return vocab }
        return vocab.filter { e in
            e.canonical.lowercased().contains(q) || e.variants.contains { $0.lowercased().contains(q) }
        }
    }

    @Published var editTpl: EditTpl?
    @Published var aiBusy = false               // 模板提示词 AI 协助进行中
    @Published var confirmTplDeleteId: String?
    @Published var editVocab: EditVocab?
    @Published var confirmVocabDeleteId: String?
    /// 智能错词标注：跨录音累计后待确认的「加入词表」建议（收件箱）。
    @Published var suggestions: [CorrectionObservation] = []

    @Published var permRows: [PermRow] = []
    @Published var needsAttention = false

    // 连接与模型配置（写 App Support .env，运行时即时生效，无需重 build）
    struct EditConfig {
        var chatKey = "", chatBaseURL = ""
        var embeddingKey = "", embeddingBaseURL = ""
        var transcribeOnline = true
        var transcribeModel = "", transcribeKey = "", transcribeBaseURL = ""
        var vaultPath = ""
        var vaultAutoPush = false
    }
    @Published var editConfig = EditConfig()

    // 通用开关（UI 偏好，持久化在 UserDefaults）
    @Published var launchAtLogin: Bool { didSet { setBool(oldValue, launchAtLogin, "resound.toggle.launch") } }
    @Published var menuBarResident: Bool { didSet { setBool(oldValue, menuBarResident, "resound.toggle.menubar") } }
    @Published var autoDetect: Bool { didSet { setBool(oldValue, autoDetect, "resound.toggle.autodetect") } }
    @Published var showReminder: Bool { didSet { setBool(oldValue, showReminder, "resound.toggle.reminder") } }

    private static let defKey = "resound.defaultTemplate"
    let placeholders = ["{date}", "{title}", "{speakers}", "{transcript}"]

    init() {
        let d = UserDefaults.standard
        defaultTplId = d.string(forKey: Self.defKey) ?? ""
        launchAtLogin = d.object(forKey: "resound.toggle.launch") as? Bool ?? true
        menuBarResident = d.object(forKey: "resound.toggle.menubar") as? Bool ?? true
        autoDetect = d.object(forKey: "resound.toggle.autodetect") as? Bool ?? true
        showReminder = d.object(forKey: "resound.toggle.reminder") as? Bool ?? true
    }

    private func setBool(_ old: Bool, _ new: Bool, _ key: String) { UserDefaults.standard.set(new, forKey: key) }

    private func vaultURL() -> URL? { (try? Config.load())?.vaultPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } }

    func load() {
        templates = SummaryTemplateStore.load()
        if defaultTplId.isEmpty || !templates.contains(where: { $0.id == defaultTplId }) {
            defaultTplId = templates.first?.id ?? ""
        }
        vocab = vaultURL().map { GlossaryStore.load(vaultRoot: $0) } ?? []
        suggestions = CorrectionLearner.pending()
        loadConfigEditor()
        loadStatus()
    }

    // MARK: 连接与模型配置（编辑 / 保存 / 导入导出 / 选择路径）

    private func loadConfigEditor() {
        let e = ConfigStore.current()
        func g(_ k: String, _ d: String = "") -> String { (e[k]?.isEmpty == false) ? e[k]! : d }
        var c = EditConfig()
        c.chatKey = g("CHAT_API_KEY")
        c.chatBaseURL = g("CHAT_BASE_URL", "https://api.deepseek.com/v1")
        c.embeddingKey = g("AIHUBMIX_API_KEY")
        c.embeddingBaseURL = g("AIHUBMIX_BASE_URL", "https://aihubmix.com/v1")
        c.transcribeOnline = g("TRANSCRIBE_ONLINE", "true").lowercased() != "false"
        c.transcribeModel = g("TRANSCRIBE_MODEL", "whisper-large-v3-turbo")
        c.transcribeBaseURL = g("TRANSCRIBE_BASE_URL", c.embeddingBaseURL)
        c.transcribeKey = g("TRANSCRIBE_API_KEY", c.embeddingKey)
        c.vaultPath = g("VAULT_PATH")
        c.vaultAutoPush = g("VAULT_AUTOPUSH", "false").lowercased() == "true"
        editConfig = c
    }

    func saveConfig() {
        let c = editConfig
        let updates: [String: String?] = [
            "CHAT_API_KEY": c.chatKey, "CHAT_BASE_URL": c.chatBaseURL,
            "AIHUBMIX_API_KEY": c.embeddingKey, "AIHUBMIX_BASE_URL": c.embeddingBaseURL,
            "TRANSCRIBE_ONLINE": c.transcribeOnline ? "true" : "false",
            "TRANSCRIBE_MODEL": c.transcribeModel,
            "TRANSCRIBE_BASE_URL": c.transcribeBaseURL, "TRANSCRIBE_API_KEY": c.transcribeKey,
            "VAULT_PATH": c.vaultPath,
            "VAULT_AUTOPUSH": c.vaultAutoPush ? "true" : "false",
        ]
        do {
            try ConfigStore.save(updates)
            loadStatus()
            app?.toast("配置已保存 · 即时生效")
        } catch { app?.toast("保存失败：\(error.localizedDescription)") }
    }

    func pickVaultPath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "选为录音库"
        if panel.runModal() == .OK, let url = panel.url { editConfig.vaultPath = url.path }
    }

    func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "resound-config.env"
        panel.message = "导出当前配置（含密钥，作为本机备份/迁移用，注意不要外发）"
        if panel.runModal() == .OK, let url = panel.url {
            do { try ConfigStore.export(to: url); app?.toast("配置已导出") }
            catch { app?.toast("导出失败：\(error.localizedDescription)") }
        }
    }

    func importConfig() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.prompt = "导入"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let n = try ConfigStore.importFrom(url)
                loadConfigEditor(); loadStatus()
                app?.toast("已导入 \(n) 项配置")
            } catch { app?.toast("导入失败：\(error.localizedDescription)") }
        }
    }

    /// 只刷新权限状态——用于 Settings 出现 / app 变 active（从系统设置授权回来）时实时反映。
    func refreshStatus() { loadStatus() }

    private func loadStatus() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let screen = CGPreflightScreenCaptureAccess()
        permRows = [
            PermRow(label: "麦克风", desc: "录制会议中你自己的声音。", granted: mic),
            PermRow(label: "屏幕录制", desc: "采集屏幕中其他参会者的声音。", granted: screen),
            PermRow(label: "自动化 · Chrome", desc: "检测浏览器中开始的 Google Meet 会议。", granted: true),
        ]
        needsAttention = permRows.contains { !$0.granted }
    }

    func openSystemSettings(_ label: String) {
        let url: String
        switch label {
        case "麦克风": url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case "屏幕录制": url = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        default: url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        }
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        app?.toast("正在打开「系统设置 › 隐私与安全性」…")
    }

    // MARK: 模板 CRUD

    var canDeleteTemplate: Bool { templates.count > 1 }
    func openNewTemplate() {
        editTpl = EditTpl(tplId: nil, name: "",
            prompt: "你是会议纪要助手。请基于以下信息输出结构化中文纪要。\n\n会议：{title}（{date}）\n参与者：{speakers}\n\n转录：\n{transcript}")
    }
    func openEditTemplate(_ id: String) {
        if let t = templates.first(where: { $0.id == id }) { editTpl = EditTpl(tplId: t.id, name: t.name, prompt: t.prompt) }
    }
    func saveTemplate() {
        guard let e = editTpl else { return }
        let name = e.name.trimmingCharacters(in: .whitespaces).isEmpty ? "未命名模板" : e.name
        if let id = e.tplId {
            templates = templates.map { $0.id == id ? SummaryTemplate(id: id, name: name, prompt: e.prompt) : $0 }
        } else {
            templates.append(SummaryTemplate(id: "t\(Int(Date().timeIntervalSince1970))", name: name, prompt: e.prompt))
        }
        try? SummaryTemplateStore.save(templates)
        editTpl = nil
        app?.toast("模板已保存")
    }
    func setDefaultTemplate(_ id: String) { defaultTplId = id; app?.toast("已设为默认模板") }
    func confirmDeleteTemplate() {
        guard let id = confirmTplDeleteId else { return }
        templates.removeAll { $0.id == id }
        if defaultTplId == id { defaultTplId = templates.first?.id ?? "" }
        try? SummaryTemplateStore.save(templates)
        confirmTplDeleteId = nil
        app?.toast("模板已删除")
    }
    func insertPlaceholder(_ ph: String) { if editTpl != nil { editTpl!.prompt += ph } }

    /// AI 协助：生成 / 润色模板提示词。结果一定带内置占位符（由 Core 兜底注入）。用 flash 模型，快。
    func aiAssist(_ mode: TemplateAssistMode) {
        guard let e = editTpl, let cfg = try? Config.load() else { return }
        let intent = e.aiIntent, base = e.prompt
        aiBusy = true
        Task {
            let chat = ChatClient(config: cfg, modelOverride: cfg.correctModel)
            let out = await assistTemplatePrompt(mode: mode, intent: intent, base: base, chat: chat)
            aiBusy = false
            if editTpl != nil { editTpl!.prompt = out }
            app?.toast(mode == .generate ? "AI 已生成提示词，可继续编辑" : "AI 已完善提示词，可继续编辑")
        }
    }

    // MARK: 词表 CRUD

    func openNewVocab() { editVocab = EditVocab(vocabId: nil, canonical: "", variants: [], draft: "") }
    func openEditVocab(_ id: String) {
        if let v = vocab.first(where: { $0.id == id }) { editVocab = EditVocab(vocabId: v.id, canonical: v.canonical, variants: v.variants, draft: "") }
    }
    func addVariant() {
        guard var e = editVocab else { return }
        let d = e.draft.trimmingCharacters(in: .whitespaces)
        if !d.isEmpty && !e.variants.contains(d) { e.variants.append(d) }
        e.draft = ""; editVocab = e
    }
    func removeVariant(_ i: Int) { if editVocab != nil, editVocab!.variants.indices.contains(i) { editVocab!.variants.remove(at: i) } }
    func saveVocab() {
        guard var e = editVocab else { return }
        let c = e.canonical.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { app?.toast("请先填写规范词"); return }
        let d = e.draft.trimmingCharacters(in: .whitespaces)
        if !d.isEmpty && !e.variants.contains(d) { e.variants.append(d) }
        guard let vault = vaultURL() else { app?.toast("未设置 VAULT_PATH，无法保存词表"); return }
        if let id = e.vocabId {
            vocab = vocab.map { $0.id == id ? GlossaryEntry(canonical: c, variants: e.variants) : $0 }
        } else {
            vocab.append(GlossaryEntry(canonical: c, variants: e.variants))
        }
        try? GlossaryStore.save(vocab, vaultRoot: vault)
        editVocab = nil
        app?.toast("词条已保存")
    }
    // MARK: 智能错词标注 —— 建议收件箱

    func acceptSuggestion(_ s: CorrectionObservation) {
        guard let vault = vaultURL() else { app?.toast("未设置 VAULT_PATH，无法保存词表"); return }
        CorrectionLearner.accept(s, vaultRoot: vault)
        vocab = GlossaryStore.load(vaultRoot: vault)
        suggestions = CorrectionLearner.pending()
        app?.toast(s.hardReplace ? "已加入词表：\(s.from) → \(s.to)（自动替换）" : "已加入词表：\(s.to)（交给 AI 校对）")
    }

    func dismissSuggestion(_ s: CorrectionObservation) {
        CorrectionLearner.dismiss(s.id)
        suggestions = CorrectionLearner.pending()
    }

    func confirmDeleteVocab() {
        guard let id = confirmVocabDeleteId, let vault = vaultURL() else { return }
        vocab.removeAll { $0.id == id }
        try? GlossaryStore.save(vocab, vaultRoot: vault)
        confirmVocabDeleteId = nil
        app?.toast("词条已删除")
    }
}
