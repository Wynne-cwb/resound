import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ResoundCore

/// 文档模块主面：左侧列表（搜索 / 标签筛选 / 导入进度 / 文档行 / 空态），
/// 右侧详情（正文渲染 + 元数据 + 关联录音 + 「向本文档提问」）。与 [LibraryView] 对称。
struct DocumentsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var vm: DocumentsModel
    @Environment(\.palette) var pal

    var body: some View {
        let _ = Perf.body("DocumentsView")
        return HStack(spacing: 0) {
            listColumn
            Rectangle().fill(pal.border).frame(width: 1)
            detail
        }
        .onAppear { vm.load() }
    }

    // MARK: 列表列

    private var listColumn: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("文档").font(.system(size: 17, weight: .bold)).foregroundStyle(pal.text)
                    Spacer()
                    Button { vm.openImport() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                            Text("导入").font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white).padding(.leading, 11).padding(.trailing, 13).frame(height: 30)
                        .background(pal.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plainHit).hoverCursor().help("导入文档")
                }
                searchField.padding(.top, 11)
                if !vm.allTags.isEmpty { tagChips.padding(.top, 10) }
            }
            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(vm.importItems) { importRow($0) }
                    let rows = vm.filtered()
                    if rows.isEmpty && vm.importItems.isEmpty { noResults }
                    ForEach(rows) { docRow($0) }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }
        }
        .frame(width: 300)
        .background(pal.sidebar)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text3)
            TextField("搜索文档…", text: $vm.query).textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(pal.text)
            if !vm.query.isEmpty {
                Button { vm.query = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(pal.text3).frame(width: 18, height: 18)
                }.buttonStyle(.plainHit).hoverCursor()
            }
        }
        .padding(.horizontal, 11).frame(height: 34)
        .background(pal.inset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .stroke(pal.border, corner: 9)
    }

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                chip("全部", active: vm.tagFilter == nil) { vm.tagFilter = nil }
                ForEach(vm.allTags, id: \.self) { t in
                    chip(t, active: vm.tagFilter == t) { vm.toggleTagFilter(t) }
                }
            }
        }
    }

    private func chip(_ text: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text).font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(active ? .white : pal.text2)
                .padding(.horizontal, 11).frame(height: 26)
                .background(active ? pal.doc : pal.inset, in: Capsule())
                .overlay(Capsule().strokeBorder(active ? .clear : pal.border, lineWidth: 1))
                .fixedSize()
        }.buttonStyle(.plainHit).hoverCursor()
    }

    private var noResults: some View {
        VStack(spacing: 11) {
            Image(systemName: "magnifyingglass").font(.system(size: 22, weight: .light)).foregroundStyle(pal.text3)
            Text(vm.filterLabel.isEmpty ? "还没有文档" : "没有匹配「\(vm.filterLabel)」的文档")
                .font(.system(size: 13)).foregroundStyle(pal.text2).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 48).padding(.horizontal, 20)
    }

    // MARK: 文档行 / 导入进度行

    private func docRow(_ d: DocumentSummary) -> some View {
        let on = vm.selectedId == d.id
        return Button { vm.select(d.id) } label: {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "doc.text").font(.system(size: 14, weight: .medium)).foregroundStyle(pal.doc).padding(.top, 1)
                VStack(alignment: .leading, spacing: 0) {
                    Text(d.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1)
                    if !d.tags.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(d.tags.prefix(3), id: \.self) { tagPill($0) }
                        }
                        .padding(.top, 6)
                    }
                    HStack(spacing: 7) {
                        Text(monthDay(d.importedAt)).font(.system(size: 11.5)).foregroundStyle(pal.text2)
                        Text("·").font(.system(size: 11)).foregroundStyle(pal.text3)
                        Text(formatLabel(d.sourceFormat)).font(.system(size: 11)).foregroundStyle(pal.text3)
                        if !d.linkedRecordingIds.isEmpty {
                            Spacer(minLength: 6)
                            HStack(spacing: 4) {
                                Image(systemName: "waveform").font(.system(size: 10, weight: .semibold)).foregroundStyle(pal.accent)
                                Text("\(d.linkedRecordingIds.count)").font(.system(size: 11)).foregroundStyle(pal.text2)
                            }
                        }
                    }
                    .padding(.top, 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11).padding(.vertical, 10)
            .background(on ? pal.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .stroke(on ? pal.accent : .clear, corner: 10)
            .overlay(alignment: .topTrailing) {
                if on { RowIconButton(pal: pal, icon: "trash", danger: true) { vm.deleteDocId = d.id }.padding(6) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plainHit).hoverCursor()
    }

    private func tagPill(_ t: String) -> some View {
        Text(t).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(pal.doc)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(pal.docSoft, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func importRow(_ item: DocumentsModel.DocImportItem) -> some View {
        HStack(spacing: 10) {
            ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(pal.docSoft)
                if item.status == .failed { Image(systemName: "exclamationmark.triangle").font(.system(size: 13)).foregroundStyle(pal.warn) }
                else { Spinner(size: 13, color: pal.doc) } }.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1)
                Text(importStatusLabel(item.status))
                    .font(.system(size: 11)).foregroundStyle(item.status == .failed ? pal.rec : pal.doc)
            }
            Spacer()
            if item.status == .failed {
                Button { vm.dismissImportItem(item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(pal.text3).frame(width: 24, height: 24)
                }.buttonStyle(.plainHit).hoverCursor()
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9).card(pal, corner: 10, fill: pal.bg)
    }

    private func importStatusLabel(_ s: DocumentsModel.DocImportItem.Status) -> String {
        switch s {
        case .parsing:  return "解析中…"
        case .tidying:  return "整理排版中…"
        case .indexing: return "建立索引中…"
        case .done:     return "完成"
        case .failed:   return "索引失败"
        }
    }

    // MARK: 详情

    @ViewBuilder private var detail: some View {
        if let d = vm.selected {
            detailScroll(d)
        } else {
            emptyDetail
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 0) {
            ZStack { RoundedRectangle(cornerRadius: 16, style: .continuous).fill(pal.docSoft)
                Image(systemName: "doc.text").font(.system(size: 28, weight: .light)).foregroundStyle(pal.doc) }
                .frame(width: 60, height: 60)
            Text("还没有导入任何文档").font(.system(size: 18, weight: .bold)).foregroundStyle(pal.text).padding(.top, 18)
            Text("导入纯文本或 Markdown，把它和录音关联起来——文档会和你的会议一起，参与 Ask Resound 的全局问答。")
                .font(.system(size: 13.5)).foregroundStyle(pal.text2).multilineTextAlignment(.center).lineSpacing(3)
                .frame(maxWidth: 420).padding(.top, 9)
            Button { vm.openImport() } label: {
                HStack(spacing: 7) { Image(systemName: "plus").font(.system(size: 13, weight: .bold)); Text("导入文档").font(.system(size: 13, weight: .semibold)) }
                    .foregroundStyle(.white).padding(.horizontal, 18).frame(height: 38)
                    .background(pal.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }.buttonStyle(.plainHit).hoverCursor().padding(.top, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding(40).background(pal.bg)
    }

    private func detailScroll(_ d: DocumentSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(d)
                if !d.tags.isEmpty {
                    HStack(spacing: 6) { ForEach(d.tags, id: \.self) { tagPillLarge($0) } }.padding(.top, 13)
                }
                linkedRecordingsCard(d).padding(.top, 20)
                tabBar.padding(.top, 24)
                if vm.tab == .content { contentTab(d) }
                else { docAskTab(d) }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 40).padding(.top, 32).padding(.bottom, 60)
        }
        .background(pal.bg)
    }

    private func header(_ d: DocumentSummary) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    ZStack { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(pal.docSoft)
                        Image(systemName: "doc.text").font(.system(size: 15, weight: .medium)).foregroundStyle(pal.doc) }
                        .frame(width: 30, height: 30)
                    Text(d.title).font(.system(size: 22, weight: .bold)).foregroundStyle(pal.text).lineLimit(1).textSelection(.enabled)
                }
                Text(metaLine(d)).font(.system(size: 13)).foregroundStyle(pal.text2).padding(.top, 7)
            }
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                Button { vm.openEdit(d.id) } label: {
                    HStack(spacing: 6) { Image(systemName: "pencil").font(.system(size: 12, weight: .semibold)); Text("编辑").font(.system(size: 12.5, weight: .semibold)) }
                        .foregroundStyle(pal.text).padding(.horizontal, 13).frame(height: 32)
                        .background(pal.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).stroke(pal.borderStrong, corner: 8)
                }.buttonStyle(.plainHit).hoverCursor().help("编辑标题与标签")
                Button { revealOriginal(d) } label: {
                    Image(systemName: "arrow.up.forward.square").font(.system(size: 14, weight: .medium)).foregroundStyle(pal.text2)
                        .frame(width: 32, height: 32).background(pal.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).stroke(pal.borderStrong, corner: 8)
                }.buttonStyle(.plainHit).hoverCursor().help("在访达中显示原始文件")
                Button { vm.deleteDocId = d.id } label: {
                    Image(systemName: "trash").font(.system(size: 14, weight: .medium)).foregroundStyle(pal.text2)
                        .frame(width: 32, height: 32).background(pal.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).stroke(pal.borderStrong, corner: 8)
                }.buttonStyle(.plainHit).hoverCursor().help("删除文档")
            }
        }
    }

    private func tagPillLarge(_ t: String) -> some View {
        Text(t).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(pal.doc)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(pal.docSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: 关联录音卡

    private func linkedRecordingsCard(_ d: DocumentSummary) -> some View {
        let recs = vm.linkedRecordings
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "waveform").font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.accent)
                Text("关联录音 · \(recs.count)").font(.system(size: 13, weight: .bold)).foregroundStyle(pal.text)
                Spacer()
                Button { vm.openLinkFromDoc() } label: {
                    HStack(spacing: 5) { Image(systemName: "plus").font(.system(size: 11, weight: .bold)); Text("管理").font(.system(size: 12, weight: .semibold)) }
                        .foregroundStyle(pal.text).padding(.horizontal, 11).frame(height: 28)
                        .background(pal.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous)).stroke(pal.borderStrong, corner: 7)
                }.buttonStyle(.plainHit).hoverCursor()
            }
            .padding(.horizontal, 15).padding(.vertical, 12)
            Rectangle().fill(pal.border).frame(height: 1)
            if recs.isEmpty {
                Text("还没有关联录音。点「管理」把相关的会议关联进来——它们会一起参与问答，并出现在答案的引用里。")
                    .font(.system(size: 12.5)).foregroundStyle(pal.text3).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 15).padding(.vertical, 14)
            } else {
                ForEach(recs, id: \.id) { r in linkedRecRow(r) }
            }
        }
        .card(pal, corner: 13)
    }

    private func linkedRecRow(_ r: (id: String, title: String)) -> some View {
        Button { openRecording(r.id) } label: {
            HStack(spacing: 12) {
                ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(pal.accentSoft); WaveMark(pal: pal, height: 12) }.frame(width: 30, height: 30)
                Text(r.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1)
                Spacer(minLength: 8)
                RowIconButton(pal: pal, icon: "xmark", danger: true) { vm.removeLink(r.id) }
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text3)
            }
            .padding(.horizontal, 15).padding(.vertical, 11).contentShape(Rectangle())
        }
        .buttonStyle(.plainHit).hoverCursor()
        .overlay(alignment: .top) { Rectangle().fill(pal.border).frame(height: 1) }
    }

    // MARK: tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabButton("文档", .content); tabButton("向本文档提问", .ask)
        }
        .padding(3).background(pal.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    private func tabButton(_ label: String, _ t: DocumentsModel.DetailTab) -> some View {
        let on = vm.tab == t
        return Button { withAnimation(.easeOut(duration: 0.12)) { vm.tab = t } } label: {
            Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(on ? pal.text : pal.text2)
                .padding(.horizontal, 14).frame(height: 30)
                .background(on ? pal.elev : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .stroke(on ? pal.border : .clear, corner: 8)
        }.buttonStyle(.plainHit).hoverCursor()
    }

    // MARK: 正文 tab

    @ViewBuilder private func contentTab(_ d: DocumentSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if vm.loadingDetail {
                HStack(spacing: 9) { Spinner(size: 15, color: pal.text2); Text("正在载入正文…").font(.system(size: 13)).foregroundStyle(pal.text2) }
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 40)
            } else {
                if let snip = vm.docHighlight {
                    highlightCard(snip).padding(.bottom, 14)
                }
                SummaryMarkdown(text: vm.content ?? "（空文档）", pal: pal)
                    .padding(.horizontal, 30).padding(.vertical, 26)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(pal, corner: 13)
            }
        }
        .padding(.top, 18)
    }

    private func highlightCard(_ snippet: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "quote.opening").font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.doc).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("引用来源").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(pal.doc)
                Text(snippet).font(.system(size: 13)).italic().foregroundStyle(pal.text).lineSpacing(2)
            }
            Spacer(minLength: 8)
            Button { vm.docHighlight = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(pal.text3).frame(width: 22, height: 22)
            }.buttonStyle(.plainHit).hoverCursor()
        }
        .padding(.horizontal, 15).padding(.vertical, 12)
        .background(pal.docSoft, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(pal.doc.opacity(0.4), lineWidth: 1))
    }

    // MARK: 向本文档提问 tab

    @ViewBuilder private func docAskTab(_ d: DocumentSummary) -> some View {
        let msgs = vm.docMsgs
        VStack(alignment: .leading, spacing: 0) {
            if !msgs.isEmpty {
                HStack {
                    Spacer()
                    Button { vm.clearDocChat() } label: {
                        HStack(spacing: 6) { Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold)); Text("重置对话").font(.system(size: 11.5)) }
                            .foregroundStyle(pal.text3).padding(.horizontal, 9).frame(height: 26).contentShape(Rectangle())
                    }.buttonStyle(.plainHit).hoverCursor()
                }.padding(.top, 4)
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(msgs) { m in docMsgView(m) }
                }.padding(.top, 14)
            } else {
                docAskEmpty(d).padding(.top, 8)
            }
            DocAskInputBar(pal: pal, busy: vm.docAskBusy, resetToken: d.id) { vm.askDocument($0) }
                .padding(.top, msgs.isEmpty ? 8 : 20)
            Text("仅检索本篇文档 · 本地模型生成，请核对引用。")
                .font(.system(size: 11)).foregroundStyle(pal.text3).frame(maxWidth: .infinity, alignment: .center).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 18)
    }

    private func docAskEmpty(_ d: DocumentSummary) -> some View {
        VStack(spacing: 0) {
            ZStack { RoundedRectangle(cornerRadius: 11, style: .continuous).fill(pal.docSoft)
                Image(systemName: "doc.text").font(.system(size: 20, weight: .light)).foregroundStyle(pal.doc) }.frame(width: 42, height: 42)
            Text("只在这篇文档里提问").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(pal.text).padding(.top, 12)
            Text("回答只检索本篇文档，并附上原文引用。").font(.system(size: 12.5)).foregroundStyle(pal.text2).multilineTextAlignment(.center).padding(.top, 6)
            HStack(spacing: 8) {
                ForEach(["这篇文档讲了什么？", "有哪些关键决定？"], id: \.self) { q in
                    Button { vm.askDocument(q) } label: {
                        Text(q).font(.system(size: 12.5)).foregroundStyle(pal.text)
                            .padding(.horizontal, 14).frame(height: 32)
                            .background(pal.elev, in: Capsule()).overlay(Capsule().strokeBorder(pal.borderStrong, lineWidth: 1))
                    }.buttonStyle(.plainHit).hoverCursor()
                }
            }.padding(.top, 16)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24)
    }

    @ViewBuilder private func docMsgView(_ m: DocumentsModel.DocAskMsg) -> some View {
        if m.isUser {
            HStack { Spacer(minLength: 50)
                Text(m.full).font(.system(size: 13.5)).foregroundStyle(.white).lineSpacing(2)
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .background(pal.accent, in: UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14, style: .continuous))
                    .frame(maxWidth: 460, alignment: .trailing)
            }
        } else {
            HStack(alignment: .top, spacing: 11) {
                ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(pal.docSoft)
                    Image(systemName: "doc.text").font(.system(size: 13, weight: .medium)).foregroundStyle(pal.doc) }.frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 0) { docAssistantBody(m) }
                Spacer(minLength: 30)
            }
        }
    }

    @ViewBuilder private func docAssistantBody(_ m: DocumentsModel.DocAskMsg) -> some View {
        switch m.phase {
        case .searching, .thinking:
            HStack(spacing: 9) { Spinner(size: 14, color: pal.doc)
                Text(m.phase == .searching ? "正在检索这篇文档…" : "正在阅读相关段落…").font(.system(size: 13)).foregroundStyle(pal.text2) }.frame(height: 22)
        case .empty:
            Text("这篇文档里没有直接相关的内容。换个更具体的说法，或切到「文档」自己翻一翻。")
                .font(.system(size: 13)).foregroundStyle(pal.text2).lineSpacing(3)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(pal.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundStyle(pal.borderStrong))
        case .answering:
            Text(String(m.full.prefix(m.revealed)) + "▍").font(.system(size: 13.5)).foregroundStyle(pal.text).lineSpacing(4).textSelection(.enabled)
        case .done:
            SummaryMarkdown(text: m.full, pal: pal)
            if !m.cites.isEmpty { docCitesView(m) }
        }
    }

    private func docCitesView(_ m: DocumentsModel.DocAskMsg) -> some View {
        let open = vm.docCiteOpen.contains(m.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.14)) { vm.toggleDocCite(m.id) } } label: {
                HStack(spacing: 5) {
                    Text("本篇引用 · \(m.cites.count)").font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(pal.text3)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(pal.text3).rotationEffect(.degrees(open ? 0 : -90))
                }.contentShape(Rectangle())
            }.buttonStyle(.plainHit).hoverCursor()
            if open {
                ForEach(m.cites) { c in
                    Button { vm.docHighlight = c.snippet; vm.tab = .content } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text").font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.doc)
                                Text("文档片段").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(pal.doc)
                            }
                            Text("“\(c.snippet)”").font(.system(size: 12)).italic().foregroundStyle(pal.text2).lineSpacing(1).lineLimit(3)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10).card(pal, corner: 10)
                    }.buttonStyle(.plainHit).hoverCursor()
                }
            }
        }.padding(.top, 13)
    }

    // MARK: 跳转 / 工具

    private func openRecording(_ recId: String) {
        library.select(recId)
        app.page = .library
    }
    private func revealOriginal(_ d: DocumentSummary) {
        NSWorkspace.shared.activateFileViewerSelecting([d.dir])
    }

    // MARK: 显示格式化

    private func formatLabel(_ fmt: String) -> String {
        switch fmt.lowercased() { case "txt", "text": return "纯文本"; case "markdown", "md": return "Markdown"; default: return fmt }
    }
    private func metaLine(_ d: DocumentSummary) -> String {
        var parts = [formatLabel(d.sourceFormat), fullDate(d.importedAt)]
        if let c = vm.content { parts.append(byteSize(c.utf8.count)) }
        return parts.joined(separator: " · ")
    }
    private func monthDay(_ iso: String) -> String {
        guard let date = isoDate(iso) else { return iso }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日"; return f.string(from: date)
    }
    private func fullDate(_ iso: String) -> String {
        guard let date = isoDate(iso) else { return iso }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "yyyy年M月d日 · HH:mm"; return f.string(from: date)
    }
    private func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
    private func byteSize(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        let kb = Double(n) / 1024
        return kb < 1024 ? String(format: "%.1f KB", kb) : String(format: "%.1f MB", kb / 1024)
    }
}

