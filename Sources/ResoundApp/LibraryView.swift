import SwiftUI
import ResoundCore

struct LibraryView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var vm: LibraryModel
    @EnvironmentObject var rec: RecordingController
    @EnvironmentObject var documents: DocumentsModel
    @EnvironmentObject var mcp: MCPModel
    @Environment(\.palette) var pal
    @State private var hoverId: String?
    @State private var hoverFolderId: String?
    @State private var folderSuggestOpen: String?   // 哪条录音的文件夹建议浮层打开
    @State private var scrollRelatedToken = 0   // 摘要区「N 篇文档已纳入」提示 → 滚到上方「相关文档」卡

    var body: some View {
        let _ = Perf.body("LibraryView")
        return HStack(spacing: 0) {
            listColumn
            Rectangle().fill(pal.border).frame(width: 1)
            detail
        }
        .onAppear { vm.load() }
        .onChange(of: app.libraryReloadToken) { _, _ in vm.refresh() }
        .background {
            Button("") { vm.openFind() }.keyboardShortcut("f", modifiers: .command).hidden()
        }
    }

    // MARK: 列表

    private var listColumn: some View {
        let secs = Perf.measure("sections") { vm.sections() }   // 一次算好复用，避免 body 内 O(folders×recordings) 过滤跑两遍
        return VStack(spacing: 0) {
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
                    Button { vm.toggleSelectionMode() } label: {
                        Image(systemName: vm.selectionMode ? "checkmark.circle.fill" : "checkmark.circle").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(vm.selectionMode ? pal.accent : pal.text)
                            .frame(width: 30, height: 30).card(pal, corner: 8)
                    }.buttonStyle(.plainHit).hoverCursor().help(vm.selectionMode ? "退出多选" : "多选合并录音")
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
                    ForEach(vm.pendingImports) { p in importingRow(p) }
                    ForEach(secs) { sec in
                        VStack(spacing: 2) {
                            folderHeader(sec)
                            if !vm.isCollapsed(sec.id) {
                                if sec.recordings.isEmpty && vm.query.isEmpty {
                                    Text("该文件夹暂无录音 · 可拖拽录音到此")
                                        .font(.system(size: 11.5)).foregroundStyle(pal.text3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 11).padding(.vertical, 9)
                                } else {
                                    ForEach(sec.recordings) { r in recordingRow(r) }
                                }
                            }
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let rid = items.first else { return false }
                            vm.move(rid, to: sec.folderId); return true
                        } isTargeted: { over in
                            vm.dragOverFolder = over ? sec.id : (vm.dragOverFolder == sec.id ? nil : vm.dragOverFolder)
                        }
                        .zIndex(vm.moveMenuFor != nil && sec.recordings.contains { $0.id == vm.moveMenuFor } ? 10 : 0)
                    }
                    if secs.allSatisfy({ $0.recordings.isEmpty }) && !vm.query.isEmpty {
                        Text("没有匹配「\(vm.query)」的录音").font(.system(size: 12)).foregroundStyle(pal.text3).padding(.top, 20)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
            if vm.selectionMode { mergeBar }
        }
        .frame(width: 300)
        .background(pal.sidebar)
    }

    private func folderHeader(_ sec: LibraryModel.Section) -> some View {
        let collapsed = vm.isCollapsed(sec.id)
        let dragOver = vm.dragOverFolder == sec.id && vm.dragRecId != nil
        let hovering = hoverFolderId == sec.id
        let canManage = sec.folderId != nil
        return Button { vm.toggleCollapse(sec.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(pal.text3)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Image(systemName: sec.folderId == nil ? "tray" : "folder").font(.system(size: 12)).foregroundStyle(pal.text2)
                Text(sec.name).font(.system(size: 12.5, weight: .bold)).foregroundStyle(pal.text).lineLimit(1)
                Spacer(minLength: 4)
                if canManage && hovering {
                    HStack(spacing: 2) {
                        folderAction("pencil") { vm.openRenameFolder(sec.folderId!) }
                        folderAction("trash", danger: true) { vm.confirmDeleteFolderId = sec.folderId! }
                    }
                } else {
                    Text("\(sec.recordings.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(pal.text3)
                }
            }
            .frame(height: 26)   // 固定行高（容纳 26px 操作按钮）：hover 出按钮时不撑高，避免列表抖动
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(dragOver ? pal.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay { if dragOver { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(pal.accent) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit).hoverCursor()
        .padding(.top, 6)
        .onHover { hoverFolderId = $0 ? sec.id : (hoverFolderId == sec.id ? nil : hoverFolderId) }
        .contextMenu {
            if let fid = sec.folderId {
                Button("重命名文件夹") { vm.openRenameFolder(fid) }
                Button("删除文件夹", role: .destructive) { vm.confirmDeleteFolderId = fid }
            }
        }
    }

    private func folderAction(_ name: String, danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        RowIconButton(pal: pal, icon: name, danger: danger, action: action)
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
                Text(RecordingController.procLabels[min(rec.procStep, RecordingController.procLabels.count - 1)]).font(.system(size: 11.5)).foregroundStyle(pal.text2)
            }
            Spacer()
            Spinner(size: 13, color: pal.accent)
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(pal.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.top, 4)
    }

    /// 后台导入中的占位行（转写/识别中显示 spinner；失败可关掉）。
    private func importingRow(_ p: LibraryModel.ImportItem) -> some View {
        let failed = p.status == .failed
        // 失败副标题：有具体原因就显示（截断成一行，完整文案进 tooltip），否则只说「转写失败」。
        let subtitle = failed ? (p.error.map { "转写失败：\($0)" } ?? "转写失败")
                              : (p.status == .identifying ? "识别说话人…" : "转写中…")
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(p.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11.5)).foregroundStyle(failed ? pal.rec : pal.text2).lineLimit(1)
                    .help(p.error ?? "")   // 悬停看完整报错
            }
            Spacer()
            if failed {
                HStack(spacing: 2) {
                    importAction("arrow.clockwise", "重试转写", color: pal.accent) { vm.retryImport(p.id) }
                    importAction("folder", "在 Finder 中显示音频") { vm.revealImport(p.id) }
                    importAction("xmark", "移除") { vm.dismissPending(p.id) }
                }
            } else {
                Spinner(size: 13, color: pal.accent)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(failed ? pal.recSoft : pal.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.top, 4)
    }

    private func importAction(_ icon: String, _ help: String, color: Color? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
                .foregroundStyle(color ?? pal.text3).frame(width: 24, height: 24)
        }.buttonStyle(.plainHit).hoverCursor().help(help)
    }

    /// 多选模式底部操作条：显示已选数 + 合并/取消。
    @ViewBuilder private var mergeBar: some View {
        let n = vm.mergeSelection.count
        VStack(spacing: 0) {
            Rectangle().fill(pal.border).frame(height: 1)
            HStack(spacing: 10) {
                Button { vm.exitSelectionMode() } label: {
                    Text("取消").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text2)
                }.buttonStyle(.plainHit).hoverCursor()
                Spacer()
                Text("已选 \(n) 条").font(.system(size: 12)).foregroundStyle(pal.text2)
                Button { vm.beginMerge() } label: {
                    HStack(spacing: 5) {
                        if vm.merging { Spinner(size: 10, color: .white) }
                        else { Image(systemName: "arrow.triangle.merge").font(.system(size: 11, weight: .bold)) }
                        Text("合并").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 30)
                    .background(n >= 2 && !vm.merging ? pal.accent : pal.text3, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }.buttonStyle(.plainHit).hoverCursor().disabled(n < 2 || vm.merging)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(pal.sidebar)
    }

    private func recordingRow(_ r: RecordingSummary) -> some View {
        let picking = vm.selectionMode
        let checked = vm.mergeSelection.contains(r.id)
        let on = picking ? checked : (vm.selectedId == r.id)
        let identifying = vm.identifyingIds.contains(r.id)
        let summarizing = vm.summarizingIds.contains(r.id)
        let identified = r.identified   // 扫描时算好的内存标志，免每行每次重绘做 fileExists 系统调用
        return HStack(spacing: 10) {
            if picking {
                Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17)).foregroundStyle(checked ? pal.accent : pal.text3)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(r.title).font(.system(size: 12.5, weight: .regular)).foregroundStyle(pal.text).lineLimit(1)
                HStack(spacing: 8) {
                    Text(shortDate(r.recordedAt)).font(.system(size: 11.5)).foregroundStyle(pal.text2)
                    Text("·").font(.system(size: 11)).foregroundStyle(pal.text3)
                    Text(mmss(Double(r.durationSec))).font(.system(size: 11, design: .monospaced)).foregroundStyle(pal.text3)
                }
                // 状态徽标独占一行：日期加了年份后侧栏一行塞不下，徽标会被挤换行 → 下移避免挤压。
                if identifying {
                    HStack(spacing: 4) {
                        Spinner(size: 9, color: pal.accent)
                        Text("识别说话人中…").font(.system(size: 10, weight: .semibold)).foregroundStyle(pal.accent).lineLimit(1)
                    }
                    .fixedSize().padding(.horizontal, 7).padding(.vertical, 2).background(pal.accentSoft, in: Capsule())
                } else if summarizing {
                    HStack(spacing: 4) {
                        Spinner(size: 9, color: pal.accent)
                        Text("生成摘要中…").font(.system(size: 10, weight: .semibold)).foregroundStyle(pal.accent).lineLimit(1)
                    }
                    .fixedSize().padding(.horizontal, 7).padding(.vertical, 2).background(pal.accentSoft, in: Capsule())
                } else if !identified {
                    Text("待识别").font(.system(size: 10, weight: .semibold)).foregroundStyle(pal.warn).lineLimit(1)
                        .fixedSize().padding(.horizontal, 7).padding(.vertical, 2)
                        .background(pal.warnSoft, in: Capsule())
                }
                if vm.recomputingFolder.contains(r.id) {
                    HStack(spacing: 4) {
                        Spinner(size: 9, color: pal.accent)
                        Text("推算文件夹中…").font(.system(size: 10, weight: .semibold)).foregroundStyle(pal.accent).lineLimit(1)
                    }
                    .fixedSize().padding(.horizontal, 7).padding(.vertical, 2).background(pal.accentSoft, in: Capsule())
                } else if let s = vm.pendingFolderSuggestion(r.id) {
                    Button { folderSuggestOpen = r.id } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "lightbulb.fill").font(.system(size: 9))
                            Text("建议：\(vm.folderSuggestionLabel(s))").font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        }
                        .foregroundStyle(pal.accent)
                        .fixedSize().padding(.horizontal, 7).padding(.vertical, 2).background(pal.accentSoft, in: Capsule())
                    }
                    .buttonStyle(.plain).hoverCursor()
                    .popover(isPresented: Binding(get: { folderSuggestOpen == r.id }, set: { if !$0 { folderSuggestOpen = nil } }), arrowEdge: .bottom) {
                        folderSuggestPopover(r.id, s)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12).padding(.top, 11).padding(.bottom, 12)
            .background(on ? pal.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .stroke(on ? pal.accent : .clear, corner: 10)
            .opacity(vm.dragRecId == r.id ? 0.4 : 1)
            .overlay(alignment: .topTrailing) {
                if !picking && hoverId == r.id && vm.moveMenuFor != r.id {
                    HStack(spacing: 2) {
                        iconBtn("folder") { vm.openMoveMenu(r.id) }
                        iconBtn("pencil") { vm.openRenameRec(r.id) }
                        iconBtn("trash", danger: true) { vm.deleteRecId = r.id }
                    }
                    .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !picking && vm.moveMenuFor == r.id { movePopover(r) }
            }
            .contentShape(Rectangle())
            .background(WindowDragBlocker(clickable: true))   // 阻止「拖窗口」+ 整行小手指针（可点击）
            .onTapGesture { if picking { vm.toggleMergeSelect(r.id) } else { vm.select(r.id) } }
            .hoverCursor()
            .onHover { hoverId = $0 ? r.id : (hoverId == r.id ? nil : hoverId) }
            .onDrag { if picking { return NSItemProvider() }; vm.dragRecId = r.id; return NSItemProvider(object: r.id as NSString) }
        .contextMenu {
            if !picking {
                moveMenu(r)
                Button(vm.recomputingFolder.contains(r.id) ? "推算中…" : "重新推算文件夹") { vm.recomputeFolderSuggestion(r.id) }
                    .disabled(vm.recomputingFolder.contains(r.id))
                Divider()
                Button("重命名") { vm.openRenameRec(r.id) }
                Button("删除", role: .destructive) { vm.deleteRecId = r.id }
            }
        }
    }

    /// 「移动到」内联浮层（点行内文件夹图标弹出）。
    private func movePopover(_ r: RecordingSummary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("移动到").font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(pal.text3)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.top, 5).padding(.bottom, 6)
            ForEach(vm.folders) { f in
                moveItem(name: f.name, icon: "folder", active: vm.assign[r.id] == f.id) { vm.move(r.id, to: f.id) }
            }
            moveItem(name: "未分类", icon: "tray", active: vm.assign[r.id] == nil || !vm.folders.contains { $0.id == vm.assign[r.id] }) { vm.move(r.id, to: nil) }
            Rectangle().fill(pal.border).frame(height: 1).padding(.vertical, 5)
            Button { vm.openNewFolder(moveRec: r.id) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text("新建文件夹…").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(pal.accent).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(Rectangle())
            }.buttonStyle(.plainHit).hoverCursor()
        }
        .frame(width: 186)
        .padding(6)
        .background(pal.elev, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .stroke(pal.borderStrong, corner: 11)
        .shadow(color: .black.opacity(0.22), radius: 14, y: 8)
        .offset(x: -6, y: 36)
        .onTapGesture { }   // 吞掉点击，避免落到行的选中
    }

    /// 智能推算文件夹的确认浮层（点行内「建议：X」角标弹出）。
    private func folderSuggestPopover(_ recId: String, _ s: FolderSuggestionRecord) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: "lightbulb.fill").font(.system(size: 11)).foregroundStyle(pal.accent)
                Text("建议归入").font(.system(size: 11)).foregroundStyle(pal.text2)
                Text(vm.folderSuggestionLabel(s)).font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1)
                if vm.folderSuggestionIsNew(s) {
                    Text("新").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(pal.accent, in: Capsule())
                }
            }
            HStack(spacing: 8) {
                Button { vm.acceptFolderSuggestion(recId); folderSuggestOpen = nil } label: {
                    Text(vm.folderSuggestionIsNew(s) ? "新建并归入" : "采纳").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 26).background(pal.accent, in: Capsule())
                }.buttonStyle(.plain).hoverCursor()
                Button { vm.dismissFolderSuggestion(recId); folderSuggestOpen = nil } label: {
                    Text("忽略").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(pal.text2).padding(.horizontal, 12).frame(height: 26).background(pal.inset, in: Capsule())
                }.buttonStyle(.plain).hoverCursor()
            }
        }
        .padding(13)
        .frame(width: 230, alignment: .leading)
        .background(pal.elev)
    }

    private func moveItem(name: String, icon: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(pal.text2)
                Text(name).font(.system(size: 12.5)).foregroundStyle(pal.text).lineLimit(1)
                Spacer(minLength: 4)
                if active { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(pal.accent) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }.buttonStyle(.plainHit).hoverCursor()
    }

    private func iconBtn(_ name: String, danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        RowIconButton(pal: pal, icon: name, danger: danger, action: action)
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
            if vm.reindexing {
                HStack(spacing: 6) { Spinner(size: 12, color: pal.accent); Text("同步检索…").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(pal.text2) }
            }
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
                    PlayerBar(vm: vm, playhead: vm.playhead, sel: sel, pal: pal).padding(.top, 22)
                    relatedDocsCard(sel).padding(.top, 18).id("rs-related-docs")
                    tabBar.padding(.top, 24)
                    if vm.loadingDetail { detailLoadingCard }
                    else if vm.tab == .summary { summaryTab }
                    else if vm.tab == .transcript { transcriptTab }
                    else { recAskTab(sel) }
                }
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 40).padding(.top, 32).padding(.bottom, 60)
            }
            .onChange(of: vm.findQuery) { _, _ in
                Perf.measure("find.scrollTo") {
                    // 不加动画：长转录里动画滚动会强制 LazyVStack 一次性实例化沿途所有行（原 14s 卡死元凶）；直接跳转便宜得多。
                    if let id = vm.firstMatchLineID() { proxy.scrollTo(id, anchor: .center) }
                }
            }
            // 引用跳转：scrollToLine 常在本视图挂载**之前**就被后台 refreshDetail 设好（点引用时还在 Ask 页），
            // 单靠 onChange 会错过那次变更 → 永不滚动。故三处都触发待定滚动：挂载时、转录载入后、scrollToLine 变更时。
            .onChange(of: vm.scrollToLine) { _, _ in scrollToCitation(proxy) }
            .onChange(of: vm.flatLines.count) { _, _ in scrollToCitation(proxy) }
            .onAppear { scrollToCitation(proxy) }
            // 本场提问：新消息进来 / 回答结束时滚到底部，让回答可见
            .onChange(of: vm.recMsgs.count) { _, _ in if vm.tab == .ask { withAnimation { proxy.scrollTo("recAskBottom", anchor: .bottom) } } }
            .onChange(of: vm.recAskBusy) { _, b in if !b && vm.tab == .ask { withAnimation { proxy.scrollTo("recAskBottom", anchor: .bottom) } } }
            .onChange(of: scrollRelatedToken) { _, _ in withAnimation { proxy.scrollTo("rs-related-docs", anchor: .top) } }
        }
    }

    /// 把待定的引用跳转目标滚到中间（转录已载入才滚；滚完清空，避免后续 blocks 变更重复触发）。
    private func scrollToCitation(_ proxy: ScrollViewProxy) {
        guard let id = vm.scrollToLine, !vm.flatLines.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard vm.scrollToLine == id else { return }   // 期间被新跳转替换则放弃
            withAnimation { proxy.scrollTo(id, anchor: .center) }
            vm.scrollToLine = nil
        }
    }

    /// 录音详情「相关文档」区：反查关联到本场的文档（本地 + 外部 MCP），可点开、同步、关联链接、管理。
    private func relatedDocsCard(_ sel: RecordingSummary) -> some View {
        let all = documents.relatedDocuments(forRecording: sel.id)
        let localDocs = all.filter { !$0.isExternal }
        let extDocs = all.filter { $0.isExternal }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.doc)
                Text("相关文档 · \(all.count)").font(.system(size: 13, weight: .bold)).foregroundStyle(pal.text)
                Spacer()
                Button { mcp.openLink(recId: sel.id, recTitle: sel.title) } label: {
                    HStack(spacing: 5) { Image(systemName: "link").font(.system(size: 11, weight: .semibold)); Text("关联链接").font(.system(size: 12, weight: .semibold)) }
                        .foregroundStyle(pal.text).padding(.horizontal, 11).frame(height: 28)
                        .background(pal.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous)).stroke(pal.borderStrong, corner: 7)
                }.buttonStyle(.plainHit).hoverCursor()
                Button { documents.openLinkFromRec(sel.id) } label: {
                    Text("管理").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(pal.text).padding(.horizontal, 11).frame(height: 28)
                        .background(pal.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous)).stroke(pal.borderStrong, corner: 7)
                }.buttonStyle(.plainHit).hoverCursor()
            }
            .padding(.horizontal, 15).padding(.vertical, 12)
            Rectangle().fill(pal.border).frame(height: 1)
            if all.isEmpty {
                Text("还没有关联文档。点「关联链接」粘贴 Notion / Jira / Figma 等外部文档的网址，或点「管理」关联已导入的文档 —— 它们都会一起参与问答。")
                    .font(.system(size: 12.5)).foregroundStyle(pal.text3).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 15).padding(.vertical, 14)
            } else {
                ForEach(localDocs) { d in relatedDocRow(d) }
                ForEach(extDocs) { d in externalDocRow(d, recId: sel.id) }
            }
        }
        .card(pal, corner: 13)
    }

    /// 外部 MCP 来源文档行（form 角标 + 同步/打开/移除）。
    private func externalDocRow(_ d: DocumentSummary, recId: String) -> some View {
        let ext = d.external
        let imported = ext?.form != "link"
        let kind = ext?.kind.flatMap { MCPSourceKind(rawValue: $0) }
        return HStack(spacing: 12) {
            SourceIcon(kind: kind, size: 30)
            Button {
                if imported { documents.select(d.id); app.page = .documents }
                else if let u = ext?.url { mcp.openExternal(u) }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(d.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1)
                        Text(imported ? "已导入" : "仅链接").font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(imported ? pal.doc : pal.text3)
                            .padding(.horizontal, 7).padding(.vertical, 1).background(imported ? pal.docSoft : pal.inset, in: RoundedRectangle(cornerRadius: 5))
                    }
                    HStack(spacing: 6) {
                        Text(ext?.kind.flatMap { MCPSourceKind(rawValue: $0) }.map(sourceDisplayName) ?? "外部来源").font(.system(size: 11.5)).foregroundStyle(pal.text2)
                        if imported { Text("· 已取回").font(.system(size: 11)).foregroundStyle(pal.ok) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plainHit).hoverCursor()
            HStack(spacing: 1) {
                if imported {
                    if mcp.isSyncing(d.dir) {
                        Spinner(size: 13, color: pal.accent).frame(width: 28, height: 28)
                    } else {
                        Button { mcp.syncExternalDoc(dir: d.dir) } label: { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13)).foregroundStyle(pal.text2).frame(width: 28, height: 28) }.buttonStyle(.plainHit).hoverCursor().help("重新取回并同步")
                    }
                }
                if let u = ext?.url {
                    Button { mcp.openExternal(u) } label: { Image(systemName: "arrow.up.right.square").font(.system(size: 13)).foregroundStyle(pal.text2).frame(width: 28, height: 28) }.buttonStyle(.plainHit).hoverCursor()
                }
                Button { documents.removeRecordingLink(docId: d.id, recId: recId) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(pal.text3).frame(width: 28, height: 28) }.buttonStyle(.plainHit).hoverCursor()
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
        .overlay(alignment: .top) { Rectangle().fill(pal.border).frame(height: 1) }
    }

    private func sourceDisplayName(_ k: MCPSourceKind) -> String {
        switch k { case .notion: return "Notion"; case .atlassian: return "Jira / Confluence"; case .google: return "Google Workspace"; case .figma: return "Figma"; case .custom: return "自定义来源" }
    }

    private func relatedDocRow(_ d: DocumentSummary) -> some View {
        Button { documents.select(d.id); app.page = .documents } label: {
            HStack(spacing: 12) {
                ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(pal.docSoft)
                    Image(systemName: "doc.text").font(.system(size: 14)).foregroundStyle(pal.doc) }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(d.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(d.sourceFormat.lowercased() == "txt" ? "纯文本" : "Markdown").font(.system(size: 11.5)).foregroundStyle(pal.text2)
                        ForEach(d.tags.prefix(2), id: \.self) { t in
                            Text(t).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(pal.doc)
                                .padding(.horizontal, 7).padding(.vertical, 1).background(pal.docSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text3)
            }
            .padding(.horizontal, 15).padding(.vertical, 11).contentShape(Rectangle())
        }
        .buttonStyle(.plainHit).hoverCursor()
        .overlay(alignment: .top) { Rectangle().fill(pal.border).frame(height: 1) }
    }

    private var detailLoadingCard: some View {
        VStack(spacing: 0) {
            Spinner(size: 28, color: pal.border)
            Text("正在载入…").font(.system(size: 14, weight: .semibold)).foregroundStyle(pal.text2).padding(.top, 14)
        }
        .frame(maxWidth: .infinity).padding(40).card(pal).padding(.top, 24)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tab("会议摘要", .summary); tab("逐句转录", .transcript); tab("向本场提问", .ask)
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
        if vm.hasSpeakers { summarySpeakers }   // 已识别说话人 → 摘要页顶部简单展示一排说话人徽标
        summaryBody
    }

    /// 摘要页顶部的说话人徽标（纯展示：头像 + 名字 + 占比，会自动换行；不可点击/不做修改）。
    private var summarySpeakers: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("说话人 · \(vm.speakers.count) 位").font(.system(size: 12, weight: .bold)).foregroundStyle(pal.text2)
            FlowLayout(spacing: 8) {
                ForEach(vm.speakers) { sp in summarySpeakerChip(sp) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
    }

    private func summarySpeakerChip(_ sp: LibraryModel.SpeakerStat) -> some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(speakerColor(for: sp.name, anon: sp.isAnon))
                Text(sp.isAnon ? "?" : String(sp.name.prefix(1)))
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(sp.isAnon ? pal.text3 : .white)
            }
            .frame(width: 22, height: 22)
            .overlay { if sp.isAnon { Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3])).foregroundStyle(pal.borderStrong) } }
            Text(sp.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text)
            Text("\(sp.pct)%").font(.system(size: 11, design: .monospaced)).foregroundStyle(pal.text3)
        }
        .padding(.leading, 4).padding(.trailing, 11).frame(height: 30)
        .background(pal.elev, in: Capsule())
        .overlay(Capsule().strokeBorder(pal.border, lineWidth: 1))
    }

    @ViewBuilder private var summaryBody: some View {
        if vm.identifyingSelected && vm.summaryText == nil {
            VStack(spacing: 0) {
                Spinner(size: 30, color: pal.accent)
                Text("正在识别说话人…").font(.system(size: 15, weight: .semibold)).foregroundStyle(pal.text).padding(.top, 16)
                Text("识别完成后会自动生成带说话人姓名的会议摘要。转录文稿已经可以查看、检索、问答。")
                    .font(.system(size: 13)).foregroundStyle(pal.text2).multilineTextAlignment(.center).frame(maxWidth: 380).padding(.top, 6)
            }
            .frame(maxWidth: .infinity).padding(36).card(pal).padding(.top, 18)
        } else if vm.summarizing {
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
            .padding(.top, 18).zIndex(1)   // 让模板下拉浮在摘要卡之上
            summaryDocsHint
            SummaryMarkdown(text: text, pal: pal, highlight: vm.findOpen ? vm.findQuery : "")
                .equatable()   // 切页/折叠时 LibraryView.body 重跑也不重解析 Markdown
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
                summaryDocsHintPending.padding(.top, 14)
            }
            .frame(maxWidth: .infinity).padding(34)
            .background(pal.inset, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(pal.borderStrong))
            .padding(.top, 18)
        }
    }

    /// 本场关联文档数（实时由当前 links 推导）。
    private var relatedDocCount: Int {
        vm.selectedId.map { documents.relatedDocuments(forRecording: $0).count } ?? 0
    }

    /// 已生成摘要时：一行可点提示，点击滚动到上方「相关文档」卡。仅当本场有关联文档时显示。
    @ViewBuilder private var summaryDocsHint: some View {
        if relatedDocCount > 0 {
            Button { scrollRelatedToken &+= 1 } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text").font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.doc)
                    Text("本场关联的 \(relatedDocCount) 篇文档已作为背景纳入").font(.system(size: 11.5)).foregroundStyle(pal.text2)
                    Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)).foregroundStyle(pal.text3)
                }
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(pal.docSoft, in: Capsule())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit).hoverCursor().help("点击查看本场关联的文档")
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
        }
    }

    /// 未生成摘要时：空状态里提示「将纳入 N 篇关联文档作为背景」。
    @ViewBuilder private var summaryDocsHintPending: some View {
        if relatedDocCount > 0 {
            HStack(spacing: 6) {
                Image(systemName: "doc.text").font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.doc)
                Text("将纳入本场关联的 \(relatedDocCount) 篇文档作为背景").font(.system(size: 11.5)).foregroundStyle(pal.text2)
            }
        }
    }

    private var curTplName: String {
        SummaryTemplateStore.load().first { $0.id == vm.currentTemplateId() }?.name ?? "默认"
    }

    // 自绘下拉（不用原生 Menu，保证胶囊外观与设计稿一致）：模板：name ⌄
    private var templateMenu: some View {
        Button { vm.tplMenuOpen.toggle() } label: {
            HStack(spacing: 6) {
                Text("模板：").font(.system(size: 12)).foregroundStyle(pal.text2)
                + Text(curTplName).font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(pal.text2)
                    .rotationEffect(.degrees(vm.tplMenuOpen ? 180 : 0))
            }
            .padding(.horizontal, 11).frame(height: 30)
            .background(pal.elev, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).stroke(pal.borderStrong, corner: 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit).hoverCursor()
        .overlay(alignment: .topLeading) {
            if vm.tplMenuOpen {
                VStack(spacing: 1) {
                    ForEach(SummaryTemplateStore.load()) { t in
                        TplOptionRow(name: t.name, active: t.id == vm.currentTemplateId(), pal: pal) { vm.chooseTemplate(t.id) }
                    }
                }
                .padding(6).frame(width: 210)
                .background(pal.elev, in: RoundedRectangle(cornerRadius: 11, style: .continuous)).stroke(pal.borderStrong, corner: 11)
                .shadow(color: .black.opacity(0.20), radius: 18, x: 0, y: 8)
                .offset(y: 38).zIndex(60)
            }
        }
    }

    // MARK: 转录 Tab

    @ViewBuilder private var transcriptTab: some View {
        let _ = Perf.body("transcriptTab")
        if vm.identifyingSelected && !vm.hasSpeakers {
            HStack(spacing: 14) {
                Spinner(size: 18, color: pal.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在识别说话人…").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                    Text("后台正在区分谁说了什么（这一步较慢）。完成后逐句会自动标上姓名。").font(.system(size: 12.5)).foregroundStyle(pal.text2)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .background(pal.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.top, 18)
            transcriptLines.padding(.top, 22)
        } else if !vm.hasSpeakers {
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
                            HStack(spacing: 6) {
                                Image(systemName: sp.isAnon ? "pencil" : "person.fill.questionmark").font(.system(size: 11, weight: .semibold))
                                Text(sp.isAnon ? "命名" : "重分配").font(.system(size: 12.5, weight: .semibold))
                            }
                                .foregroundStyle(sp.isAnon ? .white : pal.text)
                                .padding(.horizontal, 13).frame(height: 30)
                                .background(sp.isAnon ? pal.accent : pal.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .stroke(sp.isAnon ? .clear : pal.borderStrong, corner: 8)
                        }
                        .buttonStyle(.plainHit).hoverCursor().help(sp.isAnon ? "" : "如果这个人认错了，重新分配给正确的人（不影响已记住的声音）")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                if sp.id != vm.speakers.last?.id { Rectangle().fill(pal.border).frame(height: 1) }
            }
        }
        .card(pal)
    }

    private func rosterAvatar(_ sp: LibraryModel.SpeakerStat) -> some View {
        ZStack {
            Circle().fill(speakerColor(for: sp.name, anon: sp.isAnon))
            Text(sp.isAnon ? "?" : String(sp.name.prefix(2)))
                .font(.system(size: 13, weight: .bold)).foregroundStyle(sp.isAnon ? pal.text3 : .white)
        }
        .frame(width: 36, height: 36)
        .overlay { if sp.isAnon { Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3])).foregroundStyle(pal.borderStrong) } }
    }

    // 单层 LazyVStack：每行独立懒加载、scrollTo(line.id) 必可寻址（引用跳转可靠）。
    // 说话人 chip 在段首（item.chip 非 nil）随行内联渲染。
    private var transcriptLines: some View {
        let q = (vm.findOpen && !vm.findQuery.isEmpty) ? vm.findQuery : ""
        let activeID = vm.activeLineID
        return LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(vm.flatLines) { item in
                VStack(alignment: .leading, spacing: 2) {
                    if vm.hasSpeakers, let spk = item.chip {
                        transcriptSpeakerChip(spk).padding(.leading, 16).padding(.top, 14).padding(.bottom, 4)
                    }
                    // Equatable 行：仅当本行的 text/active/查询词/主题变了才重渲——
                    // 否则 vm 任何无关 @Published 变更（播放头/录音计时/本场提问态…）不再触发全列表 157 行重算。
                    TranscriptLineRow(lineID: item.line.id, start: item.line.start, text: item.line.text,
                                      active: activeID == item.line.id, query: q, pal: pal,
                                      onSeek: { vm.seek(to: item.line.start) })
                        .equatable()
                }
                .id(item.line.id)
            }
        }
    }

    /// 说话人配色（与名册头像一致，按 index 取色；匿名用灰底）。
    /// 说话人头像底色：按**名字**的稳定哈希取色——同一个人无论在哪条录音、跨 App 重启都恒定同色。
    /// 不能用 `String.hashValue`：它每次进程启动都带随机种子，会让同一人每次开 App 变色。
    private func speakerColor(for name: String, anon: Bool) -> Color {
        if anon { return pal.inset }
        let hues: [Color] = [pal.accent, Color(hex: 0x9b6dc9), Color(hex: 0x3f9d7a), Color(hex: 0xd98a3d), Color(hex: 0xc75d8a)]
        var h: UInt64 = 5381                                   // djb2，确定性哈希
        for b in name.utf8 { h = (h &* 33) &+ UInt64(b) }
        return hues[Int(h % UInt64(hues.count))]
    }

    /// 逐句转录每段开头的说话人胶囊：头像 + 名字 + 改名笔，描边成明确可点的按钮（点开命名/改名）。
    private func transcriptSpeakerChip(_ label: String) -> some View {
        let stat = vm.speakers.first { $0.label == label }
        let anon = stat?.isAnon ?? LibraryModel.isAnon(label)
        let color = speakerColor(for: stat?.name ?? label, anon: anon)
        return Button { vm.openRenameSpeaker(label) } label: {
            HStack(spacing: 7) {
                ZStack {
                    Circle().fill(color)
                    Text(anon ? "?" : String(label.prefix(1)))
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(anon ? pal.text3 : .white)
                }
                .frame(width: 22, height: 22)
                .overlay { if anon { Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3])).foregroundStyle(pal.borderStrong) } }
                Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text)
                Image(systemName: "pencil").font(.system(size: 9, weight: .semibold)).foregroundStyle(pal.text3)
            }
            .padding(.leading, 4).padding(.trailing, 10).frame(height: 30)
            .background(pal.elev, in: Capsule())
            .overlay(Capsule().strokeBorder(pal.border, lineWidth: 1))
        }
        .buttonStyle(.plainHit).hoverCursor()
    }


    // MARK: 向本场提问 Tab

    @ViewBuilder private func recAskTab(_ sel: RecordingSummary) -> some View {
        let _ = Perf.body("recAskTab")
        let msgs = vm.recMsgs
        VStack(alignment: .leading, spacing: 0) {
            if !msgs.isEmpty {
                HStack {
                    Spacer()
                    Button { vm.clearRecChat() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
                            Text("重置对话").font(.system(size: 11.5))
                        }
                        .foregroundStyle(pal.text3).padding(.horizontal, 9).frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plainHit).hoverCursor().help("清空本场对话")
                }
                .padding(.top, 4)

                VStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(msgs.enumerated()), id: \.element.id) { i, m in
                        recMsgView(m, prev: i > 0 ? msgs[i - 1] : nil, isFirst: i == 0)
                    }
                }
                .padding(.top, 14)
            }

            RecAskInputBar(pal: pal, busy: vm.recAskBusy, resetToken: sel.id) { vm.askRecording($0) }
                .padding(.top, msgs.isEmpty ? 4 : 20)
            Text("仅检索本场会议 · 本地模型生成，请核对引用。")
                .font(.system(size: 11)).foregroundStyle(pal.text3)
                .frame(maxWidth: .infinity, alignment: .center).padding(.top, 8)
                .id("recAskBottom")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18)
    }

    /// 本场对话单条消息（含会话时间分隔）。
    @ViewBuilder private func recMsgView(_ m: LibraryModel.RecAskMsg, prev: LibraryModel.RecAskMsg?, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let label = recDivider(m, prev: prev, isFirst: isFirst) {
                HStack(spacing: 12) {
                    Rectangle().fill(pal.border).frame(height: 1)
                    Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.text3).fixedSize()
                    Rectangle().fill(pal.border).frame(height: 1)
                }
            }
            if m.isUser {
                HStack { Spacer(minLength: 50)
                    Text(m.full).font(.system(size: 13.5)).foregroundStyle(.white).lineSpacing(2)
                        .padding(.vertical, 10).padding(.horizontal, 14)
                        .background(pal.accent, in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14, style: .continuous))
                        .frame(maxWidth: 460, alignment: .trailing)
                }
            } else {
                HStack(alignment: .top, spacing: 11) {
                    ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(pal.accentSoft)
                        WaveMark(pal: pal, height: 10) }.frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 0) { recAssistantBody(m) }
                    Spacer(minLength: 30)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func recAssistantBody(_ m: LibraryModel.RecAskMsg) -> some View {
        switch m.phase {
        case .searching, .thinking:
            HStack(spacing: 9) { Spinner(size: 14, color: pal.text2)
                Text(m.phase == .searching ? "正在检索这场会议…" : "正在阅读相关片段…")
                    .font(.system(size: 13)).foregroundStyle(pal.text2) }.frame(height: 22)
        case .empty:
            Text("这场会议的转录里没有直接相关的内容。换个更具体的说法，或切到「逐句转录」自己翻一翻。")
                .font(.system(size: 13)).foregroundStyle(pal.text2).lineSpacing(3)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(pal.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(pal.borderStrong))
        case .answering:
            Text(String(m.full.prefix(m.revealed)) + "▍")
                .font(.system(size: 13.5)).foregroundStyle(pal.text).lineSpacing(4).textSelection(.enabled)
        case .done:
            SummaryMarkdown(text: m.full, pal: pal)
            if !m.cites.isEmpty { recCitesView(m) }
        }
    }

    private func recCitesView(_ m: LibraryModel.RecAskMsg) -> some View {
        let open = vm.recCiteOpen.contains(m.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.14)) { vm.toggleRecCite(m.id) } } label: {
                HStack(spacing: 5) {
                    Text("本场引用 · \(m.cites.count)").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(pal.text3)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(pal.text3).rotationEffect(.degrees(open ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plainHit).hoverCursor()
            if open {
                ForEach(m.cites) { c in
                    Button {
                        if c.isDoc {
                            if let id = c.docId { documents.openFromCite(docId: id, snippet: c.snippet); app.page = .documents }
                        } else {
                            vm.openRecCite(time: c.time)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                if c.isDoc {
                                    Image(systemName: "doc.text").font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.doc)
                                    Text(c.docTitle ?? c.docId ?? "未命名文档").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(pal.doc).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text("关联文档").font(.system(size: 9.5, weight: .semibold)).tracking(0.4).foregroundStyle(pal.doc)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(pal.docSoft, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                } else {
                                    Text(c.speaker).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(pal.accent)
                                    Spacer(minLength: 8)
                                    Text(mmss(c.time)).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(pal.text3)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(pal.inset, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                }
                            }
                            Text("“\(c.snippet)”").font(.system(size: 12)).italic().foregroundStyle(pal.text2).lineSpacing(1).lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .card(pal, corner: 10)
                    }
                    .buttonStyle(.plainHit).hoverCursor()
                }
            }
        }
        .padding(.top, 13)
    }

    /// 会话分隔标签：首条显示时间；与上一条间隔 >20 分钟显示「继续对话 · 时间」。
    private func recDivider(_ m: LibraryModel.RecAskMsg, prev: LibraryModel.RecAskMsg?, isFirst: Bool) -> String? {
        guard m.isUser else { return nil }   // 只在每轮的用户提问前出现
        if isFirst { return recMsgTime(m.ts) }
        if let p = prev, m.ts.timeIntervalSince(p.ts) > 20 * 60 { return "继续对话 · \(recMsgTime(m.ts))" }
        return nil
    }
    private func recMsgTime(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(d) { f.dateFormat = "HH:mm"; return f.string(from: d) }
        if cal.isDateInYesterday(d) { f.dateFormat = "HH:mm"; return "昨天 \(f.string(from: d))" }
        f.dateFormat = "M月d日 HH:mm"; return f.string(from: d)
    }
}

// MARK: - 逐句转录单行（Equatable：长转录性能关键）
//
// 转录可达数千行；若行是 LibraryView 的内联方法，任何 vm.@Published 变更（播放头/录音计时/本场提问态…）
// 都会重渲全部已实例化的行（实测一条 157 行转录在交互时 ~597 行/秒重算）。抽成 Equatable 值视图后，
// 只有「本行 text / 是否高亮当前播放 / 查找词 / 主题」变了才重渲——绝大多数 vm 变更对它是 no-op。
private struct TranscriptLineRow: View, Equatable {
    let lineID: Int
    let start: Double
    let text: String
    let active: Bool
    let query: String        // 查找高亮词；"" = 不在查找
    let pal: Palette
    let onSeek: () -> Void

    // 只比值字段；onSeek 闭包不参与（每次重建但语义不变）。
    static func == (a: TranscriptLineRow, b: TranscriptLineRow) -> Bool {
        a.lineID == b.lineID && a.start == b.start && a.text == b.text
            && a.active == b.active && a.query == b.query && a.pal.isDark == b.pal.isDark
    }

    var body: some View {
        let _ = Perf.body("transcriptRow")
        Button(action: onSeek) {
            HStack(alignment: .top, spacing: 14) {
                Text(mmss(start)).font(.system(size: 11, design: .monospaced)).foregroundStyle(pal.text3).frame(width: 46, alignment: .leading).padding(.top, 2)
                (query.isEmpty ? Text(text) : highlightedText(text, query: query, pal: pal))
                    .font(.system(size: 14)).foregroundStyle(pal.text).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 5)
            .background(active ? pal.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(alignment: .leading) { if active { RoundedRectangle(cornerRadius: 3).fill(pal.accent).frame(width: 3).padding(.vertical, 4) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit).hoverCursor()
    }
}

// MARK: - 本场提问输入栏（本地 @State：键入不写 LibraryModel.@Published，不波及详情/转录）

private struct RecAskInputBar: View {
    let pal: Palette
    let busy: Bool
    let resetToken: String        // 切录音时变化 → 清空草稿
    let onSend: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var canSend: Bool { !busy && !text.trimmingCharacters(in: .whitespaces).isEmpty }
    private func send() { guard canSend else { return }; let q = text; text = ""; onSend(q) }

    var body: some View {
        HStack(spacing: 9) {
            TextField("就这场会议提问…", text: $text)
                .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(pal.text)
                .focused($focused).onSubmit(send).frame(height: 34)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canSend ? .white : pal.text3)
                    .frame(width: 34, height: 34)
                    .background(canSend ? pal.accent : pal.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plainHit).hoverCursor().disabled(!canSend)
        }
        .padding(.leading, 15).padding(.trailing, 6).padding(.vertical, 6)
        .background(pal.elev, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .stroke(pal.borderStrong, corner: 13)
        .onChange(of: resetToken) { _, _ in text = "" }
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

/// 播放器条：独立子视图，观察 `Playhead`（高频 currentTime）。这样 0.25s 的播放头跳动只重绘这一条，
/// 不会波及详情页/长转录列表（父视图只观察 LibraryModel，不读 playhead.time）。
private struct PlayerBar: View {
    @ObservedObject var vm: LibraryModel
    @ObservedObject var playhead: LibraryModel.Playhead
    let sel: RecordingSummary
    let pal: Palette
    var body: some View {
        HStack(spacing: 15) {
            Button { vm.togglePlay() } label: {
                Group {
                    if vm.decodingAudio { Spinner(size: 16, color: .white) }
                    else { Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white) }
                }
                .frame(width: 46, height: 46).background(pal.accent, in: Circle())
            }
            .buttonStyle(.plainHit).hoverCursor().disabled(vm.decodingAudio)
            VStack(spacing: 7) {
                Scrubber(value: playhead.time, total: max(vm.duration, 0.1), pal: pal,
                         onBegin: { vm.scrubBegan() }, onChange: { vm.scrub(to: $0) }, onEnd: { vm.scrubEnded(to: $0) })
                    .frame(height: 18)
                HStack {
                    Text(mmss(playhead.time)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(pal.text2)
                    Spacer()
                    Text(mmss(max(vm.duration, Double(sel.durationSec)))).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(pal.text2)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .card(pal)
    }
}

/// 模板下拉的一行（带 hover 高亮 + 选中勾）。
private struct TplOptionRow: View {
    let name: String
    let active: Bool
    let pal: Palette
    let onPick: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                Text(name).font(.system(size: 12.5, weight: active ? .semibold : .regular)).foregroundStyle(pal.text).lineLimit(1)
                Spacer(minLength: 6)
                if active { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(pal.accent) }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(hover ? pal.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit).hoverCursor()
        .onHover { hover = $0 }
    }
}

/// 放在交互控件背后：让 AppKit 不把这里的 mouseDown 当成「拖动窗口」(window.isMovableByWindowBackground)。
/// `clickable` 时整块区域用 AppKit 原生 cursorUpdate 强制小手指针（比 SwiftUI onHover 更稳，
/// 行是可拖拽的纯视图、SwiftUI hover 易被拖拽手势打断）。
struct WindowDragBlocker: NSViewRepresentable {
    var clickable: Bool = false
    func makeNSView(context: Context) -> NSView { BlockerView(clickable: clickable) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class BlockerView: NSView {
        let clickable: Bool
        init(clickable: Bool) { self.clickable = clickable; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override var mouseDownCanMoveWindow: Bool { false }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            guard clickable else { return }
            addTrackingArea(NSTrackingArea(rect: bounds,
                options: [.activeInActiveApp, .inVisibleRect, .cursorUpdate], owner: self))
        }
        override func cursorUpdate(with event: NSEvent) { if clickable { NSCursor.pointingHand.set() } }
    }
}

/// 放在自绘标题栏背后：让这块区域能拖动窗口。配合 `window.isMovableByWindowBackground = false`，
/// 实现「只有标题栏能拖窗、其余内容区不动窗」。
struct TitlebarDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

// MARK: - 摘要 Markdown 渲染（MarkdownUI，GitHub 风：嵌套列表/表格/代码块齐全）

// Markdown 渲染的统一入口（全 App 7 处调用）。内部走原生 MarkdownNative（swift-markdown 解析 + 自绘 + LazyVStack 虚拟化）。
// Equatable 仍保留：容器（LibraryView / ChatView）因观察 app，在切页 / 侧栏折叠时 body 频繁重跑；
// 文本/主题不变即剪枝、不重建子树。只比 pal.isDark + text/highlight。
struct SummaryMarkdown: View, Equatable {
    let text: String
    let pal: Palette
    var highlight: String = ""   // 保留签名兼容；行内查找高亮交给转录页，摘要走完整 Markdown

    init(text: String, pal: Palette, highlight: String = "") {
        self.text = text; self.pal = pal; self.highlight = highlight
    }

    static func == (a: SummaryMarkdown, b: SummaryMarkdown) -> Bool {
        a.text == b.text && a.highlight == b.highlight && a.pal.isDark == b.pal.isDark
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownNative(text: text, pal: pal)   // 原生渲染（swift-markdown 解析 + 自绘），取代 MarkdownUI
            MarkdownCopyBar(markdown: text, pal: pal)   // 底部两档复制：带样式文本 / 原始 Markdown
        }
    }
}

// 富文本底部复制条：SwiftUI 的 textSelection 无法跨块选择，故给两个显式复制入口。
// 「复制文本」写 RTF（粘到 Notion/Word 保留样式），「复制 Markdown」写原始源码。
private struct MarkdownCopyBar: View {
    let markdown: String
    let pal: Palette
    @State private var copied: Kind? = nil
    private enum Kind { case styled, md }

    var body: some View {
        HStack(spacing: 2) {
            Spacer(minLength: 0)
            button(.styled, icon: "doc.richtext", tip: "复制带样式的文本（粘到 Notion/Word 保留格式）")
            button(.md, icon: "chevron.left.forwardslash.chevron.right", tip: "复制原始 Markdown 源码")
        }
    }

    private func button(_ kind: Kind, icon: String, tip: String) -> some View {
        let done = copied == kind
        return Button {
            switch kind {
            case .styled: RichCopy.styled(markdown)
            case .md:     RichCopy.plain(markdown)
            }
            copied = kind
            Task { try? await Task.sleep(nanoseconds: 1_500_000_000); if copied == kind { copied = nil } }
        } label: {
            Image(systemName: done ? "checkmark" : icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(done ? pal.ok : pal.text3)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit).hoverCursor().help(tip)
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
// DateFormatter / ISO8601DateFormatter 创建昂贵（建 ICU/CFLocale）。提为文件级单例复用：
// 列表行每次 hover/选中/识别状态变更都会重算可见行 body，原来每行现建 3 个 formatter（首屏 3N 个）。
// 全在主线程渲染调用；全局 let 懒初始化且线程安全。
private let isoFmt: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
private let isoFmtFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
private let shortDateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy年M月d日"; f.locale = Locale(identifier: "zh_CN"); return f }()
private let fullDateFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy年M月d日 · HH:mm"; f.locale = Locale(identifier: "zh_CN"); return f }()

private func isoDate(_ iso: String) -> Date? {
    isoFmt.date(from: iso) ?? isoFmtFrac.date(from: iso)
}
func shortDate(_ iso: String) -> String {
    guard let d = isoDate(iso) else { return String(iso.prefix(10)) }
    return shortDateFmt.string(from: d)
}
func fullDate(_ iso: String) -> String {
    guard let d = isoDate(iso) else { return String(iso.prefix(10)) }
    return fullDateFmt.string(from: d)
}
