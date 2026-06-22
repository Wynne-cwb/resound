import SwiftUI
import AVFoundation
import AppKit
import ResoundCore

/// 录音库的全部状态（数据 / 播放器 / 摘要 / 说话人 / 各类弹窗）。App 级共享，便于在全窗范围渲染模态。
@MainActor
final class LibraryModel: ObservableObject {
    weak var app: AppModel?

    enum DetailTab { case summary, transcript }

    struct Line: Identifiable {
        let id = UUID()
        let start: Double
        let end: Double
        var text: String
        var speaker: String?     // diarization 标签（真名 / 说话人N / nil）
    }
    struct SpeakerStat: Identifiable {
        var id: String { label }
        let label: String        // diarization 里的原始标签（改名时作为 oldLabel）
        let name: String         // 展示名（同 label）
        let isAnon: Bool
        let isKnown: Bool
        let lineCount: Int
        let pct: Int
        let index: Int           // 配色用
    }
    struct RenameRecState: Identifiable { let id: String; var value: String }
    struct RenameSpeakerState: Identifiable {
        let id = UUID()
        let recId: String
        let label: String
        var value: String
        var remember: Bool
        let isAnon: Bool
    }
    struct ImportItem: Identifiable {
        let id = UUID()
        let url: URL
        var name: String
        var status: Status
        enum Status { case queued, transcribing, identifying, done, failed }
    }

    // data
    @Published var recordings: [RecordingSummary] = []
    @Published var selectedId: String?
    @Published var lines: [Line] = []
    @Published var speakers: [SpeakerStat] = []
    @Published var loadError: String?
    @Published private(set) var knownPeople: [String] = []   // 已注册声纹的人名（命名时可选）
    private var knownNames: Set<String> { Set(knownPeople) }

    // player
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var scrubbing = false
    private var diarSpans: [SpeakerSeg] = []
    private var stopAt: Double?              // 试听片段时的自动停点
    @Published var samplingSpeaker: String?  // 正在试听哪个说话人

    // detail
    @Published var tab: DetailTab = .summary
    @Published var analyzing = false
    @Published var namingInProgress: String?   // 正在保存/注册声纹的说话人标签
    @Published var summaryText: String?
    @Published var summaryTemplateId: String?
    @Published var summarizing = false
    @Published var chosenTemplateId: String?
    @Published var tplMenuOpen = false

    // 文件夹组织 + 录音库检索
    @Published var query = ""                       // 录音库搜索（按标题）
    @Published var folders: [LibraryFolder] = []
    @Published var assign: [String: String] = [:]   // recId -> folderId
    @Published var collapsed: Set<String> = []       // 折叠的分组 key（folderId 或 "_none"）
    @Published var folderEditor: FolderEditor?       // 新建/重命名文件夹弹窗
    @Published var confirmDeleteFolderId: String?
    struct FolderEditor: Identifiable { let id = UUID(); var folderId: String?; var name: String }
    static let unfiledKey = "_none"

    // 查找/替换（修正识别错误）
    @Published var findOpen = false
    @Published var findQuery = ""
    @Published var replaceText = ""

    // modals
    @Published var renameRec: RenameRecState?
    @Published var deleteRecId: String?
    @Published var renameSpeaker: RenameSpeakerState?
    @Published var importOpen = false
    @Published var importing = false
    @Published var importItems: [ImportItem] = []

    var selected: RecordingSummary? { recordings.first { $0.id == selectedId } }
    var hasSpeakers: Bool { !speakers.isEmpty }
    var footerText: String { recordings.isEmpty ? "尚无录音" : "\(recordings.count) 段录音 · 全程本地" }