// MARK: - 向本文档提问输入栏（本地 @State：键入不写 DocumentsModel.@Published）

private struct DocAskInputBar: View {
    let pal: Palette
    let busy: Bool
    let resetToken: String
    let onSend: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    private var canSend: Bool { !busy && !text.trimmingCharacters(in: .whitespaces).isEmpty }
    private func send() { guard canSend else { return }; let q = text; text = ""; onSend(q) }

    var body: some View {
        HStack(spacing: 9) {
            TextField("就这篇文档提问…", text: $text)
                .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(pal.text)
                .focused($focused).onSubmit(send).frame(height: 34)
            Button(action: send) {
                Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canSend ? .white : pal.text3).frame(width: 34, height: 34)
                    .background(canSend ? pal.doc : pal.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }.buttonStyle(.plainHit).hoverCursor().disabled(!canSend)
        }
        .padding(.leading, 15).padding(.trailing, 6).padding(.vertical, 6)
        .background(pal.elev, in: RoundedRectangle(cornerRadius: 13, style: .continuous)).stroke(pal.borderStrong, corner: 13)
        .onChange(of: resetToken) { _, _ in text = "" }
    }
}

// MARK: - 导入文档弹窗（自带表单状态：来源 / 标题 / 标签）

struct DocImportModal: View {
    @EnvironmentObject var vm: DocumentsModel
    @Environment(\.palette) var pal
    enum Source { case file, text }
    @State private var source: Source = .file
    @State private var fileURL: URL?
    @State private var bodyText = ""
    @State private var title = ""
    @State private var tags: [String] = []
    @State private var tagDraft = ""

