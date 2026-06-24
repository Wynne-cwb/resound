import SwiftUI
import ResoundCore

/// 问答页：查询规划（时间）→ 检索/汇总 → 综合，答案带时间范围 + 可点来源。= CLI 的 ask。
@MainActor
final class ChatVM: ObservableObject {
    struct Cite: Identifiable { let id = UUID(); let speaker: String; let meeting: String; let time: String; let snippet: String; let recId: String; let t: Double }
    struct Source: Identifiable { let id = UUID(); let title: String; let date: String; let recId: String }
    struct Msg: Identifiable {
        enum Phase { case searching, thinking, answering, done, empty, emptyTime }
        let id = UUID()
        let isUser: Bool
        var full = ""
        var revealed = 0
        var phase: Phase = .done
        var timeRange: String?
        var isDigest = false
        var cites: [Cite] = []
        var sources: [Source] = []
    }

    @Published var msgs: [Msg] = []
    @Published var input = ""
    @Published var busy = false
    @Published var conversations: [Conversation] = []
    @Published var currentId: UUID?
    @Published var renameSession: RenameSessionState?
    @Published var confirmDeleteSessionId: UUID?
    weak var app: AppModel?

    struct RenameSessionState { var id: UUID; var value: String }

    private var reveal: Timer?
    private let store = ChatStore()

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        let history = currentHistory()   // 取当前问题之前的对话作上下文
        input = ""
        busy = true
        msgs.append(Msg(isUser: true, full: q))
        var a = Msg(isUser: false); a.phase = .searching
        msgs.append(a)
        let aid = a.id
        saveCurrent()   // 先存一份（含用户提问），即便回答失败也留痕

