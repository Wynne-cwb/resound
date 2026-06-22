import SwiftUI
import MarkdownUI
import ResoundCore

struct LibraryView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var vm: LibraryModel
    @EnvironmentObject var rec: RecordingController
    @Environment(\.palette) var pal
    @State private var hoverId: String?

    var body: some View {
        HStack(spacing: 0) {
            listColumn
            Rectangle().fill(pal.border).frame(width: 1)
            detail
        }
        .onAppear { vm.load() }
        .onChange(of: app.libraryReloadToken) { _, _ in vm.load() }
        .background {
            Button("") { vm.openFind() }.keyboardShortcut("f", modifiers: .command).hidden()
        }
    }

    // MARK: 列表

    private var listColumn: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("录音库").font(.system(size: 17, weight: .bold)).foregroundStyle(pal.text)
                    Spacer()
                    Button { vm.openNewFolder() } label: {
                        Image(systemName: "folder.badge.plus").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(pal.text).frame(width: 30, height: 30).card(pal, corner: 8)
                    }.buttonStyle(.plainHit).hoverCursor().help("新建文件夹")
                    Button { vm.openImport() } label: {
                        Image(systemName: "square.and.arrow.down").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(pal.text).frame(width: 30, height: 30).card(pal, corner: 8)
                    }.buttonStyle(.plainHit).hoverCursor().help("导入录音文件")
                }
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(pal.text3)
                    TextField("搜索录音…", text: $vm.query)
                        .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(pal.text)
                    if !vm.query.isEmpty {
                        Button { vm.query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(pal.text3) }.buttonStyle(.plainHit)
                    }
                }
                .padding(.horizontal, 10).frame(height: 30).card(pal, corner: 8, fill: pal.bg)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 2, pinnedViews: []) {
                    if rec.isProcessing { processingRow }
                    ForEach(vm.sections()) { sec in
                        folderHeader(sec)
                        if !vm.isCollapsed(sec.id) {
                            ForEach(sec.recordings) { r in recordingRow(r) }
                        }
                    }
                    if vm.sections().allSatisfy({ $0.recordings.isEmpty }) && !vm.query.isEmpty {
                        Text("没有匹配「\(vm.query)」的录音").font(.system(size: 12)).foregroundStyle(pal.text3).padding(.top, 20)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
        }
        .frame(width: 300)
        .background(pal.sidebar)
    }

    private func folderHeader(_ sec: LibraryModel.Section) -> some View {
        let collapsed = vm.isCollapsed(sec.id)
        return Button { vm.toggleCollapse(sec.id) } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(pal.text3)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Image(systemName: sec.folderId == nil ? "tray" : "folder.fill").font(.system(size: 11)).foregroundStyle(pal.text2)
                Text(sec.name).font(.system(size: 12, weight: .bold)).foregroundStyle(pal.text2).lineLimit(1)
                Spacer()
                Text("\(sec.recordings.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(pal.text3)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit).hoverCursor()
        .padding(.top, 6)
        .contextMenu {
            if let fid = sec.folderId {
                Button("重命名文件夹") { vm.openRenameFolder(fid) }
                Button("删除文件夹", role: .destructive) { vm.confirmDeleteFolderId = fid }
            }
        }
    }

    @ViewBuilder private func moveMenu(_ r: RecordingSummary) -> some View {
        Menu("移动到") {
            ForEach(vm.folders) { f in
                Button { vm.move(r.id, to: f.id) } label: {
                    if vm.assign[r.id] == f.id { Label(f.name, systemImage: "checkmark") } else { Text(f.name) }
                }
            }
            if !vm.folders.isEmpty { Divider() }
            Button("未分类") { vm.move(r.id, to: nil) }
            Divider()
            Button("新建文件夹…") { vm.openNewFolder() }
        }
    }

    private var processingRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("正在处理新录音").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                Text(RecordingController.procLabels[min(rec.procStep, 2)]).font(.system(size: 11.5)).foregroundStyle(pal.text2)
            }
            Spacer()
            Spinner(size: 13, color: pal.accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(pal.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.top, 4)
    }

    private func recordingRow(_ r: RecordingSummary) -> some View {
        let on = vm.selectedId == r.id
        let identified = FileManager.default.fileExists(atPath: r.dir.appendingPathComponent("diarization.json").path)
        return Button { vm.select(r.id) } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(r.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1)
                HStack(spacing: 8) {
                    Text(shortDate(r.recordedAt)).font(.system(size: 11.5)).foregroundStyle(pal.text2)
                    Text("·").font(.system(size: 11)).foregroundStyle(pal.text3)
                    Text(mmss(Double(r.durationSec))).font(.system(size: 11, design: .monospaced)).foregroundStyle(pal.text3)
                    if !identified {
                        Spacer(minLength: 4)
                        Text("待识别").font(.system(size: 10, weight: .semibold)).foregroundStyle(pal.warn)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(pal.warnSoft, in: Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 12)
            .background(on ? pal.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .stroke(on ? pal.accent : .clear, corner: 10)
            .overlay(alignment: .topTrailing) {
                if hoverId == r.id {
                    HStack(spacing: 2) {
                        iconBtn("pencil") { vm.openRenameRec(r.id) }
                        iconBtn("trash", danger: true) { vm.deleteRecId = r.id }
                    }
                    .padding(6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit).hoverCursor()
        .onHover { hoverId = $0 ? r.id : (hoverId == r.id ? nil : hoverId) }
        .contextMenu {
            moveMenu(r)
            Divider()
            Button("重命名") { vm.openRenameRec(r.id) }
            Button("删除", role: .destructive) { vm.deleteRecId = r.id }
        }
    }

    private func iconBtn(_ name: String, danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12, weight: .medium)).foregroundStyle(pal.text2)
                .frame(width: 26, height: 26)
                .background(pal.elev, in: RoundedRectangle(cornerRadius: 6))
                .stroke(pal.border, corner: 6)
        }
        .buttonStyle(.plainHit).hoverCursor()
    }

    // MARK: 详情

    @ViewBuilder private var detail: some View {
        if let sel = vm.selected {
            VStack(spacing: 0) {
                if vm.findOpen { findBar }
                detailScroll(sel)
            }
        } else {
            VStack(spacing: 14) {
                WaveMark(pal: pal, height: 40, color: pal.text3)
                Text(vm.loadError ?? "选择左侧一条录音").foregroundStyle(pal.text2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @FocusState private var findFocused: Bool

    private var findBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(pal.text3)
                TextField("在\(vm.findScopeLabel)中查找…", text: $vm.findQuery)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(pal.text).frame(width: 150).focused($findFocused)
                Text(vm.findQuery.isEmpty ? "" : "\(vm.findMatchCount)").font(.system(size: 11, design: .monospaced)).foregroundStyle(pal.text3)
            }
            .padding(.horizontal, 10).frame(height: 30).card(pal, corner: 8, fill: pal.bg)
            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(pal.text3)
            HStack(spacing: 7) {
                TextField("替换为…", text: $vm.replaceText)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(pal.text).frame(width: 150)
            }
            .padding(.horizontal, 10).frame(height: 30).card(pal, corner: 8, fill: pal.bg)
            Button { vm.replaceAll() } label: {
                Text("全部替换").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 30).background(pal.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }.buttonStyle(.plainHit).hoverCursor().disabled(vm.findMatchCount == 0)
            Spacer()
            Button { vm.closeFind() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text2).frame(width: 28, height: 28)
            }.buttonStyle(.plainHit).hoverCursor().keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 9)
        .background(pal.sidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(pal.border).frame(height: 1) }
        .onChange(of: vm.findOpen) { _, open in if open { findFocused = true } }
        .onAppear { findFocused = true }
    }

    private func detailScroll(_ sel: RecordingSummary) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(sel.title).font(.system(size: 22, weight: .bold)).foregroundStyle(pal.text)
                        .textSelection(.enabled)
                    Text("\(fullDate(sel.recordedAt)) · \(mmss(Double(sel.durationSec)))")
                        .font(.system(size: 13)).foregroundStyle(pal.text2).padding(.top, 5)
                        .textSelection(.enabled)
                    playerBar(sel).padding(.top, 22)
                    tabBar.padding(.top, 24)
                    if vm.tab == .summary { summaryTab } else { transcriptTab }
                }
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 40).padding(.top, 32).padding(.bottom, 60)
            }
            .onChange(of: vm.findQuery) { _, _ in
                if let id = vm.firstMatchLineID() { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }

    private func playerBar(_ sel: RecordingSummary) -> some View {
        HStack(spacing: 15) {
            Button { vm.togglePlay() } label: {
                Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 46, height: 46).background(pal.accent, in: Circle())
            }
            .buttonStyle(.plainHit).hoverCursor()
            VStack(spacing: 7) {
                Scrubber(value: vm.currentTime, total: max(vm.duration, 0.1), pal: pal,
                         onBegin: { vm.scrubBegan() }, onChange: { vm.scrub(to: $0) }, onEnd: { vm.scrubEnded(to: $0) })
                    .frame(height: 18)
                HStack {
                    Text(mmss(vm.currentTime)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(pal.text2)
                    Spacer()
                    Text(mmss(max(vm.duration, Double(sel.durationSec)))).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(pal.text2)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .card(pal)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tab("会议摘要", .summary); tab("逐句转录", .transcript)
        }
        .padding(3)
        .background(pal.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private func tab(_ label: String, _ t: LibraryModel.DetailTab) -> some View {
        let on = vm.tab == t
        return Button { withAnimation(.easeOut(duration: 0.12)) { vm.tab = t } } label: {
            Text(label).font(.system(size: 13, weight: .semibold)).foregroundStyle(on ? pal.text : pal.text2)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(on ? pal.elev : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plainHit).hoverCursor()
    }

    // MARK: 摘要 Tab

    @ViewBuilder private var summaryTab: some View {
        if vm.summarizing {
            VStack(spacing: 0) {
                Spinner(size: 30, color: pal.border)
                Text("正在生成会议摘要…").font(.system(size: 15, weight: .semibold)).foregroundStyle(pal.text).padding(.top, 16)
                Text("正在用「\(curTplName)」模板分析这场会议的转录文稿。").font(.system(size: 13)).foregroundStyle(pal.text2).padding(.top, 6)
            }
            .frame(maxWidth: .infinity).padding(36).card(pal).padding(.top, 18)
        } else if let text = vm.summaryText {
            HStack(spacing: 10) {
                Text("会议摘要").font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text).textSelection(.enabled)
                templateMenu
                Spacer()
                Button { vm.regenerate() } label: {
                    HStack(spacing: 6) { Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)); Text("重新生成").font(.system(size: 12, weight: .semibold)) }
                        .foregroundStyle(.white).padding(.horizontal, 13).frame(height: 30)
                        .background(pal.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plainHit).hoverCursor()
            }
            .padding(.top, 18)
            SummaryMarkdown(text: text, pal: pal, highlight: vm.findOpen ? vm.findQuery : "")
                .padding(22).frame(maxWidth: .infinity, alignment: .leading).card(pal).padding(.top, 14)
        } else {
            VStack(spacing: 0) {
                Image(systemName: "doc.text").font(.system(size: 32)).foregroundStyle(pal.text3)
                Text("还没有生成会议摘要").font(.system(size: 15, weight: .semibold)).foregroundStyle(pal.text).padding(.top, 14)
                Text("用一个模板，把这场会议浓缩成概述、要点、决议和行动项。")
                    .font(.system(size: 13)).foregroundStyle(pal.text2).multilineTextAlignment(.center).frame(maxWidth: 360).padding(.top, 6)
                HStack(spacing: 10) {
                    templateMenu
                    Button { vm.generateSummary() } label: {
                        HStack(spacing: 7) { Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)); Text("生成摘要").font(.system(size: 13, weight: .semibold)) }
                            .foregroundStyle(.white).padding(.horizontal, 16).frame(height: 34)
                            .background(pal.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plainHit).hoverCursor()
                }
                .padding(.top, 20)
            }
            .frame(maxWidth: .infinity).padding(34)
            .background(pal.inset, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(pal.borderStrong))
            .padding(.top, 18)
        }
    }

    private var curTplName: String {
        SummaryTemplateStore.load().first { $0.id == vm.currentTemplateId() }?.name ?? "默认"
    }

    private var templateMenu: some View {
        Menu {
            ForEach(SummaryTemplateStore.load()) { t in
                Button { vm.chooseTemplate(t.id) } label: {
                    if t.id == vm.currentTemplateId() { Label(t.name, systemImage: "checkmark") } else { Text(t.name) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.text2)
                Text("模板 · ").font(.system(size: 12)).foregroundStyle(pal.text2)
                + Text(curTplName).font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(pal.text2)
            }
            .padding(.horizontal, 11).frame(height: 30).card(pal, corner: 8)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().hoverCursor()
    }

    // MARK: 转录 Tab

    @ViewBuilder private var transcriptTab: some View {
        if !vm.hasSpeakers {
            HStack(spacing: 14) {
                Image(systemName: "person.crop.circle").font(.system(size: 20)).foregroundStyle(pal.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("尚未识别说话人").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                    Text("运行分析来区分谁说了什么。已认识的声音会被自动匹配。").font(.system(size: 12.5)).foregroundStyle(pal.text2)
                }
                Spacer()
                if vm.analyzing {
                    HStack(spacing: 8) { Spinner(size: 13, color: pal.warn); Text("分析中…").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.warn) }
                } else {
                    Button { vm.analyze() } label: {
                        Text("识别说话人").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 15).frame(height: 32)
                            .background(pal.warn, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plainHit).hoverCursor()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(pal.warnSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .stroke(pal.warnBorder, corner: 12)
            .padding(.top, 18)
        } else {
            speakerRoster.padding(.top, 18)
        }
        transcriptLines.padding(.top, 22)
    }

    private var speakerRoster: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("说话人 · \(vm.speakers.count) 位").font(.system(size: 13, weight: .bold)).foregroundStyle(pal.text)
                Spacer()
                if vm.analyzing {
                    HStack(spacing: 6) { Spinner(size: 12, color: pal.accent); Text("识别中…").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(pal.accent) }
                } else {
                    Button { vm.reidentify() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold))
                            Text("重新识别").font(.system(size: 11.5, weight: .semibold))
                        }
                        .foregroundStyle(pal.text2).padding(.horizontal, 9).frame(height: 26).card(pal, corner: 7, fill: pal.bg)
                    }
                    .buttonStyle(.plainHit).hoverCursor().help("重聚类并用已记住的声音合并重复说话人、自动套真名")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Rectangle().fill(pal.border).frame(height: 1)
            ForEach(vm.speakers) { sp in
                HStack(spacing: 12) {
                    rosterAvatar(sp)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Text(sp.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                            if sp.isKnown {
                                HStack(spacing: 4) { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)); Text("已记住 · 自动识别").font(.system(size: 10.5, weight: .semibold)) }
                                    .foregroundStyle(pal.ok).padding(.horizontal, 8).padding(.vertical, 2).background(pal.ok.opacity(0.12), in: Capsule())
                            } else if sp.isAnon {
                                Text("待命名").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(pal.warn)
                                    .padding(.horizontal, 8).padding(.vertical, 2).background(pal.warnSoft, in: Capsule())
                            }
                        }
                        Text("发言 \(sp.lineCount) 句 · 占比 \(sp.pct)%").font(.system(size: 11.5)).foregroundStyle(pal.text2)
                    }
                    Spacer()
                    if vm.namingInProgress == sp.label {
                        HStack(spacing: 7) {
                            Spinner(size: 13, color: pal.accent)
                            Text("保存中…").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.accent)
                        }
                        .frame(height: 30).padding(.horizontal, 4)
                    } else {
                        Button { vm.playSpeakerSample(sp.label) } label: {
                            Image(systemName: vm.samplingSpeaker == sp.label ? "pause.fill" : "play.fill")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.accent)
                                .frame(width: 30, height: 30)
                                .background(pal.accentSoft, in: Circle())
                        }
                        .buttonStyle(.plainHit).hoverCursor().help("试听 TA 的一段发言")
                        Button { vm.openRenameSpeaker(sp.label) } label: {
                            HStack(spacing: 6) { Image(systemName: "pencil").font(.system(size: 11, weight: .semibold)); Text(sp.isAnon ? "命名" : "改名").font(.system(size: 12.5, weight: .semibold)) }
                                .foregroundStyle(sp.isAnon ? .white : pal.text)
                                .padding(.horizontal, 13).frame(height: 30)
                                .background(sp.isAnon ? pal.accent : pal.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .stroke(sp.isAnon ? .clear : pal.borderStrong, corner: 8)
                        }
                        .buttonStyle(.plainHit).hoverCursor()
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                if sp.id != vm.speakers.last?.id { Rectangle().fill(pal.border).frame(height: 1) }
            }
        }
        .card(pal)
    }

    private func rosterAvatar(_ sp: LibraryModel.SpeakerStat) -> some View {
        let hues: [Color] = [pal.accent, Color(hex: 0x9b6dc9), Color(hex: 0x3f9d7a), Color(hex: 0xd98a3d), Color(hex: 0xc75d8a)]
        return ZStack {
            Circle().fill(sp.isAnon ? pal.inset : hues[sp.index % hues.count])
            Text(sp.isAnon ? "?" : String(sp.name.prefix(2)))
                .font(.system(size: 13, weight: .bold)).foregroundStyle(sp.isAnon ? pal.text3 : .white)
        }
        .frame(width: 36, height: 36)
        .overlay { if sp.isAnon { Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3])).foregroundStyle(pal.borderStrong) } }
    }

    private var transcriptLines: some View {
        LazyVStack(spacing: 1) {
            ForEach(vm.lines) { ln in
                let active = vm.currentTime >= ln.start && vm.currentTime < ln.end
                Button { vm.seek(to: ln.start) } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Text(mmss(ln.start)).font(.system(size: 11, design: .monospaced)).foregroundStyle(pal.text3).frame(width: 46, alignment: .leading).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 3) {
                            if vm.hasSpeakers, let spk = ln.speaker {
                                Button { vm.openRenameSpeaker(spk) } label: {
                                    HStack(spacing: 5) {
                                        Text(spk).font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.accent)
                                        Image(systemName: "pencil").font(.system(size: 9)).foregroundStyle(pal.accent.opacity(0.45))
                                    }
                                }
                                .buttonStyle(.plainHit).hoverCursor()
                            }
                            lineText(ln.text).font(.system(size: 14)).foregroundStyle(pal.text).lineSpacing(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 9)
                    .background(active ? pal.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(alignment: .leading) { if active { RoundedRectangle(cornerRadius: 3).fill(pal.accent).frame(width: 3).padding(.vertical, 6) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plainHit).hoverCursor()
                .id(ln.id)
            }
        }
    }

    /// 转录行文本：查找时高亮命中片段。
    private func lineText(_ s: String) -> Text {
        (vm.findOpen && !vm.findQuery.isEmpty) ? highlightedText(s, query: vm.findQuery, pal: pal) : Text(s)
    }
}

