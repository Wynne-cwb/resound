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
    weak var app: AppModel?

    private var reveal: Timer?

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        input = ""
        busy = true
        msgs.append(Msg(isUser: true, full: q))
        var a = Msg(isUser: false); a.phase = .searching
        msgs.append(a)
        let aid = a.id

        Task {
            defer { busy = false }
            do {
                let cfg = try Config.load()
                let titles = Dictionary(uniqueKeysWithValues: listRecordings(vaultRoot: URL(fileURLWithPath: cfg.vaultPath ?? "")).map { ($0.id, $0.title) })
                setPhase(aid, .thinking)
                let r = try await IndexPipeline(config: cfg).answer(question: q, indexPath: defaultIndexPath(), topK: 8)
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
    @Environment(\.palette) var pal
    @StateObject private var vm = ChatVM()
    @FocusState private var focused: Bool

    var body: some View {
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
        .onAppear { vm.app = app }
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
                    case .answering, .done:
                        Text(String(m.full.prefix(m.revealed)) + (m.phase == .answering ? "▍" : ""))
                            .font(.system(size: 14)).foregroundStyle(pal.text).lineSpacing(4)
                            .textSelection(.enabled)
                        if m.phase == .done {
                            if m.isDigest, !m.sources.isEmpty { sourcesView(m.sources) }
                            else if !m.cites.isEmpty { citesView(m.cites) }
                        }
                    }
                }
                Spacer(minLength: 40)
            }
        }
    }

    private func citesView(_ cites: [ChatVM.Cite]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("来源 · \(cites.count)").font(.system(size: 11, weight: .semibold)).tracking(0.7).foregroundStyle(pal.text3)
            ForEach(cites) { c in
                Button { library.openCitation(recId: c.recId, time: c.t); app.page = .library } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(c.speaker).font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.accent)
                            Text("·").foregroundStyle(pal.text3)
                            Text(c.meeting).font(.system(size: 12)).foregroundStyle(pal.text2).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(c.time).font(.system(size: 11, design: .monospaced)).foregroundStyle(pal.text3)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(pal.inset, in: RoundedRectangle(cornerRadius: 5))
                        }
                        Text("“\(c.snippet)”").font(.system(size: 13)).italic().foregroundStyle(pal.text).lineSpacing(2).lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13).padding(.vertical, 11)
                    .card(pal, corner: 11)
                }
                .buttonStyle(.plainHit).hoverCursor()
            }
        }
        .padding(.top, 16)
    }

    private func sourcesView(_ sources: [ChatVM.Source]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("来源 · \(sources.count) 场会议").font(.system(size: 11, weight: .semibold)).tracking(0.7).foregroundStyle(pal.text3)
            ForEach(sources) { s in
                Button { library.openCitation(recId: s.recId, time: 0); app.page = .library } label: {
                    HStack(spacing: 11) {
                        ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(pal.accentSoft)
                            WaveMark(pal: pal, height: 12) }.frame(width: 30, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1)
                            Text(s.date).font(.system(size: 11.5)).foregroundStyle(pal.text2)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text3)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 11)
                    .card(pal, corner: 11)
                }
                .buttonStyle(.plainHit).hoverCursor()
            }
        }
        .padding(.top, 16)
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
}
