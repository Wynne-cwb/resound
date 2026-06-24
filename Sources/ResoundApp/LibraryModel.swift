import SwiftUI
import AVFoundation
import AppKit
import ResoundCore

/// 录音库的全部状态（数据 / 播放器 / 摘要 / 说话人 / 各类弹窗）。App 级共享，便于在全窗范围渲染模态。
@MainActor
final class LibraryModel: ObservableObject {
    weak var app: AppModel?

    enum DetailTab { case summary, transcript }

    /// id 用转录段自身的稳定 id（transcript.json 的 segment id），不再每次载入用新 UUID——
    /// 否则重载/识别完成后所有行身份全变 → SwiftUI 全量重建、丢滚动位置。Equatable 让 SwiftUI 能跳过未变的行。
    struct Line: Identifiable, Equatable {
        let id: Int
        let start: Double
        let end: Double
        var text: String
        var speaker: String?     // diarization 标签（真名 / 说话人N / nil）
    }
    /// 连续同一说话人的若干行合并成的段落块——名字每段只贴一次，消除视觉「散」。仅作中间结构。
    struct Block: Identifiable, Equatable {
        let speaker: String?
        let lines: [Line]
        var id: Int { lines.first?.id ?? -1 }   // 稳定 id（首行段 id）
    }
    /// 拍平后的转录行（逐句转录渲染用）：每行都是单层 LazyVStack 的直接子项，
    /// 故 `scrollTo(line.id)` 必然可寻址（块嵌套 ForEach 里行 id 不可直接定位 → 引用跳转滚不过去）；
    /// 也避免长段落里一个块塞几百行非懒加载渲染的卡顿。chip 仅在说话人切换的段首非 nil。
    struct FlatLine: Identifiable, Equatable {
        let line: Line
        let chip: String?
        var id: Int { line.id }
    }
    /// 播放头——只放高频(0.25s/次)跳变的 currentTime。单独成 ObservableObject，
    /// 让逐句转录列表（观察 LibraryModel）不会因为播放头每秒 4 次而整页重算。
    @MainActor final class Playhead: ObservableObject {
        @Published var time: Double = 0
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
        var error: String? = nil        // 失败原因（供 UI 显示 + 重试前清空）
        var source: String = "import"   // "import"（用户文件，原处可重导）/ "meeting"（录音兜底，url 是抢救出的音频）
        enum Status { case queued, transcribing, identifying, done, failed }
    }

    // data
    @Published var recordings: [RecordingSummary] = [] { didSet { recordingCount = recordings.count } }
    /// 侧栏角标用的录音数。启动时由 `prefetchCount()` 轻量后台统计先填上（不等进 Library 全量加载）；
    /// 全量加载/增删后由 recordings.didSet 同步为权威值。
    @Published private(set) var recordingCount = 0
    @Published var selectedId: String?
    @Published var lines: [Line] = []
    @Published var blocks: [Block] = []        // lines 按连续同人合并后的段落块（中间结构）
    @Published var flatLines: [FlatLine] = []  // 拍平后的逐句转录行（渲染用，单层 LazyVStack）
    @Published var speakers: [SpeakerStat] = []
    @Published var loadError: String?
    @Published var loadingDetail = false   // 正在后台载入该条录音详情（转录/摘要/名册）
    @Published private(set) var knownPeople: [String] = []   // 已注册声纹的人名（命名时可选）
    private var knownNames: Set<String> { Set(knownPeople) }

    // player
    @Published var isPlaying = false
    @Published var decodingAudio = false    // 首次播放正在后台解码音频（播放键转圈）
    let playhead = Playhead()                // 高频 currentTime 单独发布（见上）
    /// currentTime 代理到 playhead.time：内部代码照常读写，但**不再触发 LibraryModel 的 objectWillChange**，
    /// 因此播放时不会每秒 4 次重算整个详情页/转录列表（只有观察 playhead 的播放条会刷新）。
    var currentTime: Double { get { playhead.time } set { playhead.time = newValue } }
    @Published var activeLineID: Int?        // 当前播放头所在的转录行（仅跨行时跳变 → 转录列表很少重绘）
    @Published var duration: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var scrubbing = false
    private var diarSpans: [SpeakerSeg] = []
    private var stopAt: Double?              // 试听片段时的自动停点
    @Published var samplingSpeaker: String?  // 正在试听哪个说话人

    // detail
    @Published var tab: DetailTab = .summary
    @Published var scrollToLine: Int?       // 引用跳转：详情载入后要滚动定位到的转录行（段 id）
    private var pendingCiteTime: Double?     // 引用带的时间点，等详情后台载入完再定位
    @Published var analyzingId: String?     // 正在识别说话人的录音 id（仅该条显示 loading，不影响其他）
    var analyzing: Bool { analyzingId != nil && analyzingId == selectedId }
    @Published var identifyingIds: Set<String> = []   // 导入后台正在识别说话人(+摘要)的录音 id（可多条排队）
    var identifyingSelected: Bool { selectedId.map { identifyingIds.contains($0) } ?? false }
    private var speakerQueue: [RecordingSummary] = []  // 后台说话人识别串行队列（避免多条同时跑 Sortformer 抢 ANE）
    private var speakerWorking = false
    @Published var namingInProgress: String?   // 正在保存/注册声纹的说话人标签
    @Published var summaryText: String?
    @Published var summaryTemplateId: String?
    @Published var summarizingIds: Set<String> = []   // 正在生成摘要的录音 id（可并发多条，各自显示 loading）
    var summarizing: Bool { selectedId.map { summarizingIds.contains($0) } ?? false }
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
    @Published var reindexing = false              // 转录改完后，正在把更正同步进检索索引
    private var reindexTask: Task<Void, Never>?