// MARK: - 进度条（自绘，支持拖拽）

struct Scrubber: View {
    var value: Double
    var total: Double
    var pal: Palette
    var onBegin: () -> Void
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let frac = total > 0 ? min(1, max(0, value / total)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(pal.borderStrong).frame(height: 5)
                Capsule().fill(pal.accent).frame(width: geo.size.width * frac, height: 5)
                Circle().fill(.white).frame(width: 13, height: 13)
                    .stroke(pal.borderStrong, corner: 7)
                    .offset(x: geo.size.width * frac - 6.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(WindowDragBlocker())   // 拖动进度条时不带着整个窗口跑
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in onBegin(); onChange(Double(g.location.x / geo.size.width) * total) }
                .onEnded { g in onEnd(Double(g.location.x / geo.size.width) * total) })
        }
    }
}

/// 放在交互控件背后：让 AppKit 不把这里的 mouseDown 当成「拖动窗口」(window.isMovableByWindowBackground)。
struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { BlockerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class BlockerView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
    }
}

// MARK: - 摘要 Markdown 渲染（MarkdownUI，GitHub 风：嵌套列表/表格/代码块齐全）

struct SummaryMarkdown: View {
    let text: String
    let pal: Palette
    var highlight: String = ""   // 保留签名兼容；行内查找高亮交给转录页，摘要走完整 Markdown