    var body: some View {
        ModalScrim(pal: pal, onClose: { vm.importOpen = false }) {
            VStack(alignment: .leading, spacing: 0) {
                Text("导入文档").font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
                Text("把纯文本或 Markdown 加入知识库。导入后会本地建立索引，并和录音一起参与全局问答。")
                    .font(.system(size: 12.5)).foregroundStyle(pal.text2).lineSpacing(2).padding(.top, 5)

                // 来源切换
                HStack(spacing: 4) {
                    srcTab("选择文件", "doc.text", .file); srcTab("粘贴文本", "text.alignleft", .text)
                }
                .padding(3).background(pal.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).padding(.top, 16)

                if source == .file { fileArea } else { textArea }

                label("标题").padding(.top, 16)
                TextField("文档标题（可自动从文件名 / 首行预填）", text: $title)
                    .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(pal.text)
                    .padding(.horizontal, 13).frame(height: 40).background(pal.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).stroke(pal.borderStrong, corner: 10).padding(.top, 7)

                label("标签 · 选填").padding(.top, 16)
                if !tags.isEmpty { FlowLayout(spacing: 7) { ForEach(tags, id: \.self) { tagChip($0) } }.padding(.top, 8) }
                HStack(spacing: 8) {
                    TextField("输入标签，回车添加", text: $tagDraft)
                        .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(pal.text)
                        .padding(.horizontal, 12).frame(height: 38).background(pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(pal.borderStrong, corner: 9)
                        .onSubmit(addTag)
                    btn("添加", filled: false, action: addTag)
                }.padding(.top, 8)

                HStack(spacing: 9) { Spacer(); btn("取消", filled: false) { vm.importOpen = false }; btn("导入", filled: true, action: doImport) }.padding(.top, 22)
            }
            .frame(width: 540)
        }
    }

    private func srcTab(_ t: String, _ icon: String, _ s: Source) -> some View {
        let on = source == s
        return Button { source = s } label: {
            HStack(spacing: 6) { Image(systemName: icon).font(.system(size: 12, weight: .medium)); Text(t).font(.system(size: 12.5, weight: .semibold)) }
                .foregroundStyle(on ? pal.text : pal.text2).frame(maxWidth: .infinity).frame(height: 30)
                .background(on ? pal.elev : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).stroke(on ? pal.border : .clear, corner: 8)
        }.buttonStyle(.plainHit).hoverCursor()
    }

    @ViewBuilder private var fileArea: some View {
        if let url = fileURL {
            HStack(spacing: 12) {
                ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(pal.docSoft)
                    Image(systemName: "doc.text").font(.system(size: 15)).foregroundStyle(pal.doc) }.frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent).font(.system(size: 13.5, weight: .semibold, design: .monospaced)).foregroundStyle(pal.text).lineLimit(1)
                    HStack(spacing: 4) { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(pal.ok); Text("已选择").font(.system(size: 11.5)).foregroundStyle(pal.ok) }
                }
                Spacer()
                Button(action: pickFile) { Text("更换").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.doc) }.buttonStyle(.plainHit).hoverCursor()
            }
            .padding(.horizontal, 15).padding(.vertical, 13).card(pal, corner: 11, fill: pal.inset).padding(.top, 14)
        } else {
            Button(action: pickFile) {
                VStack(spacing: 0) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 26)).foregroundStyle(pal.doc)
                    Text("点击选择文件").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text).padding(.top, 11)
                    Text("支持 .md · .markdown · .txt").font(.system(size: 11.5)).foregroundStyle(pal.text3).padding(.top, 4)
                }
                .frame(maxWidth: .infinity).padding(26)
                .background(pal.inset, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundStyle(pal.borderStrong))
            }.buttonStyle(.plainHit).hoverCursor().padding(.top, 14)
        }
    }

    private var textArea: some View {
        TextEditor(text: $bodyText)
            .font(.system(size: 13, design: .monospaced)).foregroundStyle(pal.text).scrollContentBackground(.hidden)
            .frame(height: 150).padding(10).background(pal.bg, in: RoundedRectangle(cornerRadius: 11, style: .continuous)).stroke(pal.borderStrong, corner: 11).padding(.top, 14)
            .overlay(alignment: .topLeading) {
                if bodyText.isEmpty {
                    Text("把文档内容粘贴到这里，支持 Markdown。第一行会被用作默认标题。")
                        .font(.system(size: 13)).foregroundStyle(pal.text3).padding(.horizontal, 15).padding(.top, 24).allowsHitTesting(false)
                }
            }
    }

    private func pickFile() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = vm.docImportContentTypes()
        if panel.runModal() == .OK, let url = panel.url {
            fileURL = url
            if title.isEmpty { title = url.deletingPathExtension().lastPathComponent }
        }
    }

    private func addTag() {
        let t = tagDraft.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty, !tags.contains(t) { tags.append(t) }
        tagDraft = ""
    }

    private func doImport() {
        if source == .file {
            guard let url = fileURL else { vm.app?.toast("请先选择文件"); return }
            vm.importFile(title: title, url: url, tags: tags)   // 解析富格式 + 留档真原件
        } else {
            vm.importComposed(title: title, text: bodyText, sourceFormat: "markdown", tags: tags)
        }
    }

    private func label(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(pal.text3)
    }
    private func tagChip(_ t: String) -> some View {
        HStack(spacing: 7) {
            Text(t).font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.doc)
            Button { tags.removeAll { $0 == t } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(pal.doc).frame(width: 15, height: 15) }.buttonStyle(.plainHit).hoverCursor()
        }
        .padding(.leading, 11).padding(.trailing, 5).padding(.vertical, 4)
        .background(pal.docSoft, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    private func btn(_ t: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(filled ? .white : pal.text)
                .padding(.horizontal, 16).frame(height: 34)
                .background(filled ? pal.accent : pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .stroke(filled ? .clear : pal.borderStrong, corner: 9)
        }.buttonStyle(.plainHit).hoverCursor()
    }
}

