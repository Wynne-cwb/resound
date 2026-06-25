import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ResoundCore

/// 「文档」模块的全部状态（列表 / 导入 / 详情 / 编辑 / 关联录音 / 向本文档提问）。
/// App 级共享，便于在全窗范围渲染模态。后端见 ResoundCore 的 Document/Index/IndexPipeline。
/// 结构与 [LibraryModel] 对称（文档是与录音平级的一等内容类型）。
@MainActor
final class DocumentsModel: ObservableObject {
    weak var app: AppModel?

    enum DetailTab { case content, ask }

    /// 「向本文档提问」的一条消息（绑定当前文档；持久化见 [DocAskStore]）。
    struct DocAskMsg: Identifiable, Equatable {
        enum Phase: Equatable { case searching, thinking, answering, done, empty }
        let id: UUID
        let isUser: Bool
        var full: String
        var revealed: Int
        var phase: Phase
        var cites: [DocCite]
        let ts: Date
    }
    struct DocCite: Identifiable, Equatable {
        let id = UUID()
        let snippet: String      // 被引用的文档段落（文档无时间轴/说话人）
    }

    struct DocImportItem: Identifiable {
        let id = UUID()
        var name: String
        var status: Status
        var error: String? = nil
        enum Status { case parsing, tidying, indexing, done, failed }
    }
    struct EditState: Identifiable { let id: String; var title: String; var tags: [String]; var tagDraft = "" }

    // data
    @Published var documents: [DocumentSummary] = [] { didSet { documentCount = documents.count } }
    @Published private(set) var documentCount = 0
    @Published var selectedId: String?
    @Published var content: String?            // 选中文档的 content.md
    @Published var loadingDetail = false
    @Published var loadError: String?
    @Published var query = ""                  // 列表搜索（标题/标签）
    @Published var tagFilter: String?          // 标签筛选（nil = 全部）
    @Published var tab: DetailTab = .content

    // 录音标题镜像（关联展示/选择器用）
    @Published private(set) var recordingTitles: [String: String] = [:]
    var allRecordings: [(id: String, title: String)] {
        recordingTitles.map { ($0.key, $0.value) }.sorted { $0.title < $1.title }
    }

    // 导入
    @Published var importOpen = false
    @Published var importItems: [DocImportItem] = []

    // 编辑元数据 / 删除
    @Published var editState: EditState?
    @Published var deleteDocId: String?

    // 关联选择器（双向：从文档侧选录音 / 从录音侧选文档）。staged：编辑工作集，「完成」才落盘。
    enum LinkPickerMode: Equatable { case fromDoc(docId: String); case fromRec(recId: String) }
    struct LinkItem: Identifiable { let id: String; let title: String; let sub: String; let isDoc: Bool }
    @Published var linkPicker: LinkPickerMode?
    @Published var linkPickerQuery = ""
    @Published var linkWorking: Set<String> = []   // 工作集：录音 id（fromDoc）或文档 id（fromRec）
    /// 经由 Ask 文档引用跳转过来时，高亮展示被引用的段落原文（轻量：内容上方一张高亮卡）。
    @Published var docHighlight: String?
    /// 从录音侧「导入新文档」进来时，导入成功后自动关联到该录音。
    private var importPrefillRecId: String?

    // 向本文档提问（按 docId 分桶）
    @Published var docChats: [String: [DocAskMsg]] = [:]
    @Published var docAskBusy = false
    @Published var docCiteOpen: Set<UUID> = []
    private let docStore = DocAskStore()
    private var docReveal: Timer?
    var docMsgs: [DocAskMsg] { selectedId.flatMap { docChats[$0] } ?? [] }

    var selected: DocumentSummary? { documents.first { $0.id == selectedId } }
    /// 选中文档关联的录音（id + 标题，标题从镜像解析；解析不到则用 id 占位）。
    var linkedRecordings: [(id: String, title: String)] {
        (selected?.linkedRecordingIds ?? []).map { ($0, recordingTitles[$0] ?? $0) }
    }
    var footerText: String { documents.isEmpty ? "尚无文档" : "\(documents.count) 篇文档" }