    init(text: String, pal: Palette, highlight: String = "") {
        self.text = text; self.pal = pal; self.highlight = highlight
    }

    var body: some View {
        Markdown(text)
            .markdownTheme(.resound(pal))
            .textSelection(.enabled)
    }
}

extension MarkdownUI.Theme {
    /// 贴合 Resound 调色板的 Markdown 主题：以 GitHub 主题为底（表格/列表/代码块渲染完备），
    /// 仅覆盖文字/标题/链接/代码的配色与字号。
    static func resound(_ pal: Palette) -> MarkdownUI.Theme {
        MarkdownUI.Theme.gitHub
            .text {
                ForegroundColor(pal.text)
                FontSize(13.5)
            }
            .strong { FontWeight(.semibold) }
            .emphasis { FontStyle(.italic) }
            .link { ForegroundColor(pal.accent) }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                ForegroundColor(pal.accent)
                BackgroundColor(pal.accentSoft)
            }
            .heading1 { c in c.label.markdownMargin(top: 16, bottom: 10)
                .markdownTextStyle { FontWeight(.bold); FontSize(.em(1.5)); ForegroundColor(pal.accent) } }
            .heading2 { c in c.label.markdownMargin(top: 16, bottom: 8)
                .markdownTextStyle { FontWeight(.bold); FontSize(.em(1.28)); ForegroundColor(pal.accent) } }
            .heading3 { c in c.label.markdownMargin(top: 14, bottom: 6)
                .markdownTextStyle { FontWeight(.bold); FontSize(.em(1.12)); ForegroundColor(pal.accent) } }
            .heading4 { c in c.label.markdownMargin(top: 12, bottom: 6)
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.0)); ForegroundColor(pal.accent) } }
            .paragraph { c in c.label.relativeLineSpacing(.em(0.28)).markdownMargin(top: 0, bottom: 10) }
            .listItem { c in c.label.markdownMargin(top: .em(0.2)) }
            .blockquote { c in
                HStack(spacing: 0) {
                    Rectangle().fill(pal.accent.opacity(0.5)).frame(width: 3)
                    c.label.padding(.leading, 12).markdownTextStyle { ForegroundColor(pal.text2) }
                }
            }
    }
}

