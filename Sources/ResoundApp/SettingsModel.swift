import SwiftUI
import AVFoundation
import CoreGraphics
import ResoundCore

/// 设置页状态：就绪状态 / 权限 / 通用开关 / 摘要模板 CRUD / 专有词表 CRUD。
@MainActor
final class SettingsModel: ObservableObject {
    weak var app: AppModel?

    struct EditTpl: Identifiable { var id: String { tplId ?? "__new__" }; var tplId: String?; var name: String; var prompt: String }
    struct EditVocab: Identifiable { var id: String { vocabId ?? "__new__" }; var vocabId: String?; var canonical: String; var variants: [String]; var draft: String }
    struct ConfigRow: Identifiable { let id = UUID(); let label: String; let value: String; let ok: Bool }
    struct PermRow: Identifiable { let id = UUID(); let label: String; let desc: String; let granted: Bool }

    @Published var templates: [SummaryTemplate] = []
    @Published var defaultTplId: String { didSet { UserDefaults.standard.set(defaultTplId, forKey: Self.defKey) } }
    @Published var vocab: [GlossaryEntry] = []

    @Published var editTpl: EditTpl?
    @Published var confirmTplDeleteId: String?
    @Published var editVocab: EditVocab?
    @Published var confirmVocabDeleteId: String?

    @Published var configRows: [ConfigRow] = []
    @Published var permRows: [PermRow] = []
    @Published var needsAttention = false

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
        loadStatus()
    }

    private func loadStatus() {
        let cfg = try? Config.load()
        configRows = [
            ConfigRow(label: "录音库路径", value: cfg?.vaultPath ?? "未设置 VAULT_PATH", ok: !(cfg?.vaultPath ?? "").isEmpty),
            ConfigRow(label: "转写模型", value: cfg.map { "\($0.transcribeModel) · \($0.transcribeOnline ? "在线 aihubmix" : "本地")" } ?? "未配置", ok: cfg != nil),
            ConfigRow(label: "说话人识别", value: cfg?.speakerModel != nil ? "CAM++ 声纹 · 本地" : "未配置 SPEAKER_MODEL", ok: cfg?.speakerModel != nil),
            ConfigRow(label: "嵌入 / 检索", value: cfg.map { "\($0.embeddingModel) · dim \($0.embeddingDim)" } ?? "未配置", ok: cfg != nil),
            ConfigRow(label: "回答模型", value: cfg?.answerModel ?? "未配置", ok: cfg != nil),
        ]
        let mic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let screen = CGPreflightScreenCaptureAccess()
        permRows = [
            PermRow(label: "麦克风", desc: "录制会议中你自己的声音。", granted: mic),
            PermRow(label: "屏幕录制", desc: "采集屏幕中其他参会者的声音。", granted: screen),
            PermRow(label: "自动化 · Chrome", desc: "检测浏览器中开始的 Google Meet 会议。", granted: true),
        ]
        needsAttention = permRows.contains { !$0.granted } || configRows.contains { !$0.ok }
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
    func confirmDeleteVocab() {
        guard let id = confirmVocabDeleteId, let vault = vaultURL() else { return }
        vocab.removeAll { $0.id == id }
        try? GlossaryStore.save(vocab, vaultRoot: vault)
        confirmVocabDeleteId = nil
        app?.toast("词条已删除")
    }
}