    private func cfg() -> Config? { try? Config.load() }
    private func vaultURL() -> URL? { cfg()?.vaultPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } }
    private func dim() -> Int { cfg()?.embeddingDim ?? 4096 }

    /// vault 开了「自动推送」时，后台把文本派生物 commit+push。
    func autoPushVault(_ message: String) {
        guard let cfg = cfg(), cfg.vaultAutoPush, let vault = vaultURL() else { return }
        Task.detached {
            do { _ = try Git(repo: vault).syncTextOnly(message: message) }
            catch { await MainActor.run { self.app?.toast("自动同步失败：\(error.localizedDescription)") } }
        }
    }

    // MARK: 加载

    private var didInitialLoad = false
    func load() {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        loadDocChats()
        reload()
    }
    /// 启动时轻量统计文档数（侧栏角标即时正确）。
    func prefetchCount() {
        guard !didInitialLoad, let vault = vaultURL() else { return }
        Task.detached(priority: .utility) { [weak self] in
            let n = findDocuments(vault).count
            await MainActor.run { guard let self, !self.didInitialLoad else { return }; self.documentCount = n }
        }
    }
    func refresh() { reload() }

    private func reload(reselect: String? = nil) {
        guard let vault = vaultURL() else {
            loadError = "未设置 VAULT_PATH（在设置里配置 vault 路径）"; documents = []; return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let docs = listDocuments(vaultRoot: vault)
            let recs = listRecordings(vaultRoot: vault)
            let titles = Dictionary(recs.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
            await MainActor.run {
                self.documents = docs
                self.recordingTitles = titles
                self.loadError = nil
                if let reselect { self.select(reselect); return }
                if self.selectedId == nil || !docs.contains(where: { $0.id == self.selectedId }) {
                    self.select(docs.last?.id)
                } else {
                    self.refreshDetail()
                }
            }
        }
    }

    func select(_ id: String?) {
        selectedId = id
        tab = .content
        linkPicker = nil
        docHighlight = nil
        refreshDetail()
    }

    /// 从 Ask 的文档引用跳转过来：选中该文档、切到正文 tab、高亮被引段落。
    func openFromCite(docId: String, snippet: String) {
        select(docId)
        docHighlight = snippet
    }

    /// 选中文档关联的录音（id + 标题）；供录音侧「相关文档」反查。
    func relatedDocuments(forRecording recId: String) -> [DocumentSummary] {
        documents.filter { $0.linkedRecordingIds.contains(recId) }
    }

    private var detailToken = 0
    private func refreshDetail() {
        content = nil
        guard let doc = selected else { loadingDetail = false; return }
        loadingDetail = true
        detailToken &+= 1
        let token = detailToken
        let dir = doc.dir
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let text = documentContent(dir)
            await MainActor.run {
                guard self.detailToken == token else { return }
                self.loadingDetail = false
                self.content = text
            }
        }
    }

    /// 所有标签去重（标签筛选条用），按出现频次降序。
    var allTags: [String] {
        var counts: [String: Int] = [:]
        for d in documents { for t in d.tags { counts[t, default: 0] += 1 } }
        return counts.keys.sorted { (counts[$0]!, $1) > (counts[$1]!, $0) }
    }

    /// 列表（先标签筛选，再按搜索过滤标题/标签）。最新的排在最前。
    func filtered() -> [DocumentSummary] {
        var list = documents
        if let tag = tagFilter { list = list.filter { $0.tags.contains(tag) } }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { d in
                d.title.lowercased().contains(q) || d.tags.contains { $0.lowercased().contains(q) }
            }
        }
        return list.reversed()   // documents 按 importedAt 升序；列表展示新→旧
    }

    /// 列表筛选标签（点同一个再点取消）。
    func toggleTagFilter(_ tag: String) { tagFilter = (tagFilter == tag) ? nil : tag }

    /// 列表空结果时，用于提示的当前筛选词。
    var filterLabel: String { tagFilter ?? query }

    // MARK: 导入

    func openImport() { importItems = []; importOpen = true }

    /// 取出并清空一次性的「导入后自动关联录音」预设。
    private func consumePrefillLinks() -> [String] {
        defer { importPrefillRecId = nil }
        return importPrefillRecId.map { ["recording:\($0)"] } ?? []
    }

    /// 导入文件选择器支持的类型（md/txt/pdf/docx/pptx/html/图片）。openFilePicker 与导入弹窗共用。
    func docImportContentTypes() -> [UTType] {
        var types: [UTType] = [.plainText, .text, .pdf, .html, .image]
        for ext in ["md", "markdown", "docx", "pptx"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }

    /// 选本地文档导入（md/txt/pdf/docx/pptx/html/图片）。
    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = docImportContentTypes()
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    /// 导入若干本地文件（先解析富格式 → 写 vault + 真原件 + 建索引，逐个异步）。
    func importFiles(_ urls: [URL]) {
        guard let vault = vaultURL() else { app?.toast("未设置录音库路径（去设置配置 vault）"); return }
        guard !urls.isEmpty else { return }
        importOpen = false
        app?.toast(urls.count == 1 ? "正在导入并解析「\(urls[0].lastPathComponent)」…" : "正在导入 \(urls.count) 个文档…")
        let links = consumePrefillLinks()   // 多文件共用同一组预填关联
        for url in urls { startFileImport(vault: vault, title: "", url: url, tags: [], links: links) }
    }

    /// 单文件导入（标题/标签来自导入弹窗）。
    func importFile(title: String, url: URL, tags: [String]) {
        guard let vault = vaultURL() else { app?.toast("未设置录音库路径（去设置配置 vault）"); return }
        importOpen = false
        app?.toast("正在导入并解析「\(url.lastPathComponent)」…")
        startFileImport(vault: vault, title: title, url: url, tags: tags, links: consumePrefillLinks())
    }

    private func startFileImport(vault: URL, title: String, url: URL, tags: [String], links: [String]) {
        let item = DocImportItem(name: url.lastPathComponent, status: .parsing)
        importItems.append(item)
        let resolved = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? url.deletingPathExtension().lastPathComponent : title
        Task { await ingestFile(itemId: item.id, vault: vault, title: resolved, url: url, tags: tags, links: links) }
    }

    /// 富格式导入主流程：后台解析 → 写 vault（含真原件）→ 建索引。warnings 走 toast，文档照常建。
    private func ingestFile(itemId: UUID, vault: URL, title: String, url: URL,
                            tags: [String], links: [String]) async {
        let raw = await Task.detached { extractDocument(url: url) }.value   // 解析/OCR 离开主线程
        let cfgNow = cfg()
        let willTidy = cfgNow != nil && (raw.sourceFormat == "pdf" || raw.sourceFormat == "image")
            && !raw.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if willTidy { setImportStatus(itemId, .tidying) }
        // PDF/图片 OCR 排版乱 → v4-flash 保语义整理成可读 markdown（其它格式原样返回）
        let result = await tidiedExtraction(raw, config: cfgNow) { AppLog.log($0) }
        setImportStatus(itemId, .indexing)
        if let first = result.warnings.first { app?.toast("⚠️ \(first)（已导入，原件留档）") }
        do {
            let store = DocumentStore(vaultRoot: vault)
            let (manifest, dir) = try store.importDocument(
                title: title, text: result.markdown, sourceFormat: result.sourceFormat,
                tags: tags, links: links, originalFileURL: url)
            if let cfg = cfg() {
                try await IndexPipeline(config: cfg).indexDocument(docDir: dir, indexPath: defaultIndexPath())
            }
            setImportStatus(itemId, .done)
            autoPushVault("doc: 导入 \(manifest.title)")
            if let sum = loadDocumentSummary(dir: dir) { insertDocument(sum); select(sum.id) }
            importItems.removeAll { $0.id == itemId }
            if result.warnings.isEmpty { app?.toast("📄 已加入文档「\(manifest.title)」") }
        } catch {
            AppLog.error("文档导入失败「\(title)」", error)
            setImportStatus(itemId, .failed)
            setImportError(itemId, String(describing: error))
            app?.toast("❌ 文档导入失败「\(title)」：\(shortErr(error))")
        }
    }

    /// 粘贴/输入文本导入。
    func importText(title: String, body: String, tags: [String] = [], links: [String] = []) {
        guard let vault = vaultURL() else { app?.toast("未设置录音库路径（去设置配置 vault）"); return }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { app?.toast("内容为空"); return }
        importOpen = false
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "粘贴的文档" : title
        let item = DocImportItem(name: name, status: .indexing)
        importItems.append(item)
        app?.toast("正在导入文档…")
        let effectiveLinks = links.isEmpty ? consumePrefillLinks() : links
        Task { await ingest(itemId: item.id, vault: vault, title: title, text: body,
                            sourceFormat: "markdown", tags: tags, links: effectiveLinks) }
    }

    /// 导入弹窗统一入口（标题 + 标签 + 来源已在 UI 收齐）。
    func importComposed(title: String, text: String, sourceFormat: String, tags: [String]) {
        guard let vault = vaultURL() else { app?.toast("未设置录音库路径（去设置配置 vault）"); return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { app?.toast("内容为空"); return }
        importOpen = false
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "导入的文档" : title
        let item = DocImportItem(name: name, status: .indexing)
        importItems.append(item)
        app?.toast("正在导入文档…")
        let links = consumePrefillLinks()
        Task { await ingest(itemId: item.id, vault: vault, title: title, text: text,
                            sourceFormat: sourceFormat, tags: tags, links: links) }
    }

    private func ingest(itemId: UUID, vault: URL, title: String, text: String,
                        sourceFormat: String, tags: [String], links: [String]) async {
        do {
            let store = DocumentStore(vaultRoot: vault)
            let (manifest, dir) = try store.importDocument(
                title: title, text: text, sourceFormat: sourceFormat, tags: tags, links: links)
            if let cfg = cfg() {
                try await IndexPipeline(config: cfg).indexDocument(docDir: dir, indexPath: defaultIndexPath())
            }
            setImportStatus(itemId, .done)
            autoPushVault("doc: 导入 \(manifest.title)")
            if let sum = loadDocumentSummary(dir: dir) { insertDocument(sum); select(sum.id) }
            importItems.removeAll { $0.id == itemId }   // 成功即从进度条移除
            app?.toast("📄 已加入文档「\(manifest.title)」")
        } catch {
            AppLog.error("文档导入失败「\(title)」", error)
            setImportStatus(itemId, .failed)
            setImportError(itemId, String(describing: error))
            app?.toast("❌ 文档导入失败「\(title)」：\(shortErr(error))")
        }
    }

    private func insertDocument(_ d: DocumentSummary) {
        guard !documents.contains(where: { $0.id == d.id }) else { return }
        var arr = documents; arr.append(d)
        arr.sort { $0.importedAt < $1.importedAt }
        documents = arr
    }
    private func setImportStatus(_ id: UUID, _ s: DocImportItem.Status) {
        if let i = importItems.firstIndex(where: { $0.id == id }) { importItems[i].status = s }
    }
    private func setImportError(_ id: UUID, _ msg: String?) {
        if let i = importItems.firstIndex(where: { $0.id == id }) { importItems[i].error = msg }
    }
    func dismissImportItem(_ id: UUID) { importItems.removeAll { $0.id == id } }

    /// 错误转 toast 用的短文案（截断，避免 toast 撑爆）。
    private func shortErr(_ error: Error) -> String {
        let s = (error as NSError).localizedDescription
        return s.count > 60 ? String(s.prefix(60)) + "…" : s
    }

    // MARK: 编辑元数据 / 删除

    func openEdit(_ id: String) {
        guard let d = documents.first(where: { $0.id == id }) else { return }
        editState = EditState(id: id, title: d.title, tags: d.tags)
    }
    func addEditTag() {
        guard var st = editState else { return }
        let t = st.tagDraft.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, !st.tags.contains(t) { st.tags.append(t) }
        st.tagDraft = ""; editState = st
    }
    func removeEditTag(_ t: String) {
        guard var st = editState else { return }
        st.tags.removeAll { $0 == t }; editState = st
    }
    func saveEdit() {
        guard let st = editState, let d = documents.first(where: { $0.id == st.id }) else { return }
        let tags = st.tags
        let title = st.title.trimmingCharacters(in: .whitespaces)
        editState = nil
        let dir = d.dir
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            _ = try? DocumentStore(vaultRoot: dir.deletingLastPathComponent()).updateManifest(
                dir: dir, title: title.isEmpty ? nil : title, tags: tags)
            await MainActor.run { self.reload(reselect: d.id); self.app?.toast("已更新"); self.autoPushVault("doc: 编辑 \(title)") }
        }
    }
    func confirmDelete() {
        guard let id = deleteDocId, let d = documents.first(where: { $0.id == id }) else { return }
        deleteDocId = nil
        try? FileManager.default.removeItem(at: d.dir)
        try? Index(path: defaultIndexPath(), dim: dim()).deleteDocument(id: id)
        if docChats[id] != nil { docChats[id] = nil; saveDocChats() }
        if selectedId == id { selectedId = nil }
        reload()
        app?.toast("文档已删除")
        autoPushVault("doc: 删除 \(d.title)")
    }

    // MARK: 关联录音（双向；事实源 document.yaml，索引镜像 doc_links）

    /// 文档详情里「关联录音」行内移除（即时落盘，作用于当前选中文档）。
    func removeLink(_ recId: String) {
        guard let d = selected else { return }
        var ids = d.linkedRecordingIds; ids.removeAll { $0 == recId }
        applyDocLinks(docId: d.id, dir: d.dir, recIds: ids)
    }

    // -- 选择器（两模式 staged）--

    func openLinkFromDoc() {
        guard let d = selected else { return }
        linkPicker = .fromDoc(docId: d.id)
        linkWorking = Set(d.linkedRecordingIds)
        linkPickerQuery = ""
    }
    func openLinkFromRec(_ recId: String) {
        linkPicker = .fromRec(recId: recId)
        linkWorking = Set(relatedDocuments(forRecording: recId).map { $0.id })
        linkPickerQuery = ""
    }
    func toggleLinkWorking(_ id: String) {
        if linkWorking.contains(id) { linkWorking.remove(id) } else { linkWorking.insert(id) }
    }
    func cancelLinkPicker() { linkPicker = nil; linkWorking = []; linkPickerQuery = "" }
    func saveLinkPicker() {
        switch linkPicker {
        case .fromDoc(let docId):
            if let d = documents.first(where: { $0.id == docId }) {
                applyDocLinks(docId: docId, dir: d.dir, recIds: Array(linkWorking))
            }
        case .fromRec(let recId):
            applyRecLinks(recId: recId, docIds: linkWorking)
        case nil: break
        }
        cancelLinkPicker()
    }

    var linkPickerTitle: String {
        switch linkPicker { case .fromDoc: return "关联录音"; case .fromRec: return "关联文档"; case nil: return "" }
    }
    var linkPickerSubtitle: String {
        switch linkPicker {
        case .fromDoc: return "选择要和这篇文档关联的录音。关联后会一起参与问答，并出现在答案的引用里。"
        case .fromRec: return "选择要和这场录音关联的文档，或导入一篇新文档。"
        case nil: return ""
        }
    }
    var linkPickerPlaceholder: String {
        switch linkPicker { case .fromDoc: return "搜索录音…"; case .fromRec, nil: return "搜索文档…" }
    }
    var linkPickerShowImport: Bool { if case .fromRec = linkPicker { return true }; return false }

    func linkPickerItems() -> [LinkItem] {
        let q = linkPickerQuery.trimmingCharacters(in: .whitespaces).lowercased()
        switch linkPicker {
        case .fromDoc:
            return allRecordings
                .filter { q.isEmpty || $0.title.lowercased().contains(q) }
                .map { LinkItem(id: $0.id, title: $0.title, sub: "录音", isDoc: false) }
        case .fromRec:
            return documents
                .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.tags.contains { $0.lowercased().contains(q) } }
                .map { LinkItem(id: $0.id, title: $0.title, sub: $0.sourceFormat, isDoc: true) }
        case nil:
            return []
        }
    }

    /// 从录音侧选择器点「导入新文档」：关掉选择器、打开导入，成功后自动关联回该录音。
    func openImportForRec(_ recId: String) {
        importPrefillRecId = recId
        cancelLinkPicker()
        openImport()
    }

    // -- 落盘 helper（改关联只重写 yaml + 更新索引镜像，不重新 embedding）--

    /// 把某文档的关联录音整体设为 recIds。
    private func applyDocLinks(docId: String, dir: URL, recIds: [String]) {
        let links = recIds.map { "recording:\($0)" }
        let dd = dim()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            _ = try? DocumentStore(vaultRoot: dir.deletingLastPathComponent()).updateManifest(dir: dir, links: links)
            try? Index(path: defaultIndexPath(), dim: dd).setDocLinks(docId: docId, recordingIds: recIds)
            await MainActor.run {
                self.reload(reselect: self.selectedId == docId ? docId : self.selectedId)
                self.autoPushVault("doc: 关联录音 \(docId)")
            }
        }
    }

    /// 让某录音的关联文档集恰好为 docIds（对每篇文档增删 recording:<recId>）。
    private func applyRecLinks(recId: String, docIds: Set<String>) {
        let dd = dim()
        // 计算差异：需要含 recId 的文档 = docIds；当前已含的 = 反查。
        let current = Set(relatedDocuments(forRecording: recId).map { $0.id })
        let toAdd = docIds.subtracting(current)
        let toRemove = current.subtracting(docIds)
        let affected = toAdd.union(toRemove)
        guard !affected.isEmpty else { return }
        // 收集每篇受影响文档的目录与新关联集
        let plan: [(id: String, dir: URL, recIds: [String])] = affected.compactMap { id in
            guard let d = documents.first(where: { $0.id == id }) else { return nil }
            var ids = d.linkedRecordingIds
            if toAdd.contains(id), !ids.contains(recId) { ids.append(recId) }
            if toRemove.contains(id) { ids.removeAll { $0 == recId } }
            return (id, d.dir, ids)
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for p in plan {
                _ = try? DocumentStore(vaultRoot: p.dir.deletingLastPathComponent())
                    .updateManifest(dir: p.dir, links: p.recIds.map { "recording:\($0)" })
                try? Index(path: defaultIndexPath(), dim: dd).setDocLinks(docId: p.id, recordingIds: p.recIds)
            }
            await MainActor.run { self.reload(); self.autoPushVault("doc: 录音 \(recId) 关联文档") }
        }
    }

    // MARK: 向本文档提问（检索限定单篇文档）

    func loadDocChats() {
        docChats = docStore.load().mapValues { stored in
            stored.map { s in
                DocAskMsg(id: s.id, isUser: s.isUser, full: s.text, revealed: s.text.count,
                          phase: .done, cites: s.cites.map { DocCite(snippet: $0.snippet) }, ts: s.ts)
            }
        }
    }
    private func saveDocChats() {
        let map = docChats.mapValues { msgs in
            msgs.filter { $0.isUser || $0.phase == .done }
                .map { StoredDocMsg(id: $0.id, isUser: $0.isUser, text: $0.full,
                                    cites: $0.cites.map { StoredDocCite(snippet: $0.snippet) }, ts: $0.ts) }
        }
        docStore.save(map)
    }
    func toggleDocCite(_ id: UUID) {
        if docCiteOpen.contains(id) { docCiteOpen.remove(id) } else { docCiteOpen.insert(id) }
    }
    func clearDocChat() {
        guard let id = selectedId else { return }
        docReveal?.invalidate(); docChats[id] = []; docAskBusy = false; saveDocChats()
    }
    private func docHistory(_ id: String) -> [ChatTurn] {
        (docChats[id] ?? []).suffix(8).compactMap { m in
            switch m.phase {
            case .searching, .thinking: return nil
            case .empty: return m.isUser ? ChatTurn(isUser: true, text: m.full) : ChatTurn(isUser: false, text: "（无相关内容）")
            default: return m.full.isEmpty ? nil : ChatTurn(isUser: m.isUser, text: m.full)
            }
        }
    }

    func askDocument(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !docAskBusy, let did = selectedId else { return }
        let now = Date()
        docAskBusy = true
        var arr = docChats[did] ?? []
        arr.append(DocAskMsg(id: UUID(), isUser: true, full: q, revealed: q.count, phase: .done, cites: [], ts: now))
        let aid = UUID()
        arr.append(DocAskMsg(id: aid, isUser: false, full: "", revealed: 0, phase: .searching, cites: [], ts: now))
        docChats[did] = arr
        let history = docHistory(did)
        saveDocChats()

        Task {
            defer { docAskBusy = false; saveDocChats() }
            do {
                let cfg = try Config.load()
                patch(did, aid) { $0.phase = .thinking }
                let r = try await IndexPipeline(config: cfg).answerInDocument(
                    question: q, documentId: did, indexPath: defaultIndexPath(), history: history)
                if r.hits.isEmpty {
                    patch(did, aid) { $0.phase = .empty; $0.revealed = 0 }
                    return
                }
                let cites = r.hits.prefix(4).map { DocCite(snippet: $0.text) }
                patch(did, aid) { $0.full = r.text; $0.cites = Array(cites) }
                startReveal(did, aid)
            } catch {
                patch(did, aid) { $0.full = "出错：\(error.localizedDescription)"; $0.phase = .done; $0.revealed = 9999 }
            }
        }
    }

    private func startReveal(_ did: String, _ aid: UUID) {
        patch(did, aid) { $0.phase = .answering }
        docReveal?.invalidate()
        docReveal = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, let arr = self.docChats[did], let i = arr.firstIndex(where: { $0.id == aid }) else { t.invalidate(); return }
                if self.docChats[did]![i].revealed >= self.docChats[did]![i].full.count {
                    t.invalidate(); self.docChats[did]![i].phase = .done; self.saveDocChats(); return
                }
                self.docChats[did]![i].revealed = min(self.docChats[did]![i].full.count, self.docChats[did]![i].revealed + 3)
            }
        }
    }
    private func patch(_ did: String, _ id: UUID, _ f: (inout DocAskMsg) -> Void) {
        guard var arr = docChats[did], let i = arr.firstIndex(where: { $0.id == id }) else { return }
        f(&arr[i]); docChats[did] = arr
    }
}