        Task {
            defer { busy = false; saveCurrent() }
            do {
                let cfg = try Config.load()
                let titles = Dictionary(uniqueKeysWithValues: listRecordings(vaultRoot: URL(fileURLWithPath: cfg.vaultPath ?? "")).map { ($0.id, $0.title) })
                setPhase(aid, .thinking)
                let r = try await IndexPipeline(config: cfg).answer(question: q, indexPath: defaultIndexPath(), topK: 8, history: history)
                let range = Self.fmtRange(r.plan.dateFrom, r.plan.dateTo)

                if !r.digestRecordings.isEmpty {
                    let sources = r.digestRecordings.map { Source(title: $0.title, date: Self.monthDay(String($0.recordedAt.prefix(10))), recId: $0.id) }
                    patch(aid) { $0.full = r.text; $0.isDigest = true; $0.timeRange = range; $0.sources = sources }
                    startReveal(aid)
                } else if r.hits.isEmpty {
                    patch(aid) { $0.phase = (r.plan.dateRange != nil) ? .emptyTime : .empty; $0.timeRange = range }
                } else {
                    let cites = r.hits.prefix(6).map { h in
                        Cite(speaker: h.personId ?? "未知", meeting: titles[h.recordingId] ?? h.recordingId,
                             time: mmss(h.start), snippet: h.text, recId: h.recordingId, t: h.start)
                    }
                    patch(aid) { $0.full = r.text; $0.timeRange = range; $0.cites = Array(cites) }
                    startReveal(aid)
                }
            } catch {
                patch(aid) { $0.full = "出错：\(error)"; $0.phase = .done; $0.revealed = 9999 }
            }
        }
    }

    // MARK: 对话历史（持久化 + 列表 + 多轮上下文）

    /// 把当前已完成的对话转成喂给 LLM 的上下文（取最近 8 条）。
    private func currentHistory() -> [ChatTurn] {
        msgs.suffix(8).compactMap { m in
            switch m.phase {
            case .searching, .thinking: return nil
            case .empty, .emptyTime: return m.isUser ? ChatTurn(isUser: true, text: m.full) : ChatTurn(isUser: false, text: "（无相关内容）")
            default: return m.full.isEmpty ? nil : ChatTurn(isUser: m.isUser, text: m.full)
            }
        }
    }

    func loadHistory() { conversations = store.load() }

    func newChat() {
        reveal?.invalidate()
        msgs = []; currentId = nil; input = ""
    }

    func open(_ conv: Conversation) {
        guard !busy, conv.id != currentId else { return }
        reveal?.invalidate()
        currentId = conv.id
        msgs = conv.messages.map { sm in
            var m = Msg(isUser: sm.isUser, full: sm.text)
            m.revealed = sm.text.count   // 历史消息直接全显，不做打字机
            m.phase = .done
            m.timeRange = sm.timeRange
            m.isDigest = sm.isDigest
            m.cites = sm.cites.map { Cite(speaker: $0.speaker, meeting: $0.meeting, time: $0.time, snippet: $0.snippet, recId: $0.recId, t: $0.t) }
            m.sources = sm.sources.map { Source(title: $0.title, date: $0.date, recId: $0.recId) }
            return m
        }
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        store.save(conversations)
        if currentId == id { newChat() }
    }

    func openRenameSession(_ id: UUID) {
        renameSession = RenameSessionState(id: id, value: conversations.first { $0.id == id }?.title ?? "")
    }
    func saveRenameSession() {
        guard let r = renameSession else { return }
        let name = r.value.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, let i = conversations.firstIndex(where: { $0.id == r.id }) {
            conversations[i].title = name
            conversations[i].customTitle = true
            store.save(conversations)
        }
        renameSession = nil
    }
    func confirmDeleteSession() {
        if let id = confirmDeleteSessionId { deleteConversation(id) }
        confirmDeleteSessionId = nil
    }

    /// 把当前 msgs 落盘成一条对话（按 currentId 更新或新建），并刷新列表。
    private func saveCurrent() {
        let stored = msgs.compactMap { storedMsg(from: $0) }
        guard !stored.isEmpty else { return }
        let now = Date()
        let title = Self.titleFrom(msgs.first { $0.isUser }?.full ?? "新对话")
        let id = currentId ?? UUID()
        currentId = id
        var conv: Conversation
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conv = conversations[idx]
            conv.messages = stored; conv.updatedAt = now
            if conv.customTitle != true { conv.title = title }   // 重命名过的不被自动覆盖
            conversations.remove(at: idx)
        } else {
            conv = Conversation(id: id, title: title, createdAt: now, updatedAt: now, messages: stored, customTitle: false)
        }
        conversations.insert(conv, at: 0)   // 最近的排最前
        store.save(conversations)
    }

    private func storedMsg(from m: Msg) -> StoredMsg? {
        let text: String
        switch m.phase {
        case .searching, .thinking: return nil   // 进行中不存
        case .empty: text = "（未找到相关片段）"
        case .emptyTime: text = "（这段时间没有录音）"
        default: text = m.full
        }
        guard m.isUser || !text.isEmpty else { return nil }
        return StoredMsg(isUser: m.isUser, text: text, timeRange: m.timeRange, isDigest: m.isDigest,
                         cites: m.cites.map { StoredCite(speaker: $0.speaker, meeting: $0.meeting, time: $0.time, snippet: $0.snippet, recId: $0.recId, t: $0.t) },
                         sources: m.sources.map { StoredSource(title: $0.title, date: $0.date, recId: $0.recId) })
    }

    private static func titleFrom(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return one.count > 30 ? String(one.prefix(30)) + "…" : (one.isEmpty ? "新对话" : one)
    }

    private func startReveal(_ id: UUID) {
        setPhase(id, .answering)
        reveal?.invalidate()
        reveal = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, let i = self.msgs.firstIndex(where: { $0.id == id }) else { t.invalidate(); return }
                if self.msgs[i].revealed >= self.msgs[i].full.count { t.invalidate(); self.msgs[i].phase = .done; return }
                self.msgs[i].revealed = min(self.msgs[i].full.count, self.msgs[i].revealed + 3)
            }
        }
    }

    private func setPhase(_ id: UUID, _ p: Msg.Phase) { patch(id) { $0.phase = p } }
    private func patch(_ id: UUID, _ f: (inout Msg) -> Void) { if let i = msgs.firstIndex(where: { $0.id == id }) { f(&msgs[i]) } }

    static func monthDay(_ ymd: String) -> String {
        let p = ymd.split(separator: "-")
        guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return ymd }
        return "\(m)月\(d)日"
    }
    static func fmtRange(_ from: String?, _ to: String?) -> String? {
        guard let from else { return nil }
        if let to, to != from { return "\(monthDay(from)) – \(monthDay(to))" }
        return monthDay(from)
    }
}