// MARK: - 关联选择器弹窗（fromDoc 选录音 / fromRec 选文档；staged）

struct DocLinkPickerModal: View {
    @EnvironmentObject var vm: DocumentsModel
    @Environment(\.palette) var pal

    var body: some View {
        ModalScrim(pal: pal, onClose: { vm.cancelLinkPicker() }) {
            VStack(alignment: .leading, spacing: 0) {
                Text(vm.linkPickerTitle).font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
                Text(vm.linkPickerSubtitle).font(.system(size: 12.5)).foregroundStyle(pal.text2).lineSpacing(2).padding(.top, 5)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text3)
                    TextField(vm.linkPickerPlaceholder, text: $vm.linkPickerQuery).textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(pal.text)
                }
                .padding(.horizontal, 12).frame(height: 38).background(pal.inset, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(pal.border, corner: 9).padding(.top, 14)

                ScrollView {
                    VStack(spacing: 4) {
                        if case .fromRec(let recId)? = vm.linkPicker {
                            Button { vm.openImportForRec(recId) } label: {
                                HStack(spacing: 11) {
                                    ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(pal.docSoft)
                                        Image(systemName: "square.and.arrow.up").font(.system(size: 14)).foregroundStyle(pal.doc) }.frame(width: 30, height: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("导入新文档…").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                                        Text("上传文件或粘贴文本，自动关联到本场录音").font(.system(size: 11.5)).foregroundStyle(pal.text2)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 11)
                                .background(pal.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4])).foregroundStyle(pal.borderStrong))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plainHit).hoverCursor()
                        }
                        let items = vm.linkPickerItems()
                        if items.isEmpty {
                            Text("没有可选项").font(.system(size: 13)).foregroundStyle(pal.text3).frame(maxWidth: .infinity).padding(.vertical, 36)
                        }
                        ForEach(items) { pickerRow($0) }
                    }
                }
                .frame(minHeight: 120, maxHeight: 300).padding(.top, 6)

                HStack(spacing: 9) {
                    Text("已选择 \(vm.linkWorking.count) 项").font(.system(size: 12)).foregroundStyle(pal.text3)
                    Spacer()
                    btn("取消", filled: false) { vm.cancelLinkPicker() }
                    btn("完成", filled: true) { vm.saveLinkPicker() }
                }.padding(.top, 18)
            }
            .frame(width: 480)
        }
    }

    private func pickerRow(_ it: DocumentsModel.LinkItem) -> some View {
        let checked = vm.linkWorking.contains(it.id)
        return Button { vm.toggleLinkWorking(it.id) } label: {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(checked ? pal.accent : .clear).frame(width: 18, height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(checked ? pal.accent : pal.borderStrong, lineWidth: 1.5))
                    if checked { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                }
                ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(it.isDoc ? pal.docSoft : pal.accentSoft)
                    if it.isDoc { Image(systemName: "doc.text").font(.system(size: 14)).foregroundStyle(pal.doc) } else { WaveMark(pal: pal, height: 12) } }.frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1)
                    Text(it.sub).font(.system(size: 11.5)).foregroundStyle(pal.text2)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(checked ? pal.accentSoft.opacity(0.5) : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plainHit).hoverCursor()
    }

    private func btn(_ t: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(filled ? .white : pal.text)
                .padding(.horizontal, 16).frame(height: 34)
                .background(filled ? pal.accent : pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(filled ? .clear : pal.borderStrong, corner: 9)
        }.buttonStyle(.plainHit).hoverCursor()
    }
}