/// 把 query 命中的片段加黄色高亮背景（查找时用）。
func highlightMatches(in input: AttributedString, query: String, pal: Palette) -> AttributedString {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return input }
    var attr = input
    let plain = String(input.characters)
    var search = plain.startIndex..<plain.endIndex
    while let r = plain.range(of: q, options: .caseInsensitive, range: search) {
        if let lo = AttributedString.Index(r.lowerBound, within: attr),
           let hi = AttributedString.Index(r.upperBound, within: attr) {
            attr[lo..<hi].backgroundColor = pal.warn.opacity(0.45)
            attr[lo..<hi].foregroundColor = pal.text
        }
        search = r.upperBound..<plain.endIndex
    }
    return attr
}

/// 高亮 query 命中的纯文本 → Text（转录行用）。
func highlightedText(_ s: String, query: String, pal: Palette) -> Text {
    Text(highlightMatches(in: AttributedString(s), query: query, pal: pal))
}

// MARK: - 日期格式

private func isoDate(_ iso: String) -> Date? {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso) ?? { let g = ISO8601DateFormatter(); g.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return g.date(from: iso) }()
}
func shortDate(_ iso: String) -> String {
    guard let d = isoDate(iso) else { return String(iso.prefix(10)) }
    let f = DateFormatter(); f.dateFormat = "M月d日"; f.locale = Locale(identifier: "zh_CN"); return f.string(from: d)
}
func fullDate(_ iso: String) -> String {
    guard let d = isoDate(iso) else { return String(iso.prefix(10)) }
    let f = DateFormatter(); f.dateFormat = "yyyy年M月d日 · HH:mm"; f.locale = Locale(identifier: "zh_CN"); return f.string(from: d)
}