    private func cfg() -> Config? { try? Config.load() }
    private func vaultURL() -> URL? { cfg()?.vaultPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } }
    private func dim() -> Int { cfg()?.embeddingDim ?? 4096 }

    // MARK: 加载

    func load() {
        guard let vault = vaultURL() else {
            loadError = "未设置 VAULT_PATH（在设置里配置 vault 路径）"; recordings = []; return
        }
        recordings = listRecordings(vaultRoot: vault)
        let org = LibraryStore.load(vaultRoot: vault)
        folders = org.folders
        assign = org.assign
        knownPeople = ((try? Index(path: defaultIndexPath(), dim: dim()))?.loadSpeakerRefs().map { $0.name } ?? []).sorted()
        loadError = recordings.isEmpty ? "vault 里还没有录音" : nil
        if selectedId == nil || !recordings.contains(where: { $0.id == selectedId }) {
            select(recordings.first?.id)
        } else {
            refreshDetail()
        }
    }

    func select(_ id: String?) {
        stopPlayer()
        selectedId = id
        tab = .summary
        tplMenuOpen = false
        currentTime = 0; duration = 0
        refreshDetail()
    }

    private func refreshDetail() {
        lines = []; speakers = []; summaryText = nil; summaryTemplateId = nil; chosenTemplateId = nil
        guard let rec = selected, let t = loadTranscript(rec.transcriptURL) else { return }

        let diar = loadDiarization(rec.dir)
        diarSpans = diar ?? []
        let spans: [(start: Double, end: Double, person: String?)] = diar?.map { ($0.start, $0.end, $0.speaker) } ?? []
        func speakerAt(_ time: Double) -> String? {
            let p = spans.first(where: { $0.start <= time && time <= $0.end })?.person
                ?? spans.min(by: { abs(($0.start + $0.end)/2 - time) < abs(($1.start + $1.end)/2 - time) })?.person
            return (p == "?" ) ? nil : p
        }
        lines = t.segments.map { Line(start: $0.start, end: $0.end, text: $0.text, speaker: spans.isEmpty ? nil : speakerAt(($0.start + $0.end)/2)) }
        buildRoster()

        // 摘要：summary.md 为展示源，模板 id 从 index 读
        summaryText = (try? String(contentsOf: rec.dir.appendingPathComponent("summary.md"), encoding: .utf8))
        summaryTemplateId = (try? Index(path: defaultIndexPath(), dim: dim()))?.recordingSummaryInfo(id: rec.id).template

        // 播放器
        if let p = try? AVAudioPlayer(contentsOf: rec.audioURL) { p.prepareToPlay(); player = p; duration = p.duration }
        else { duration = Double(rec.durationSec) }
    }

    private func buildRoster() {
        let labels = lines.compactMap { $0.speaker }
        guard !labels.isEmpty else { speakers = []; return }
        let total = labels.count
        var order: [String] = []
        var counts: [String: Int] = [:]
        for l in labels { if counts[l] == nil { order.append(l) }; counts[l, default: 0] += 1 }
        speakers = order.enumerated().map { i, label in
            let c = counts[label] ?? 0
            let anon = Self.isAnon(label)
            return SpeakerStat(label: label, name: label, isAnon: anon,
                               isKnown: !anon && knownNames.contains(label),
                               lineCount: c, pct: Int((Double(c) / Double(total) * 100).rounded()), index: i)
        }
    }

    static func isAnon(_ label: String) -> Bool {
        label == "?" || label.range(of: #"^(说话人|Speaker)\s?\d*$"#, options: .regularExpression) != nil
    }

    // MARK: 查找 / 替换（当前 Tab：转录或摘要）

    var findScopeLabel: String { tab == .transcript ? "逐句转录" : "会议摘要" }
    var findMatchCount: Int {
        guard !findQuery.isEmpty else { return 0 }
        let hay = tab == .transcript ? lines.map { $0.text }.joined(separator: "\n") : (summaryText ?? "")
        return hay.components(separatedBy: findQuery).count - 1
    }

    func openFind() { if selected != nil { findOpen = true } }
    func closeFind() { findOpen = false }

    /// 转录里第一条命中查询的行（用于自动滚动定位）。
    func firstMatchLineID() -> UUID? {
        guard tab == .transcript, !findQuery.isEmpty else { return nil }
        return lines.first { $0.text.range(of: findQuery, options: .caseInsensitive) != nil }?.id
    }

    /// 全部替换：写回 transcript.json / summary.md（事实源），并刷新展示。
    func replaceAll() {
        let q = findQuery
        guard !q.isEmpty, let rec = selected else { return }
        let r = replaceText
        if tab == .transcript {
            guard let t = loadTranscript(rec.transcriptURL) else { return }
            var n = 0
            let segs = t.segments.map { seg -> Transcript.Segment in
                n += seg.text.components(separatedBy: q).count - 1
                return Transcript.Segment(id: seg.id, start: seg.start, end: seg.end,
                    text: seg.text.replacingOccurrences(of: q, with: r),
                    words: seg.words.map { Transcript.Word(w: $0.w.replacingOccurrences(of: q, with: r), start: $0.start, end: $0.end) })
            }
            guard n > 0 else { app?.toast("转录里没有匹配「\(q)」"); return }
            try? Transcript(language: t.language, segments: segs).jsonData().write(to: rec.transcriptURL)
            lines = lines.map { var l = $0; l.text = l.text.replacingOccurrences(of: q, with: r); return l }
            app?.toast("已替换 \(n) 处（转录）")
        } else {
            guard var s = summaryText else { return }
            let n = s.components(separatedBy: q).count - 1
            guard n > 0 else { app?.toast("摘要里没有匹配「\(q)」"); return }
            s = s.replacingOccurrences(of: q, with: r)
            summaryText = s
            try? s.data(using: .utf8)?.write(to: rec.dir.appendingPathComponent("summary.md"))
            try? Index(path: defaultIndexPath(), dim: dim()).setRecordingSummary(id: rec.id, summary: s, template: summaryTemplateId)
            app?.toast("已替换 \(n) 处（摘要）")
        }
    }

    // MARK: 文件夹 + 检索

    private func saveOrg() {
        guard let vault = vaultURL() else { return }
        try? LibraryStore.save(LibraryOrganization(folders: folders, assign: assign), vaultRoot: vault)
    }

    /// 分组后的录音库（按搜索过滤）：每个文件夹一组 + 末尾「未分类」。搜索时不受折叠影响。
    struct Section: Identifiable { let id: String; let name: String; let folderId: String?; let recordings: [RecordingSummary] }
    func sections() -> [Section] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func match(_ r: RecordingSummary) -> Bool { q.isEmpty || r.title.lowercased().contains(q) }
        let validFolderIds = Set(folders.map { $0.id })
        var out: [Section] = []
        for f in folders {
            let recs = recordings.filter { assign[$0.id] == f.id && match($0) }
            if q.isEmpty || !recs.isEmpty { out.append(Section(id: f.id, name: f.name, folderId: f.id, recordings: recs)) }
        }
        let unfiled = recordings.filter { r in
            let fid = assign[r.id]
            return (fid == nil || !validFolderIds.contains(fid!)) && match(r)
        }
        if q.isEmpty || !unfiled.isEmpty {
            out.append(Section(id: Self.unfiledKey, name: folders.isEmpty ? "全部录音" : "未分类", folderId: nil, recordings: unfiled))
        }
        return out
    }
    func isCollapsed(_ key: String) -> Bool { query.isEmpty && collapsed.contains(key) }
    func toggleCollapse(_ key: String) { if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) } }

    func openNewFolder() { folderEditor = FolderEditor(folderId: nil, name: "") }
    func openRenameFolder(_ id: String) { if let f = folders.first(where: { $0.id == id }) { folderEditor = FolderEditor(folderId: id, name: f.name) } }
    func saveFolder() {
        guard let e = folderEditor else { return }
        let name = e.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { folderEditor = nil; return }
        if let id = e.folderId { folders = folders.map { $0.id == id ? LibraryFolder(id: id, name: name) : $0 } }
        else { folders.append(LibraryFolder(id: "f\(Int(Date().timeIntervalSince1970 * 1000))", name: name)) }
        folderEditor = nil; saveOrg()
        app?.toast("文件夹已保存")
    }
    func confirmDeleteFolder() {
        guard let id = confirmDeleteFolderId else { return }
        folders.removeAll { $0.id == id }
        assign = assign.filter { $0.value != id }   // 其内录音回到未分类
        confirmDeleteFolderId = nil; saveOrg()
        app?.toast("文件夹已删除")
    }
    func move(_ recId: String, to folderId: String?) {
        if let folderId { assign[recId] = folderId } else { assign[recId] = nil }
        saveOrg()
        app?.toast(folderId == nil ? "已移出文件夹" : "已移到「\(folders.first { $0.id == folderId }?.name ?? "")」")
    }

    /// 从问答引用跳转：选中录音并定位到时间点（页面切换由调用方设置）。
    func openCitation(recId: String, time: Double) {
        if recordings.isEmpty { load() }
        select(recId)
        if time > 0 { seek(to: time) } else { currentTime = 0 }
    }

    // MARK: 识别说话人

    func analyze() {
        guard let rec = selected else { return }
        guard let model = cfg()?.speakerModel else { app?.toast("未设置 SPEAKER_MODEL，无法识别说话人"); return }
        analyzing = true
        Task {
            defer { analyzing = false }
            do {
                _ = try await analyzeSpeakers(rec, model: model)
                refreshDetail()
                app?.toast("已识别说话人。命名后下次可自动认出。")
            } catch { app?.toast("识别失败：\(error)") }
        }
    }

    /// 重新识别：用已记住的声音合并重复的匿名说话人、并自动套上真名。
    func reidentify() {
        guard let rec = selected else { return }
        guard let model = cfg()?.speakerModel else { app?.toast("未设置 SPEAKER_MODEL，无法识别说话人"); return }
        let d = dim()
        analyzing = true
        Task {
            defer { analyzing = false }
            do {
                let segs = try await reidentifySpeakers(rec, model: model, indexPath: defaultIndexPath(), embeddingDim: d)
                refreshDetail(); buildRoster()
                let named = Set(segs.map { $0.speaker }.filter { !$0.hasPrefix("说话人") && $0 != "?" }).count
                app?.toast("已重新识别 · \(speakers.count) 位（自动认出 \(named) 人）")
            } catch { app?.toast("重新识别失败：\(error)") }
        }
    }

    // MARK: 录音改名 / 删除

    func openRenameRec(_ id: String) { if let r = recordings.first(where: { $0.id == id }) { renameRec = .init(id: id, value: r.title) } }
    func saveRenameRec() {
        guard let st = renameRec, let r = recordings.first(where: { $0.id == st.id }) else { return }
        let keep = selectedId
        try? renameRecording(r, to: st.value)
        renameRec = nil
        load(); selectedId = keep
        app?.toast("已重命名")
    }
    func confirmDeleteRec() {
        guard let id = deleteRecId, let r = recordings.first(where: { $0.id == id }) else { return }
        stopPlayer()
        try? deleteRecording(r)
        try? Index(path: defaultIndexPath(), dim: dim()).deleteRecording(id: id)
        deleteRecId = nil
        if selectedId == id { selectedId = nil }
        load()
        app?.toast("录音已删除")
    }

    // MARK: 说话人命名

    /// 命名时的人名建议：按输入做模糊匹配（子串优先，其次字符子序列）。
    func suggestedPeople(for q: String) -> [String] {
        let query = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return knownPeople }
        func subsequence(_ name: String) -> Bool {
            var it = name.startIndex
            for ch in query {
                guard let f = name[it...].firstIndex(of: ch) else { return false }
                it = name.index(after: f)
            }
            return true
        }
        return knownPeople.filter { let n = $0.lowercased(); return n.contains(query) || subsequence(n) }
            .sorted { a, b in a.lowercased().contains(query) && !b.lowercased().contains(query) }
    }

    func openRenameSpeaker(_ label: String) {
        guard let rec = selected else { return }
        let anon = Self.isAnon(label)
        renameSpeaker = .init(recId: rec.id, label: label, value: anon ? "" : label, remember: true, isAnon: anon)
    }
    func saveRenameSpeaker() {
        guard let st = renameSpeaker, let rec = recordings.first(where: { $0.id == st.recId }) else { return }
        let name = st.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { renameSpeaker = nil; return }
        let remember = st.remember
        let model = cfg()?.speakerModel
        let d = dim()
        let label = st.label
        renameSpeaker = nil
        namingInProgress = label
        app?.toast(remember ? "正在记住「\(name)」的声音…" : "正在重命名…")
        Task {
            defer { namingInProgress = nil }
            do {
                let msg = try await renameSpeakerInRecording(
                    rec: rec, oldLabel: label, newName: name, enroll: remember,
                    speakerModel: model, indexPath: defaultIndexPath(), embeddingDim: d)
                refreshDetail()
                knownPeople = ((try? Index(path: defaultIndexPath(), dim: d))?.loadSpeakerRefs().map { $0.name } ?? []).sorted()
                buildRoster()
                app?.toast(msg)
            } catch { app?.toast("命名失败：\(error)") }
        }
    }
    func resetSpeaker() {
        guard let st = renameSpeaker, let rec = recordings.first(where: { $0.id == st.recId }) else { return }
        let idx = (speakers.firstIndex { $0.label == st.label } ?? 0) + 1
        let anon = "说话人\(idx)"
        let d = dim()
        let label = st.label
        renameSpeaker = nil
        namingInProgress = label
        Task {
            defer { namingInProgress = nil }
            _ = try? await renameSpeakerInRecording(rec: rec, oldLabel: label, newName: anon,
                                                    enroll: false, speakerModel: nil, indexPath: defaultIndexPath(), embeddingDim: d)
            refreshDetail(); buildRoster()
            app?.toast("已恢复为匿名标签")
        }
    }

    // MARK: 摘要

    func currentTemplateId() -> String {
        summaryTemplateId ?? chosenTemplateId ?? SummaryTemplateStore.load().first?.id ?? "t_general"
    }
    func chooseTemplate(_ id: String) {
        tplMenuOpen = false
        let hadSummary = summaryText != nil
        chosenTemplateId = id
        if hadSummary { runSummary(id) }
    }
    func generateSummary() { runSummary(currentTemplateId()) }
    func regenerate() { runSummary(currentTemplateId()) }

    private func runSummary(_ tplId: String) {
        guard let rec = selected else { return }
        summarizing = true; tplMenuOpen = false
        Task {
            defer { summarizing = false }
            do {
                let cfg = try Config.load()
                let pipeline = IndexPipeline(config: cfg)
                _ = try await pipeline.summarizeRecording(recDir: rec.dir, indexPath: defaultIndexPath(), templateId: tplId)
                summaryText = (try? String(contentsOf: rec.dir.appendingPathComponent("summary.md"), encoding: .utf8))
                summaryTemplateId = tplId
                let name = SummaryTemplateStore.load().first { $0.id == tplId }?.name ?? "默认"
                app?.toast("已用「\(name)」模板生成摘要")
            } catch { app?.toast("生成摘要失败：\(error)") }
        }
    }

    // MARK: 导入

    func openImport() { importItems = []; importing = false; importOpen = true }
    func cancelImport() { if !importing { importOpen = false; importItems = [] } }
    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff]
        if panel.runModal() == .OK {
            let have = Set(importItems.map { $0.url })
            importItems.append(contentsOf: panel.urls.filter { !have.contains($0) }
                .map { ImportItem(url: $0, name: $0.lastPathComponent, status: .queued) })
        }
    }
    func removeImport(_ id: UUID) { if !importing { importItems.removeAll { $0.id == id } } }

    func startImport() {
        guard !importItems.isEmpty, !importing, let vault = vaultURL() else { return }
        importing = true
        Task {
            let cfg = try? Config.load()
            for i in importItems.indices {
                let item = importItems[i]
                do {
                    setImportStatus(item.id, .transcribing)
                    let out = try await IngestPipeline(vaultRoot: vault)
                        .ingest(audioPath: item.url, title: nil, source: "import", tags: [],
                                model: "large-v3", language: "zh", hints: [], push: false)
                    setImportStatus(item.id, .identifying)
                    if let cfg {
                        let pipeline = IndexPipeline(config: cfg)
                        try await pipeline.indexRecording(recDir: out.recordingDir, indexPath: defaultIndexPath())
                        _ = try? await pipeline.summarizeRecording(recDir: out.recordingDir, indexPath: defaultIndexPath())
                    }
                    setImportStatus(item.id, .done)
                } catch { setImportStatus(item.id, .failed) }
            }
            let n = importItems.filter { $0.status == .done }.count
            importing = false; importOpen = false; importItems = []
            load()
            app?.toast("已导入 \(n) 个录音并完成转写")
        }
    }
    private func setImportStatus(_ id: UUID, _ s: ImportItem.Status) {
        if let i = importItems.firstIndex(where: { $0.id == id }) { importItems[i].status = s }
    }

    // MARK: 播放器

    func togglePlay() {
        clearSample()
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false; stopTimer() }
        else { if currentTime >= duration { p.currentTime = 0; currentTime = 0 }; p.play(); isPlaying = true; startTimer() }
    }
    func seek(to time: Double) {
        clearSample()
        guard let p = player else { return }
        p.currentTime = max(0, min(time, p.duration)); currentTime = p.currentTime
        if !p.isPlaying { p.play(); isPlaying = true; startTimer() }
    }

    /// 试听某说话人最长的一段（用于标注前快速辨认）。
    func playSpeakerSample(_ label: String) {
        guard let p = player else { return }
        if samplingSpeaker == label, p.isPlaying { p.pause(); isPlaying = false; clearSample(); stopTimer(); return }
        let segs = diarSpans.filter { $0.speaker == label }
        guard let best = segs.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return }
        samplingSpeaker = label
        stopAt = min(best.end, p.duration)
        p.currentTime = max(0, min(best.start, p.duration)); currentTime = p.currentTime
        p.play(); isPlaying = true; startTimer()
    }
    private func clearSample() { stopAt = nil; samplingSpeaker = nil }

    func scrubBegan() { clearSample(); scrubbing = true }
    func scrub(to time: Double) { if scrubbing { currentTime = max(0, min(time, duration)) } }
    func scrubEnded(to time: Double) {
        scrubbing = false
        player?.currentTime = max(0, min(time, duration)); currentTime = player?.currentTime ?? time
    }
    func stopPlayer() { clearSample(); player?.stop(); player = nil; isPlaying = false; stopTimer() }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, !self.scrubbing else { return }
                self.currentTime = p.currentTime
                if let stop = self.stopAt, p.currentTime >= stop {   // 试听片段到点自动停
                    p.pause(); self.isPlaying = false; self.clearSample(); self.stopTimer(); return
                }
                if !p.isPlaying { self.isPlaying = false; self.stopTimer() }
            }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
}