    // 文件夹：移动菜单 + 拖拽
    @Published var moveMenuFor: String?            // 哪条录音打开了「移动到」浮层
    @Published var dragRecId: String?              // 正在拖拽的录音（拖拽中半透明）
    @Published var dragOverFolder: String?         // 拖拽悬停到的目标文件夹组
    private var pendingMoveRecId: String?          // 「新建文件夹…」创建后要落入的录音

    // modals
    @Published var renameRec: RenameRecState?
    @Published var deleteRecId: String?
    @Published var renameSpeaker: RenameSpeakerState?
    @Published var importOpen = false
    @Published var importing = false
    @Published var importItems: [ImportItem] = []
    @Published var pendingImports: [ImportItem] = []   // 已入列、正在后台转写的导入项（显示在录音库顶部）

    var selected: RecordingSummary? { recordings.first { $0.id == selectedId } }
    var hasSpeakers: Bool { !speakers.isEmpty }
    var footerText: String { recordings.isEmpty ? "尚无录音" : "\(recordings.count) 段录音 · 全程本地" }

    private func cfg() -> Config? { try? Config.load() }
    private func vaultURL() -> URL? { cfg()?.vaultPath.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } }
    private func dim() -> Int { cfg()?.embeddingDim ?? 4096 }

    /// vault 是 git repo 且开了「自动推送」时，后台把文本派生物 commit+push（音频已 gitignore）。
    func autoPushVault(_ message: String) {
        guard let cfg = cfg(), cfg.vaultAutoPush, let vault = vaultURL() else { return }
        Task.detached {
            do {
                let pushed = try Git(repo: vault).syncTextOnly(message: message)
                if pushed { await MainActor.run { self.app?.toast("已同步到 vault 远端") } }
            } catch {
                await MainActor.run { self.app?.toast("自动同步失败：\(error.localizedDescription)") }
            }
        }
    }

    // MARK: 加载

    private var didInitialLoad = false
    /// 切页进入 Library 调用。**幂等**：仅首次扫盘，之后什么都不做——
    /// 拾取新录音靠 `libraryReloadToken` 走 `refresh()`，导入/删除/改名各自走增量或显式 reload。
    /// 修复：原来每次切到 Library 都 reload→refreshDetail（先把转录/名册塌空再后台重解码 JSON+flatten+roster），
    /// 即「啥都没改也重算两轮整树失效」，长转录肉眼可感卡顿。
    func load() {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        reload()
    }

    /// 启动时轻量统计录音数（只扫盘数 manifest，不加载详情/声纹/sqlite），让侧栏角标即时正确——
    /// 不必等用户进 Library 触发全量加载。全量加载会接管为权威值。
    func prefetchCount() {
        guard !didInitialLoad, let vault = vaultURL() else { return }
        Task.detached(priority: .utility) { [weak self] in
            let n = listRecordings(vaultRoot: vault).count
            await MainActor.run { guard let self, !self.didInitialLoad else { return }; self.recordingCount = n }
        }
    }
    /// libraryReloadToken 变更（录音/导入完成）：强制全量刷新以拾取新录音。
    func refresh() { reload() }

    /// 全量刷新录音库。扫盘 + 解析 manifest + 开 sqlite 读声纹**全部放后台**（原来同步在主线程，
    /// 录音多了点开/切页/导入都卡）。算完回主线程一次性发布。
    /// - reselect: 刷新后要选中的录音 id（重命名/删除后保持选中）。
    /// - then: 列表就绪后在主线程执行（引用跳转用：先确保列表，再定位）。
    private func reload(reselect: String? = nil, then: (() -> Void)? = nil) {
        guard let vault = vaultURL() else {
            loadError = "未设置 VAULT_PATH（在设置里配置 vault 路径）"; recordings = []; return
        }
        let d = dim(); let indexPath = defaultIndexPath()
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let recs = listRecordings(vaultRoot: vault)
            let org = LibraryStore.load(vaultRoot: vault)
            let known = ((try? Index(path: indexPath, dim: d))?.loadSpeakerRefs().map { $0.name } ?? []).sorted()
            await MainActor.run {
                self.recordings = recs
                self.folders = org.folders; self.assign = org.assign
                self.loadCollapsed()
                self.knownPeople = known
                self.loadError = recs.isEmpty ? "vault 里还没有录音" : nil
                if let reselect { self.selectedId = reselect }
                if let then { then(); return }
                // 引用跳转进行中：列表刷新即可，别再 select/refreshDetail（那会 bump detailToken，作废跳转）。
                if self.pendingCiteTime != nil { return }
                if self.selectedId == nil || !recs.contains(where: { $0.id == self.selectedId }) {
                    self.select(recs.last?.id)   // 默认选最新（现在排在最下）
                } else {
                    self.refreshDetail()
                }
            }
        }
    }

    /// 导入后增量插入单条录音（按时间倒序就位），避免每个文件都 reload() 全量扫盘。
    private func insertRecording(_ r: RecordingSummary) {
        guard !recordings.contains(where: { $0.id == r.id }) else { return }
        var arr = recordings
        arr.append(r)
        arr.sort { $0.recordedAt < $1.recordedAt }   // 升序：最新在末（列表最下）
        recordings = arr
    }

    /// 后台识别说话人完成后，把该条的 identified 标志置真（列表「待识别」徽标即时消失，免重扫）。
    private func markIdentified(_ id: String) {
        guard let i = recordings.firstIndex(where: { $0.id == id }), !recordings[i].identified else { return }
        let r = recordings[i]
        recordings[i] = RecordingSummary(id: r.id, title: r.title, recordedAt: r.recordedAt,
                                         durationSec: r.durationSec, dir: r.dir, audioFile: r.audioFile, identified: true)
    }

    func select(_ id: String?) {
        stopPlayer()
        selectedId = id
        tab = .summary
        tplMenuOpen = false
        moveMenuFor = nil; dragRecId = nil
        currentTime = 0; duration = 0
        refreshDetail()
    }

    private var detailToken = 0   // 切换录音时自增；后台计算回主线程前比对，丢弃过期结果

    private func refreshDetail() {
        lines = []; blocks = []; flatLines = []; speakers = []
        summaryText = nil; summaryTemplateId = nil; chosenTemplateId = nil
        diarSpans = []; currentTime = 0; activeLineID = nil; decodingAudio = false
        player = nil   // 懒加载：旧播放器已由 select() 的 stopPlayer() 释放，按下播放时才解码音频
        guard let rec = selected else { duration = 0; loadingDetail = false; return }
        duration = Double(rec.durationSec)   // 用元数据时长即时占位，避免同步解码长音频卡住点开
        loadingDetail = true

        detailToken &+= 1
        let token = detailToken
        let d = dim(); let indexPath = defaultIndexPath(); let known = knownNames

        // 文件读取 + JSON 解码 + 标签平滑 + 索引查询全部放后台，算完回主线程一次性发布，
        // 否则点开每条录音都在主线程做这些 I/O，录音多了越来越卡。
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var payload: (spans: [SpeakerSeg], lines: [Line], blocks: [Block], roster: [SpeakerStat])?
            if let t = loadTranscript(rec.transcriptURL) {
                let spans = loadDiarization(rec.dir) ?? []
                func speakerAt(_ time: Double) -> String? {
                    let p = spans.first(where: { $0.start <= time && time <= $0.end })?.speaker
                        ?? spans.min(by: { abs(($0.start + $0.end)/2 - time) < abs(($1.start + $1.end)/2 - time) })?.speaker
                    return (p == "?") ? nil : p
                }
                let raw = t.segments.map { Line(id: $0.id, start: $0.start, end: $0.end, text: $0.text,
                                                speaker: spans.isEmpty ? nil : speakerAt(($0.start + $0.end)/2)) }
                let ls = self.smoothSpeakers(raw)
                payload = (spans, ls, self.groupBlocks(ls), Self.makeRoster(from: ls, known: known))
            }
            let summary = (try? String(contentsOf: rec.dir.appendingPathComponent("summary.md"), encoding: .utf8))
            let tplId = (try? Index(path: indexPath, dim: d))?.recordingSummaryInfo(id: rec.id).template
            let result = payload
            await MainActor.run {
                guard self.detailToken == token else { return }   // 用户已切走，丢弃
                self.loadingDetail = false
                if let p = result {
                    self.diarSpans = p.spans
                    self.lines = p.lines; self.blocks = p.blocks; self.speakers = p.roster
                    self.flatLines = Self.flatten(p.blocks)
                    // 引用跳转：详情载入完成后，定位到该时间点所在的转录行（让 detailScroll 滚过去）
                    if let t = self.pendingCiteTime, !p.lines.isEmpty {
                        let hit = p.lines.first(where: { $0.start <= t && t < $0.end })
                            ?? p.lines.min(by: { abs(($0.start + $0.end)/2 - t) < abs(($1.start + $1.end)/2 - t) })
                        self.scrollToLine = hit?.id
                    }
                }
                self.pendingCiteTime = nil   // 一次详情载入后即清，避免后续 load() 一直被 guard 早退
                self.summaryText = summary; self.summaryTemplateId = tplId
            }
        }
    }

    private func buildRoster() { speakers = Self.makeRoster(from: lines, known: knownNames) }

    nonisolated static func makeRoster(from lines: [Line], known: Set<String>) -> [SpeakerStat] {
        let labels = lines.compactMap { $0.speaker }
        guard !labels.isEmpty else { return [] }
        let total = labels.count
        var order: [String] = []
        var counts: [String: Int] = [:]
        for l in labels { if counts[l] == nil { order.append(l) }; counts[l, default: 0] += 1 }
        let stats = order.map { label -> SpeakerStat in
            let c = counts[label] ?? 0
            let anon = isAnon(label)
            return SpeakerStat(label: label, name: label, isAnon: anon,
                               isKnown: !anon && known.contains(label),
                               lineCount: c, pct: Int((Double(c) / Double(total) * 100).rounded()), index: 0)
        }
        // 按说话占比降序（说得多的排前，更符合多人会议的直觉）；配色已改用名字稳定哈希，index 仅留作兼容。
        return stats.sorted { $0.lineCount > $1.lineCount }.enumerated().map { i, s in
            SpeakerStat(label: s.label, name: s.name, isAnon: s.isAnon, isKnown: s.isKnown,
                        lineCount: s.lineCount, pct: s.pct, index: i)
        }
    }

    /// 平滑逐行说话人：被前后「同一个人」夹住、且很短(<minDur)的小段，视为逐窗声纹匹配抖动，并入两侧。
    /// 平滑逐行说话人，消除两类抖动（反复扫描到稳定）：
    /// A. 被**同一个人**夹住的 <3s 短掉点 → 并入两侧（偶发误标）。
    /// B. **从不持续发言的「噪点说话人」**（最长一段都 < `ephemeralMax`，多为转场边界窗的混合声纹误配/匿名小堆）
    ///    → 其短段并入相邻的「真实说话人」。真实说话人=曾有过 ≥`ephemeralMax` 的完整发言段，永不被吸收，
    ///    因此 1-on-1 里的幽灵人(Sara/说话人N)被清掉，而多人会议里真有简短发言的人(曾说满一段)受保护。
    nonisolated private func smoothSpeakers(_ input: [Line]) -> [Line] {
        // 委托给 Core 的同一套算法（避免两处实现漂移）。nil ↔ "?" 互转。
        let segs = input.map { SpeakerSeg(start: $0.start, end: $0.end, speaker: $0.speaker ?? "?") }
        let sm = smoothSpeakerSegs(segs)
        return zip(input, sm).map { var l = $0; l.speaker = ($1.speaker == "?") ? nil : $1.speaker; return l }
    }

    /// 把连续同一说话人的行合并成段落块。
    nonisolated private func groupBlocks(_ lines: [Line]) -> [Block] {
        var out: [Block] = []
        var cur: [Line] = []
        for l in lines {
            if let last = cur.last, last.speaker != l.speaker {
                out.append(Block(speaker: cur[0].speaker, lines: cur)); cur = []
            }
            cur.append(l)
        }
        if !cur.isEmpty { out.append(Block(speaker: cur[0].speaker, lines: cur)) }
        return out
    }

    /// 段落块 → 拍平行：每段首行带 chip(说话人)，其余 nil。
    nonisolated static func flatten(_ blocks: [Block]) -> [FlatLine] {
        var out: [FlatLine] = []
        for b in blocks {
            for (i, l) in b.lines.enumerated() {
                out.append(FlatLine(line: l, chip: i == 0 ? b.speaker : nil))
            }
        }
        return out
    }

    /// 大小写不敏感地数 needle 在 hay 中的出现次数——与查找高亮、替换口径统一。
    nonisolated static func ciCount(_ hay: String, _ needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var n = 0, lo = hay.startIndex
        while let r = hay.range(of: needle, options: .caseInsensitive, range: lo..<hay.endIndex) {
            n += 1; lo = r.upperBound
        }
        return n
    }

    nonisolated static func isAnon(_ label: String) -> Bool {
        label == "?" || label.range(of: #"^(说话人|Speaker)\s?\d*$"#, options: .regularExpression) != nil
    }

    // MARK: 查找 / 替换（当前 Tab：转录或摘要）

    var findScopeLabel: String { tab == .transcript ? "逐句转录" : "会议摘要" }
    var findMatchCount: Int {
        guard !findQuery.isEmpty else { return 0 }
        let hay = tab == .transcript ? lines.map { $0.text }.joined(separator: "\n") : (summaryText ?? "")
        return Self.ciCount(hay, findQuery)
    }

    func openFind() { if selected != nil { findOpen = true } }
    func closeFind() { findOpen = false }

    /// 转录里第一条命中查询的行（用于自动滚动定位）。
    func firstMatchLineID() -> Int? {
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
                n += Self.ciCount(seg.text, q)
                return Transcript.Segment(id: seg.id, start: seg.start, end: seg.end,
                    text: seg.text.replacingOccurrences(of: q, with: r, options: .caseInsensitive),
                    words: seg.words.map { Transcript.Word(w: $0.w.replacingOccurrences(of: q, with: r, options: .caseInsensitive), start: $0.start, end: $0.end) })
            }
            guard n > 0 else { app?.toast("转录里没有匹配「\(q)」"); return }
            try? Transcript(language: t.language, segments: segs).jsonData().write(to: rec.transcriptURL)
            lines = lines.map { var l = $0; l.text = l.text.replacingOccurrences(of: q, with: r, options: .caseInsensitive); return l }
            blocks = groupBlocks(lines); flatLines = Self.flatten(blocks)
            app?.toast("已替换 \(n) 处（转录）· 正在同步检索…")
            scheduleReindex(rec)   // 更正后重建该条索引，Ask 才会用到正确文本
            autoPushVault("edit: 转录更正 \(rec.title)")
            observeCorrection(from: q, to: r, rec: rec)   // 智能词表：跨录音累计同样的更正，够了就建议加入词表
        } else {
            guard var s = summaryText else { return }
            let n = Self.ciCount(s, q)
            guard n > 0 else { app?.toast("摘要里没有匹配「\(q)」"); return }
            s = s.replacingOccurrences(of: q, with: r, options: .caseInsensitive)
            summaryText = s
            try? s.data(using: .utf8)?.write(to: rec.dir.appendingPathComponent("summary.md"))
            try? Index(path: defaultIndexPath(), dim: dim()).setRecordingSummary(id: rec.id, summary: s, template: summaryTemplateId)
            app?.toast("已替换 \(n) 处（摘要）")
            autoPushVault("edit: 摘要更正 \(rec.title)")
        }
    }

    /// 智能错词标注：把这次「错→对」更正记进学习器（按不同录音去重累计）。
    /// 跨录音攒够阈值（已知词第 1 次 / 新词 2 次）即即时提示，去 设置 › 专有词表 收件箱一键加入。
    private func observeCorrection(from q: String, to r: String, rec: RecordingSummary) {
        guard let vault = vaultURL() else { return }
        let known = Set(GlossaryStore.load(vaultRoot: vault).map { $0.canonical })
        guard let sug = CorrectionLearner.record(from: q, to: r, recordingId: rec.id, knownCanonicals: known) else { return }
        let how = sug.hardReplace ? "自动替换" : "AI 校对"
        app?.toast("「\(q) → \(r)」已第 \(sug.count) 次更正 · 去 设置 › 专有词表 一键加入（\(how)）")
    }

    /// 转录更正后重建该条录音的检索索引（切块→上下文→embedding，幂等）。
    /// 防抖 1.5s，连续多次替换合并成一次重建，避免重复嵌入。
    private func scheduleReindex(_ rec: RecordingSummary) {
        reindexTask?.cancel()
        reindexTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !Task.isCancelled else { return }
            self.reindexing = true
            defer { self.reindexing = false }
            do {
                let cfg = try Config.load()
                try await IndexPipeline(config: cfg).indexRecording(recDir: rec.dir, indexPath: defaultIndexPath())
                guard !Task.isCancelled else { return }   // 被新一次替换取代，别报“成功”
                app?.toast("检索已同步，Ask 将用更正后的内容")
            } catch is CancellationError {
                // 被后续替换取代而取消，不是失败，静默
            } catch let e as URLError where e.code == .cancelled {
                // 网络请求随 Task 取消，静默
            } catch {
                app?.toast("同步检索失败：\(error.localizedDescription)")
            }
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
    func toggleCollapse(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) } else { collapsed.insert(key) }
        saveCollapsed()
    }

    // 折叠状态是机器本地的 UI 偏好（非 vault 事实），存 UserDefaults，下次进来沿用上次的展开/折叠。
    private static let collapsedKey = "resound.collapsedFolders"
    private func saveCollapsed() { UserDefaults.standard.set(Array(collapsed), forKey: Self.collapsedKey) }
    private func loadCollapsed() { collapsed = Set((UserDefaults.standard.array(forKey: Self.collapsedKey) as? [String]) ?? []) }

    func openNewFolder(moveRec: String? = nil) { pendingMoveRecId = moveRec; moveMenuFor = nil; folderEditor = FolderEditor(folderId: nil, name: "") }
    func openRenameFolder(_ id: String) { if let f = folders.first(where: { $0.id == id }) { folderEditor = FolderEditor(folderId: id, name: f.name) } }
    func openMoveMenu(_ id: String) { moveMenuFor = (moveMenuFor == id) ? nil : id }
    func closeMoveMenu() { moveMenuFor = nil }
    func saveFolder() {
        guard let e = folderEditor else { return }
        let name = e.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { folderEditor = nil; pendingMoveRecId = nil; return }
        if let id = e.folderId { folders = folders.map { $0.id == id ? LibraryFolder(id: id, name: name) : $0 } }
        else {
            let nf = LibraryFolder(id: "f\(Int(Date().timeIntervalSince1970 * 1000))", name: name)
            folders.append(nf)
            if let rid = pendingMoveRecId { assign[rid] = nf.id }   // 「新建文件夹…」后把这条移进去
        }
        pendingMoveRecId = nil; folderEditor = nil; saveOrg()
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
        moveMenuFor = nil; dragRecId = nil; dragOverFolder = nil
        saveOrg()
        app?.toast(folderId == nil ? "已移出文件夹" : "已移到「\(folders.first { $0.id == folderId }?.name ?? "")」")
    }

    /// 从问答引用跳转：选中录音、切到逐句转录、定位到时间点（页面切换由调用方设置）。
    func openCitation(recId: String, time: Double) {
        scrollToLine = nil
        pendingCiteTime = time > 0 ? time : nil   // 先置（reload 的 guard 靠它），select→refreshDetail 后台载入完再定位
        if recordings.contains(where: { $0.id == recId }) {
            applyCitation(recId, time)
        } else {
            // 列表还没加载（如直接从 Ask 跳来）：后台扫盘就绪后再定位，别同步卡主线程
            reload(then: { [weak self] in self?.applyCitation(recId, time) })
        }
    }
    private func applyCitation(_ recId: String, _ time: Double) {
        select(recId)                              // 注意：select 会把 tab 置为 .summary
        if time > 0 {
            tab = .transcript                      // 引用带时间→直接看逐句转录
            seek(to: time)                         // 同时把播放头移到该处
        } else {
            currentTime = 0
        }
    }

    // MARK: 识别说话人

    func analyze() {
        guard let rec = selected else { return }
        guard let model = cfg()?.speakerModel else { app?.toast("未设置 SPEAKER_MODEL，无法识别说话人"); return }
        let d = dim()
        analyzingId = rec.id
        Task {
            defer { if analyzingId == rec.id { analyzingId = nil } }
            do {
                // 真 diarization 优先（干净轮次→簇级声纹+VAD→匹配真名）；多人会(≥4簇)自动回退逐窗法
                let segs = try await identifySpeakersByDiarization(rec, model: model, indexPath: defaultIndexPath(), embeddingDim: d)
                refreshDetail()
                let named = Set(segs.map { $0.speaker }.filter { !$0.hasPrefix("说话人") && $0 != "?" }).count
                app?.toast(named > 0 ? "已识别 · 自动认出 \(named) 人（命名匿名者后下次也能自动认出）"
                                     : "已识别说话人。命名后下次可自动认出。")
            } catch { app?.toast("识别失败：\(error)") }
        }
    }

    /// 重新识别：用已记住的声音合并重复的匿名说话人、并自动套上真名。
    func reidentify() {
        guard let rec = selected else { return }
        guard let model = cfg()?.speakerModel else { app?.toast("未设置 SPEAKER_MODEL，无法识别说话人"); return }
        let d = dim()
        analyzingId = rec.id
        Task {
            defer { if analyzingId == rec.id { analyzingId = nil } }
            do {
                let segs = try await reidentifySpeakers(rec, model: model, indexPath: defaultIndexPath(), embeddingDim: d)
                refreshDetail(); buildRoster()
                let named = Set(segs.map { $0.speaker }.filter { !$0.hasPrefix("说话人") && $0 != "?" }).count
                app?.toast("已重新识别 · \(speakers.count) 位（自动认出 \(named) 人）")
            } catch { app?.toast("重新识别失败：\(error)") }
        }
    }

    /// 把一条录音排进后台说话人识别队列：识别说话人(Sortformer，慢)→生成摘要(带真名)。
    /// 串行执行（一次一条），期间 `identifyingIds` 含该 id，UI 显示「识别说话人中…」。
    /// 导入时调用——让转录+入库一完成就先露出录音（可读/可搜/可问答），重活后台慢慢补。
    func enqueueSpeakerID(_ rec: RecordingSummary) {
        if !speakerQueue.contains(where: { $0.id == rec.id }) { speakerQueue.append(rec) }
        identifyingIds.insert(rec.id)
        runSpeakerWorker()
    }
    private func runSpeakerWorker() {
        guard !speakerWorking else { return }
        guard let cfg = cfg(), let model = cfg.speakerModel else {
            identifyingIds.removeAll(); speakerQueue.removeAll(); return   // 没配 SPEAKER_MODEL：放弃后台识别
        }
        speakerWorking = true
        let d = cfg.embeddingDim
        Task {
            defer { speakerWorking = false }
            while !speakerQueue.isEmpty {
                let rec = speakerQueue.removeFirst()   // 队列直接存录音，不再每条全量扫盘取一条
                _ = try? await identifySpeakersByDiarization(rec, model: model, indexPath: defaultIndexPath(), embeddingDim: d)
                _ = try? await IndexPipeline(config: cfg).summarizeRecording(recDir: rec.dir, indexPath: defaultIndexPath())
                identifyingIds.remove(rec.id)
                markIdentified(rec.id)
                autoPushVault("rec: 识别说话人+摘要 \(rec.title)")
                if selectedId == rec.id { refreshDetail() }   // 正在看这条→刷新详情（名册/摘要）；其它条靠 identifyingIds/列表变更自动重绘
            }
        }
    }

    // MARK: 录音改名 / 删除

    func openRenameRec(_ id: String) { if let r = recordings.first(where: { $0.id == id }) { renameRec = .init(id: id, value: r.title) } }
    func saveRenameRec() {
        guard let st = renameRec, let r = recordings.first(where: { $0.id == st.id }) else { return }
        let keep = selectedId
        try? renameRecording(r, to: st.value)
        renameRec = nil
        reload(reselect: keep)
        app?.toast("已重命名")
    }
    func confirmDeleteRec() {
        guard let id = deleteRecId, let r = recordings.first(where: { $0.id == id }) else { return }
        stopPlayer()
        try? deleteRecording(r)
        try? Index(path: defaultIndexPath(), dim: dim()).deleteRecording(id: id)
        deleteRecId = nil
        if selectedId == id { selectedId = nil }
        reload()
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
        // 记住声音默认开：无论是命名匿名者，还是**重分配误识别的人**（如把误判的 GGBond 改成 Ben），
        // 都希望「下次自动认出」。重分配只会注册/更新**新名字**的声纹，绝不动原来那个人（GGBond）的声纹
        // （见 renameSpeakerInRecording：enroll 仅 upsert newName 的 ref）。纯改错别字时用户可手动取消勾选。
        // 预填：匿名者留空让用户输入；已命名者预填原名，便于改成正确的人。
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
                autoPushVault("speaker: 命名 \(name)")
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
        // 用户本次显式选择的模板优先于「已有摘要用的模板」——否则刚选了 1-on-1、
        // 重新生成时下拉/loading 仍显示旧摘要的模板名（通用），看着像选错了。
        if let id = chosenTemplateId { return id }
        if let id = summaryTemplateId { return id }
        let tpls = SummaryTemplateStore.load()
        // 回退到「设为默认」的模板（Templates 页设置，存 UserDefaults），否则第一个
        if let def = UserDefaults.standard.string(forKey: "resound.defaultTemplate"),
           tpls.contains(where: { $0.id == def }) { return def }
        return tpls.first?.id ?? "t_general"
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
        summarizingIds.insert(rec.id); tplMenuOpen = false
        Task {
            defer { summarizingIds.remove(rec.id) }
            do {
                let cfg = try Config.load()
                let pipeline = IndexPipeline(config: cfg)
                _ = try await pipeline.summarizeRecording(recDir: rec.dir, indexPath: defaultIndexPath(), templateId: tplId)
                if selectedId == rec.id {   // 用户没切走才更新当前详情；切走了 summary.md 已落盘，回来会重新加载
                    summaryText = (try? String(contentsOf: rec.dir.appendingPathComponent("summary.md"), encoding: .utf8))
                    summaryTemplateId = tplId
                }
                let name = SummaryTemplateStore.load().first { $0.id == tplId }?.name ?? "默认"
                app?.toast("已用「\(name)」模板生成摘要")
                autoPushVault("summary: \(rec.title)")
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

    /// 导入：立即入列 + 关闭弹窗，转写/索引/摘要全部放后台异步进行（适合批量迁移，不再卡等）。
    func startImport() {
        guard !importItems.isEmpty, vaultURL() != nil else { return }
        let queued = importItems.map { ImportItem(url: $0.url, name: $0.name, status: .transcribing) }
        importItems = []; importOpen = false; importing = false
        pendingImports.append(contentsOf: queued)
        app?.toast("已加入 \(queued.count) 个文件，正在后台转写…")
        Task {
            for p in queued { await ingestOne(p) }
            let failed = pendingImports.filter { $0.status == .failed }.count
            app?.toast(failed == 0 ? "导入转写完成" : "导入完成，\(failed) 个失败（点失败项可重试）")
        }
    }

    /// 单个文件的转写→入库→后台识别。失败：把原因写进该项（UI 显示/重试用）+ 落盘日志，**不丢占位**。
    /// 既给 `startImport` 批量调用，也给 `retryImport`、录音兜底（`recordFailedRecording`）复用。
    private func ingestOne(_ p: ImportItem) async {
        guard let vault = vaultURL() else {
            setPendingStatus(p.id, .failed)
            setPendingError(p.id, "未设置录音库路径（去 设置 配置 vault 后重试）")
            return
        }
        let cfg = try? Config.load()
        setPendingStatus(p.id, .transcribing); setPendingError(p.id, nil)
        do {
            let out = try await IngestPipeline(vaultRoot: vault)
                .ingest(audioPath: p.url, title: nil, source: p.source, tags: [],
                        model: "large-v3", language: "zh", hints: [], push: false)
            if let cfg {
                // labelSpeakers:false——随后的 diarization worker 会重算并覆盖 chunk 说话人，
                // 这里再标注是纯浪费的整段解码+提声纹。
                try await IndexPipeline(config: cfg).indexRecording(
                    recDir: out.recordingDir, indexPath: defaultIndexPath(), labelSpeakers: false)
            }
            // 转录+入库完成即露出录音：可读/可搜/可问答。说话人识别(慢，占导入 ~80%)+摘要后台串行补，
            // 期间该条显示「识别说话人中…」。摘要放识别之后→摘要自带真名。
            autoPushVault("rec: 导入 \(p.name)")
            // 录音兜底（meeting）抢救出的临时音频，成功入库后清掉，避免 App Support 堆垃圾。
            if p.source == "meeting" { try? FileManager.default.removeItem(at: p.url) }
            pendingImports.removeAll { $0.id == p.id }   // 真录音已生成，移除占位
            // 增量插入这一条（免每个文件都全量扫盘 reload；文件夹/声纹库导入时不变，无需重扫）。
            if let sum = loadRecordingSummary(dir: out.recordingDir) {
                insertRecording(sum)
                enqueueSpeakerID(sum)
            }
        } catch {
            AppLog.error("导入转写失败「\(p.name)」(\(p.url.path))", error)
            setPendingStatus(p.id, .failed)
            setPendingError(p.id, String(describing: error))
        }
    }

    /// 重试一个失败项（原地重跑同一文件）。
    func retryImport(_ id: UUID) {
        guard let p = pendingImports.first(where: { $0.id == id }), p.status == .failed else { return }
        guard FileManager.default.fileExists(atPath: p.url.path) else {
            app?.toast("源音频已不在原位置，无法重试：\(p.url.lastPathComponent)"); return
        }
        app?.toast("重新转写「\(p.name)」…")
        Task { await ingestOne(p) }
    }

    /// 在 Finder 中显示该项音频（失败时取回/另存原始录音）。
    func revealImport(_ id: UUID) {
        guard let p = pendingImports.first(where: { $0.id == id }) else { return }
        guard FileManager.default.fileExists(atPath: p.url.path) else {
            app?.toast("音频文件已不在：\(p.url.path)"); return
        }
        NSWorkspace.shared.activateFileViewerSelecting([p.url])
    }

    /// 录音（Meet）转写失败兜底：把抢救出的音频登记成一个失败占位，复用导入失败行的「重试 / 在 Finder 中显示」。
    /// 这样录好的会议即使转写翻车也**不会丢音频**，且能一键重试或取回。
    func recordFailedRecording(url: URL, title: String?, error: String) {
        let safe = Self.preserveFailedAudio(url)   // 临时混音 → App Support，免被系统清掉
        let name = (title?.isEmpty == false ? title! : safe.deletingPathExtension().lastPathComponent)
        var item = ImportItem(url: safe, name: name, status: .failed)
        item.error = error; item.source = "meeting"
        pendingImports.append(item)
        AppLog.log("⚠️ 录音转写失败，音频已抢救到：\(safe.path)")
    }

    /// 把临时目录里的录音搬到 App Support/Resound/failed-recordings/（系统不会清），返回新位置。
    /// 搬动失败则退回原 url（至少暂时还在临时目录）。
    private nonisolated static func preserveFailedAudio(_ src: URL) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Resound/failed-recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let dest = base.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(src.lastPathComponent)")
        do { try FileManager.default.moveItem(at: src, to: dest); return dest }
        catch { return src }
    }

    private func setPendingStatus(_ id: UUID, _ s: ImportItem.Status) {
        if let i = pendingImports.firstIndex(where: { $0.id == id }) { pendingImports[i].status = s }
    }
    private func setPendingError(_ id: UUID, _ msg: String?) {
        if let i = pendingImports.firstIndex(where: { $0.id == id }) { pendingImports[i].error = msg }
    }
    func dismissPending(_ id: UUID) { pendingImports.removeAll { $0.id == id } }

    // MARK: 播放器

    /// 懒解码：首次播放/跳转时才在后台解码音频（避免点开录音时同步解码长音频卡顿），
    /// 解码期间 `decodingAudio=true`（播放键转圈），完成后回主线程执行 `then` 真正播放。
    private func withPlayer(_ then: @escaping (AVAudioPlayer) -> Void) {
        if let p = player { then(p); return }
        guard let rec = selected, !decodingAudio else { return }
        decodingAudio = true
        let token = detailToken
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let p = try? AVAudioPlayer(contentsOf: rec.audioURL)
            p?.prepareToPlay()
            await MainActor.run {
                self.decodingAudio = false
                guard self.detailToken == token, let p else { return }   // 切走了就别播
                self.player = p
                if p.duration > 0 { self.duration = p.duration }
                then(p)
            }
        }
    }

    func togglePlay() {
        clearSample()
        if let p = player, p.isPlaying { p.pause(); isPlaying = false; stopTimer(); return }
        withPlayer { p in
            if self.currentTime >= self.duration { p.currentTime = 0; self.currentTime = 0 }
            p.play(); self.isPlaying = true; self.startTimer()
        }
    }
    func seek(to time: Double) {
        clearSample()
        withPlayer { p in
            p.currentTime = max(0, min(time, p.duration)); self.currentTime = p.currentTime
            if !p.isPlaying { p.play(); self.isPlaying = true; self.startTimer() }
        }
    }

    /// 试听某说话人最长的一段（用于标注前快速辨认）。
    func playSpeakerSample(_ label: String) {
        if let p = player, samplingSpeaker == label, p.isPlaying {
            p.pause(); isPlaying = false; clearSample(); stopTimer(); return
        }
        let segs = diarSpans.filter { $0.speaker == label }
        guard let best = segs.max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) else { return }
        withPlayer { p in
            self.samplingSpeaker = label
            self.stopAt = min(best.end, p.duration)
            p.currentTime = max(0, min(best.start, p.duration)); self.currentTime = p.currentTime
            p.play(); self.isPlaying = true; self.startTimer()
        }
    }
    private func clearSample() { stopAt = nil; samplingSpeaker = nil }

    func scrubBegan() { clearSample(); scrubbing = true }
    func scrub(to time: Double) { if scrubbing { currentTime = max(0, min(time, duration)); syncActiveLine(currentTime) } }
    func scrubEnded(to time: Double) {
        scrubbing = false
        player?.currentTime = max(0, min(time, duration)); currentTime = player?.currentTime ?? time
        syncActiveLine(currentTime)
    }
    func stopPlayer() { clearSample(); player?.stop(); player = nil; isPlaying = false; stopTimer() }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, !self.scrubbing else { return }
                self.currentTime = p.currentTime            // 走 playhead，只刷新播放条，不重算转录
                self.syncActiveLine(p.currentTime)          // 仅跨行时才发布 → 转录列表很少重绘
                if let stop = self.stopAt, p.currentTime >= stop {   // 试听片段到点自动停
                    p.pause(); self.isPlaying = false; self.clearSample(); self.stopTimer(); return
                }
                if !p.isPlaying { self.isPlaying = false; self.stopTimer() }
            }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }

    /// 当前时间所在的转录行（二分：start<=t 的最后一行，命中 [start,end) 才算 active，与旧逐行高亮一致）。
    private func lineID(at t: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        var lo = 0, hi = lines.count - 1, idx = -1
        while lo <= hi { let m = (lo + hi) / 2; if lines[m].start <= t { idx = m; lo = m + 1 } else { hi = m - 1 } }
        guard idx >= 0 else { return nil }
        return t < lines[idx].end ? lines[idx].id : nil
    }
    private func syncActiveLine(_ t: Double) {
        let id = lineID(at: t)
        if id != activeLineID { activeLineID = id }
    }
}