struct ChatView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var vm: ChatVM
    @Environment(\.palette) var pal
    @FocusState private var focused: Bool
    @State private var hoverConvId: UUID?
    @State private var expandedCites: Set<UUID> = []   // 引用默认折叠，点「来源」展开

    var body: some View {
        HStack(spacing: 0) {
            historyColumn
            Rectangle().fill(pal.border).frame(width: 1)
            chatArea
        }
        .onAppear { vm.app = app; vm.loadHistory() }
    }

    private var chatArea: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if vm.msgs.isEmpty { emptyState }
                    else {
                        VStack(spacing: 26) {
                            ForEach(vm.msgs) { msg in messageRow(msg).id(msg.id) }
                        }
                        .frame(maxWidth: 720)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 20)
                    }
                }
                .onChange(of: vm.msgs.count) { _, _ in if let l = vm.msgs.last { withAnimation { proxy.scrollTo(l.id, anchor: .bottom) } } }
            }
            inputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.bg)
    }

    // MARK: 对话历史列

    private var historyColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("对话").font(.system(size: 17, weight: .bold)).foregroundStyle(pal.text)
                Spacer()
                Button { vm.newChat() } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(pal.text).frame(width: 30, height: 30).card(pal, corner: 8)
                }.buttonStyle(.plainHit).hoverCursor().help("新对话")
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(vm.conversations) { c in conversationRow(c) }
                    if vm.conversations.isEmpty {
                        VStack(spacing: 11) {
                            Image(systemName: "bubble.left").font(.system(size: 24, weight: .light)).foregroundStyle(pal.text3)
                            Text("还没有任何对话。\n提个问题，这里就会留下记录。")
                                .font(.system(size: 12.5)).foregroundStyle(pal.text2).multilineTextAlignment(.center).lineSpacing(3)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
        }
        .frame(width: 236)
        .background(pal.sidebar)
    }

    private func conversationRow(_ c: Conversation) -> some View {
        let on = vm.currentId == c.id
        return Button { vm.open(c) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(c.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(relTime(c.updatedAt)).font(.system(size: 10.5)).foregroundStyle(pal.text3).fixedSize()
                }
                Text(c.preview).font(.system(size: 11.5)).foregroundStyle(pal.text2).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11).padding(.vertical, 10)
            .background(on ? pal.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .stroke(on ? pal.accent : .clear, corner: 9)
            .overlay(alignment: .topTrailing) {
                if hoverConvId == c.id {
                    HStack(spacing: 2) {
                        convAction("pencil") { vm.openRenameSession(c.id) }
                        convAction("trash", danger: true) { vm.confirmDeleteSessionId = c.id }
                    }
                    .padding(6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit).hoverCursor()
        .onHover { hoverConvId = $0 ? c.id : (hoverConvId == c.id ? nil : hoverConvId) }
    }

    private func convAction(_ name: String, danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        RowIconButton(pal: pal, icon: name, danger: danger, action: action)
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: 0) {
            BrandIcon(pal: pal, size: 76).padding(.bottom, 18)
            Text("向你的所有会议提问").font(.system(size: 25, weight: .bold)).foregroundStyle(pal.text)
            Text("Resound 会检索你录下的所有内容，用平实的语言回答你——并附上谁在什么时候说了什么的原文引用。")
                .font(.system(size: 14.5)).foregroundStyle(pal.text2).multilineTextAlignment(.center)
                .lineSpacing(3).frame(maxWidth: 460).padding(.top, 11)
        }
        .frame(maxWidth: 680).frame(maxWidth: .infinity)
        .padding(.horizontal, 32).padding(.top, 90).padding(.bottom, 40)
    }

    // MARK: 消息

    @ViewBuilder private func messageRow(_ m: ChatVM.Msg) -> some View {
        if m.isUser {
            HStack { Spacer(minLength: 50)
                Text(m.full).font(.system(size: 14)).foregroundStyle(.white).lineSpacing(2)
                    .padding(.vertical, 11).padding(.horizontal, 15)
                    .background(pal.accent, in: UnevenRoundedRectangle(topLeadingRadius: 15, bottomLeadingRadius: 15, bottomTrailingRadius: 4, topTrailingRadius: 15, style: .continuous))
                    .frame(maxWidth: 540, alignment: .trailing)
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(pal.accentSoft)
                    WaveMark(pal: pal, height: 11) }.frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 0) {
                    if let tr = m.timeRange, m.phase != .searching, m.phase != .thinking {
                        HStack(spacing: 6) {
                            Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                            Text("时间范围 · \(tr)").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(pal.accent).padding(.horizontal, 11).padding(.vertical, 4)
                        .background(pal.accentSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.bottom, 11)
                    }
                    switch m.phase {
                    case .searching, .thinking:
                        HStack(spacing: 9) { Spinner(size: 15, color: pal.text2)
                            Text(m.phase == .searching ? "正在检索你的录音…" : "正在阅读相关片段…")
                                .font(.system(size: 13.5)).foregroundStyle(pal.text2) }.frame(height: 24)
                    case .empty:
                        Text("在你的录音里没有找到匹配的片段。试试换个更宽泛的说法，或者把相关的会议录下来。")
                            .font(.system(size: 13)).foregroundStyle(pal.text2).lineSpacing(3)
                            .padding(.horizontal, 15).padding(.vertical, 13)
                            .background(pal.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(pal.borderStrong))
                    case .emptyTime:
                        Text("这段时间没有录音。换一个时间范围，或先把会议录下来 —— 转写后它就能在这里被汇总。")
                            .font(.system(size: 13)).foregroundStyle(pal.text2).lineSpacing(3)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(pal.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(pal.borderStrong))
                    case .answering:
                        // 打字机阶段：纯文本 + 光标（逐字渲染 Markdown 会因半截语法闪烁）
                        Text(String(m.full.prefix(m.revealed)) + "▍")
                            .font(.system(size: 14)).foregroundStyle(pal.text).lineSpacing(4)
                            .textSelection(.enabled)
                    case .done:
                        // 完成后整段走 Markdown 富文本（与 Library 摘要一致）
                        SummaryMarkdown(text: m.full, pal: pal)
                        if m.isDigest, !m.sources.isEmpty { sourcesView(m.sources, id: m.id) }
                        else if !m.cites.isEmpty { citesView(m.cites, id: m.id) }
                    }
                }
                Spacer(minLength: 40)
            }
        }
    }

    /// 折叠/展开来源的标题行。
    private func citeHeader(_ label: String, id: UUID) -> some View {
        let expanded = expandedCites.contains(id)
        return Button {
            withAnimation(.easeOut(duration: 0.14)) {
                if expanded { expandedCites.remove(id) } else { expandedCites.insert(id) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(pal.text3).rotationEffect(.degrees(expanded ? 90 : 0))
                Text(label).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(pal.text3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit).hoverCursor()
    }

    private func citesView(_ cites: [ChatVM.Cite], id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            citeHeader("来源 · \(cites.count)", id: id)
            if expandedCites.contains(id) {
            ForEach(cites) { c in
                Button { library.openCitation(recId: c.recId, time: c.t); app.page = .library } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(c.speaker).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(pal.accent)
                            Text("·").foregroundStyle(pal.text3)
                            Text(c.meeting).font(.system(size: 11.5)).foregroundStyle(pal.text2).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(c.time).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(pal.text3)
                        }
                        Text("“\(c.snippet)”").font(.system(size: 12)).italic().foregroundStyle(pal.text2).lineSpacing(1).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .card(pal, corner: 9)
                }
                .buttonStyle(.plainHit).hoverCursor()
            }
            }
        }
        .padding(.top, 12)
    }

    private func sourcesView(_ sources: [ChatVM.Source], id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            citeHeader("来源 · \(sources.count) 场会议", id: id)
            if expandedCites.contains(id) {
            ForEach(sources) { s in
                Button { library.openCitation(recId: s.recId, time: 0); app.page = .library } label: {
                    HStack(spacing: 9) {
                        ZStack { RoundedRectangle(cornerRadius: 7, style: .continuous).fill(pal.accentSoft)
                            WaveMark(pal: pal, height: 10) }.frame(width: 24, height: 24)
                        Text(s.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1)
                        Text(s.date).font(.system(size: 11)).foregroundStyle(pal.text3).fixedSize()
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.text3)
                    }
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .card(pal, corner: 9)
                }
                .buttonStyle(.plainHit).hoverCursor()
            }
            }
        }
        .padding(.top, 12)
    }

    // MARK: 输入

    private var inputBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                TextField("在所有会议中提问…", text: $vm.input)
                    .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(pal.text)
                    .focused($focused).onSubmit { vm.ask(vm.input) }
                    .frame(height: 36)
                Button { vm.ask(vm.input) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(canSend ? .white : pal.text3)
                        .frame(width: 36, height: 36)
                        .background(canSend ? pal.accent : pal.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plainHit).hoverCursor().disabled(!canSend)
            }
            .padding(.leading, 16).padding(.trailing, 7).padding(.vertical, 7)
            .background(pal.elev, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .stroke(pal.borderStrong, corner: 14)
            .frame(maxWidth: 720)
            Text("回答由本地模型基于你的录音生成。Resound 可能出错——请核对来源。")
                .font(.system(size: 11)).foregroundStyle(pal.text3)
        }
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 20)
    }

    private var canSend: Bool { !vm.busy && !vm.input.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 对话列表的相对时间：今天 HH:mm / 昨天 / M月d日。
    private func relTime(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
        }
        if cal.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter(); f.dateFormat = "M月d日"; f.locale = Locale(identifier: "zh_CN"); return f.string(from: d)
    }
}
