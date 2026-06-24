import SwiftUI
import ResoundCore

/// 全窗范围的浮层：会议检测弹窗、各类模态、toast。挂在 RootView 顶层，覆盖侧栏+内容。
struct OverlayHost: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var rec: RecordingController
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var settings: SettingsModel
    @EnvironmentObject var chat: ChatVM
    @Environment(\.palette) var pal

    var body: some View {
        ZStack {
            speakerModal
            renameRecModal
            deleteRecModal
            templateEditor
            templateDeleteModal
            vocabEditor
            vocabDeleteModal
            importModal
            folderEditorModal
            folderDeleteModal
            sessionRenameModal
            sessionDeleteModal
            toast
        }
        .animation(.easeOut(duration: 0.16), value: app.toastText)
    }

    // MARK: 对话（Ask 历史）

    @ViewBuilder private var sessionRenameModal: some View {
        if chat.renameSession != nil {
            ModalScrim(pal: pal, onClose: { chat.renameSession = nil }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("重命名对话").font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
                    TextField("对话名称", text: Binding(get: { chat.renameSession?.value ?? "" }, set: { chat.renameSession?.value = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(pal.text)
                        .padding(.horizontal, 13).frame(height: 40).background(pal.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).stroke(pal.borderStrong, corner: 10)
                        .padding(.top, 15).onSubmit { chat.saveRenameSession() }
                    HStack(spacing: 9) { Spacer(); secondaryBtn("取消") { chat.renameSession = nil }; primaryBtn("保存") { chat.saveRenameSession() } }.padding(.top, 20)
                }
                .frame(width: 380)
            }
        }
    }

    @ViewBuilder private var sessionDeleteModal: some View {
        if chat.confirmDeleteSessionId != nil {
            ModalScrim(pal: pal, onClose: { chat.confirmDeleteSessionId = nil }) {
                confirmCard(title: "删除这段对话？",
                            message: AttributedString("对话记录会被永久删除，相关的录音和转录不受影响。"),
                            confirm: "删除", onCancel: { chat.confirmDeleteSessionId = nil }, onConfirm: { chat.confirmDeleteSession() })
            }
        }
    }

    // MARK: 说话人命名

    @ViewBuilder private var speakerModal: some View {
        if let st = library.renameSpeaker {
            ModalScrim(pal: pal, onClose: { library.renameSpeaker = nil }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(st.isAnon ? "认领并命名说话人" : "重新分配说话人").font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
                    if st.isAnon {
                        (Text("当前标签 ").foregroundStyle(pal.text2) + Text(st.label).foregroundStyle(pal.text).fontWeight(.semibold) + Text(" —— 命名后，整篇转录里 TA 的所有句子会立即换成真名。").foregroundStyle(pal.text2))
                            .font(.system(size: 12.5)).lineSpacing(2).padding(.top, 6)
                    } else {
                        (Text("当前识别为 ").foregroundStyle(pal.text2) + Text(st.label).foregroundStyle(pal.text).fontWeight(.semibold) + Text(" 。如果认错了，输入正确的人名重新分配 —— 这只改这条录音的标注，").foregroundStyle(pal.text2) + Text("不会改动「\(st.label)」已记住的声音。").foregroundStyle(pal.text).fontWeight(.semibold))
                            .font(.system(size: 12.5)).lineSpacing(2).padding(.top, 6)
                    }
                    TextField("输入真实人名，例如 张三", text: Binding(get: { library.renameSpeaker?.value ?? "" }, set: { library.renameSpeaker?.value = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(pal.text)
                        .padding(.horizontal, 13).frame(height: 40).background(pal.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).stroke(pal.borderStrong, corner: 10)
                        .padding(.top, 15).onSubmit { library.saveRenameSpeaker() }
                    peoplePicker(current: st.value)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "person.crop.circle").font(.system(size: 16)).foregroundStyle(pal.accent)
                        (st.isAnon
                            ? (Text("这不只是改这一条录音。Resound 会记住 TA 的声音特征，").foregroundStyle(pal.text) + Text("以后的新录音里再出现同一个人，会被自动认出并标上真名。").foregroundStyle(pal.text).fontWeight(.semibold))
                            : (Text("把 TA 登记为一个**新的**说话人并记住声音，").foregroundStyle(pal.text) + Text("以后自动认出 —— 原来那个人的声纹完全不受影响。").foregroundStyle(pal.text).fontWeight(.semibold)))
                            .font(.system(size: 12)).lineSpacing(2)
                    }
                    .padding(.horizontal, 13).padding(.vertical, 11).background(pal.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).padding(.top, 13)
                    HStack(spacing: 9) {
                        CheckBox(on: Binding(get: { library.renameSpeaker?.remember ?? false }, set: { library.renameSpeaker?.remember = $0 }), pal: pal)
                        Text(st.isAnon ? "记住这个声音，在以后的录音中自动识别" : "记住正确的人的声音，以后自动认出").font(.system(size: 12.5)).foregroundStyle(pal.text2)
                    }.padding(.top, 13)
                    HStack(spacing: 9) {
                        if !st.isAnon {
                            Button { library.resetSpeaker() } label: { Text("恢复为匿名").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text2) }.buttonStyle(.plainHit).hoverCursor()
                            Spacer()
                        } else { Spacer() }
                        secondaryBtn("取消") { library.renameSpeaker = nil }
                        primaryBtn("保存") { library.saveRenameSpeaker() }
                    }.padding(.top, 20)
                }
                .frame(width: 380)
            }
        }
    }

    // MARK: 录音改名

    @ViewBuilder private var renameRecModal: some View {
        if library.renameRec != nil {
            ModalScrim(pal: pal, onClose: { library.renameRec = nil }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("重命名录音").font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
                    TextField("标题", text: Binding(get: { library.renameRec?.value ?? "" }, set: { library.renameRec?.value = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(pal.text)
                        .padding(.horizontal, 13).frame(height: 40).background(pal.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).stroke(pal.borderStrong, corner: 10)
                        .padding(.top, 15).onSubmit { library.saveRenameRec() }
                    HStack(spacing: 9) { Spacer(); secondaryBtn("取消") { library.renameRec = nil }; primaryBtn("保存") { library.saveRenameRec() } }.padding(.top, 20)
                }
                .frame(width: 380)
            }
        }
    }

    @ViewBuilder private var deleteRecModal: some View {
        if let id = library.deleteRecId {
            let title = library.recordings.first { $0.id == id }?.title ?? ""
            ModalScrim(pal: pal, onClose: { library.deleteRecId = nil }) {
                confirmCard(title: "删除录音？",
                            message: AttributedString(title) + AttributedString(" 及其转录文稿将从你的录音库中永久删除。此操作无法撤销。"),
                            confirm: "删除", onCancel: { library.deleteRecId = nil }, onConfirm: { library.confirmDeleteRec() })
            }
        }
    }

    // MARK: 模板编辑

    @ViewBuilder private var templateEditor: some View {
        if let e = settings.editTpl {
            ModalScrim(pal: pal, onClose: { settings.editTpl = nil }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.tplId == nil ? "新增模板" : "编辑模板").font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
                    fieldLabel("名称").padding(.top, 18)
                    TextField("例如 客户会议", text: Binding(get: { settings.editTpl?.name ?? "" }, set: { settings.editTpl?.name = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(pal.text)
                        .padding(.horizontal, 13).frame(height: 40).background(pal.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).stroke(pal.borderStrong, corner: 10).padding(.top, 7)
                    fieldLabel("提示词").padding(.top, 16)
                    TextEditor(text: Binding(get: { settings.editTpl?.prompt ?? "" }, set: { settings.editTpl?.prompt = $0 }))
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(pal.text).scrollContentBackground(.hidden)
                        .frame(height: 160).padding(8).background(pal.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).stroke(pal.borderStrong, corner: 10).padding(.top, 7)
                    HStack(spacing: 7) {
                        Text("插入占位符：").font(.system(size: 11.5)).foregroundStyle(pal.text2)
                        ForEach(settings.placeholders, id: \.self) { ph in
                            Button { settings.insertPlaceholder(ph) } label: {
                                Text(ph).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(pal.accent)
                                    .padding(.horizontal, 9).padding(.vertical, 3).background(pal.accentSoft, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plainHit).hoverCursor()
                        }
                    }.padding(.top, 11)
                    aiAssistBox.padding(.top, 16)
                    HStack(spacing: 9) { Spacer(); secondaryBtn("取消") { settings.editTpl = nil }; primaryBtn("保存模板") { settings.saveTemplate() } }.padding(.top, 22)
                }
                .frame(width: 520)
            }
        }
    }

    /// 模板编辑器里的「AI 协助」区：描述用途 → 生成 / 润色提示词（结果自带内置占位符）。
    @ViewBuilder private var aiAssistBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 14, weight: .semibold)).foregroundStyle(pal.accent)
                Text("AI 协助").font(.system(size: 12.5, weight: .bold)).foregroundStyle(pal.text)
                Text("描述用途即可生成，或一键润色当前提示词").font(.system(size: 11.5)).foregroundStyle(pal.text2)
            }
            TextEditor(text: Binding(get: { settings.editTpl?.aiIntent ?? "" }, set: { settings.editTpl?.aiIntent = $0 }))
                .font(.system(size: 13)).foregroundStyle(pal.text).scrollContentBackground(.hidden)
                .frame(height: 58).padding(8)
                .background(pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(pal.borderStrong, corner: 9)
                .padding(.top, 11)
                .overlay(alignment: .topLeading) {
                    if (settings.editTpl?.aiIntent ?? "").isEmpty {
                        Text("这个模板用于什么会议？例如：客户访谈，重点提炼需求与异议，并整理出明确的跟进项")
                            .font(.system(size: 13)).foregroundStyle(pal.text3).padding(.horizontal, 13).padding(.top, 19).allowsHitTesting(false)
                    }
                }
            if settings.aiBusy {
                HStack(spacing: 9) { Spinner(size: 14, color: pal.accent); Text("AI 正在撰写提示词…").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.accent) }
                    .frame(height: 36).padding(.top, 11)
            } else {
                HStack(spacing: 8) {
                    Button { settings.aiAssist(.generate) } label: {
                        HStack(spacing: 6) { Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold)); Text("生成提示词").font(.system(size: 12.5, weight: .semibold)) }
                            .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 36)
                            .background(pal.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }.buttonStyle(.plainHit).hoverCursor()
                    Button { settings.aiAssist(.polish) } label: {
                        HStack(spacing: 6) { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 12, weight: .semibold)); Text("润色当前").font(.system(size: 12.5, weight: .semibold)) }
                            .foregroundStyle(pal.text).padding(.horizontal, 14).frame(height: 36)
                            .background(pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(pal.borderStrong, corner: 9)
                    }.buttonStyle(.plainHit).hoverCursor()
                }.padding(.top, 11)
            }
        }
        .padding(13)
        .background(pal.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var templateDeleteModal: some View {
        if let id = settings.confirmTplDeleteId {
            let name = settings.templates.first { $0.id == id }?.name ?? ""
            ModalScrim(pal: pal, onClose: { settings.confirmTplDeleteId = nil }) {
                confirmCard(title: "删除模板？",
                            message: AttributedString("将删除模板 ") + AttributedString(name) + AttributedString("。已用它生成的摘要不受影响，但下次需要时要重新选择模板。"),
                            confirm: "删除", onCancel: { settings.confirmTplDeleteId = nil }, onConfirm: { settings.confirmDeleteTemplate() })
            }
        }
    }

    // MARK: 词条编辑

    @ViewBuilder private var vocabEditor: some View {
        if let e = settings.editVocab {
            ModalScrim(pal: pal, onClose: { settings.editVocab = nil }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.vocabId == nil ? "新增词条" : "编辑词条").font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
                    fieldLabel("规范词 · 必填").padding(.top, 18)
                    TextField("正确写法，例如 Qwen3", text: Binding(get: { settings.editVocab?.canonical ?? "" }, set: { settings.editVocab?.canonical = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 14, design: .monospaced)).foregroundStyle(pal.text)
                        .padding(.horizontal, 13).frame(height: 40).background(pal.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).stroke(pal.borderStrong, corner: 10).padding(.top, 7)
                    fieldLabel("易错变体 · 选填").padding(.top, 16)
                    Text("这个词常被转录成的错误写法。转录后会被自动替换回规范词。").font(.system(size: 12)).foregroundStyle(pal.text2).padding(.top, 5)
                    if !e.variants.isEmpty {
                        WrapVariants(variants: e.variants, pal: pal) { settings.removeVariant($0) }.padding(.top, 11)
                    }
                    HStack(spacing: 8) {
                        TextField("输入一个易错写法，回车添加", text: Binding(get: { settings.editVocab?.draft ?? "" }, set: { settings.editVocab?.draft = $0 }))
                            .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(pal.text)
                            .padding(.horizontal, 12).frame(height: 38).background(pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(pal.borderStrong, corner: 9)
                            .onSubmit { settings.addVariant() }
                        secondaryBtn("添加") { settings.addVariant() }
                    }.padding(.top, 11)
                    HStack(spacing: 9) { Spacer(); secondaryBtn("取消") { settings.editVocab = nil }; primaryBtn("保存词条") { settings.saveVocab() } }.padding(.top, 22)
                }
                .frame(width: 460)
            }
        }
    }

    @ViewBuilder private var vocabDeleteModal: some View {
        if let id = settings.confirmVocabDeleteId {
            let name = settings.vocab.first { $0.id == id }?.canonical ?? ""
            ModalScrim(pal: pal, onClose: { settings.confirmVocabDeleteId = nil }) {
                confirmCard(title: "删除词条？",
                            message: AttributedString("将从专有词表中删除 ") + AttributedString(name) + AttributedString(" 及其全部易错变体。"),
                            confirm: "删除", onCancel: { settings.confirmVocabDeleteId = nil }, onConfirm: { settings.confirmDeleteVocab() })
            }
        }
    }

    // MARK: 导入

    @ViewBuilder private var importModal: some View {
        if library.importOpen {
            ModalScrim(pal: pal, onClose: { library.cancelImport() }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("导入录音文件").font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
                    Text("一次选择多个音频文件，Resound 会逐个本地转写、分离说话人并加入录音库。").font(.system(size: 12.5)).foregroundStyle(pal.text2).lineSpacing(2).padding(.top, 5)
                    Button { library.pickFiles() } label: {
                        VStack(spacing: 0) {
                            Image(systemName: "square.and.arrow.up").font(.system(size: 28)).foregroundStyle(pal.accent)
                            Text("点击选择文件").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text).padding(.top, 11)
                            Text("支持 .m4a · .mp3 · .wav · .aac —— 可多选").font(.system(size: 11.5)).foregroundStyle(pal.text3).padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity).padding(26)
                        .background(pal.inset, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundStyle(pal.borderStrong))
                    }.buttonStyle(.plainHit).hoverCursor().padding(.top, 16)
                    if !library.importItems.isEmpty {
                        HStack {
                            Text("已选 \(library.importItems.count) 个文件").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(pal.text2)
                            Spacer()
                            if !library.importing {
                                Button { library.importItems = [] } label: {
                                    Text("清空").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(pal.text3)
                                }.buttonStyle(.plainHit).hoverCursor()
                            }
                        }.padding(.top, 16)
                        // 少文件直接铺行、卡片贴合内容（避免被贪婪 ScrollView 撑满整屏）；多文件才套定高滚动。
                        let rows = VStack(spacing: 7) { ForEach(library.importItems) { f in importRow(f) } }
                        if library.importItems.count > 5 {
                            ScrollView { rows }.frame(height: 300).padding(.top, 8)
                        } else {
                            rows.padding(.top, 8)
                        }
                    }
                    HStack(spacing: 9) {
                        Spacer()
                        secondaryBtn("取消") { library.cancelImport() }
                        if library.importing {
                            HStack(spacing: 8) { Spinner(size: 13, color: .white); Text(importLabel).font(.system(size: 13, weight: .semibold)) }
                                .foregroundStyle(.white).padding(.horizontal, 16).frame(height: 34).background(pal.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        } else if !library.importItems.isEmpty {
                            primaryBtn(importLabel) { library.startImport() }
                        }
                    }.padding(.top, 22)
                }
                .frame(width: 520)
            }
        }
    }

    private var importLabel: String {
        let done = library.importItems.filter { $0.status == .done }.count
        return library.importing ? "正在导入… \(done)/\(library.importItems.count)" : "导入 \(library.importItems.count) 个文件"
    }

    private func importRow(_ f: LibraryModel.ImportItem) -> some View {
        let labels: [LibraryModel.ImportItem.Status: String] = [.queued: "等待中", .transcribing: "转写中…", .identifying: "识别说话人…", .done: "完成", .failed: "失败"]
        let working = f.status == .transcribing || f.status == .identifying
        return HStack(spacing: 11) {
            ZStack { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(pal.accentSoft); WaveMark(pal: pal, height: 12) }.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) { Text(f.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.text).lineLimit(1) }
            Spacer()
            Text(labels[f.status] ?? "").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(f.status == .done ? pal.ok : (working ? pal.accent : (f.status == .failed ? pal.rec : pal.text3)))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(f.status == .done ? pal.ok.opacity(0.12) : (working ? pal.accentSoft : pal.inset), in: Capsule())
            if !library.importing && f.status == .queued {
                Button { library.removeImport(f.id) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(pal.text3).frame(width: 24, height: 24) }.buttonStyle(.plainHit).hoverCursor()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10).card(pal, corner: 10, fill: pal.bg)
    }

    // MARK: 文件夹

    @ViewBuilder private var folderEditorModal: some View {
        if let e = library.folderEditor {
            ModalScrim(pal: pal, onClose: { library.folderEditor = nil }) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(e.folderId == nil ? "新建文件夹" : "重命名文件夹").font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
                    TextField("文件夹名称，例如 工作 / 1:1", text: Binding(get: { library.folderEditor?.name ?? "" }, set: { library.folderEditor?.name = $0 }))
                        .textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(pal.text)
                        .padding(.horizontal, 13).frame(height: 40).background(pal.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).stroke(pal.borderStrong, corner: 10)
                        .padding(.top, 15).onSubmit { library.saveFolder() }
                    HStack(spacing: 9) { Spacer(); secondaryBtn("取消") { library.folderEditor = nil }; primaryBtn("保存") { library.saveFolder() } }.padding(.top, 20)
                }
                .frame(width: 380)
            }
        }
    }

    @ViewBuilder private var folderDeleteModal: some View {
        if let id = library.confirmDeleteFolderId {
            let name = library.folders.first { $0.id == id }?.name ?? ""
            ModalScrim(pal: pal, onClose: { library.confirmDeleteFolderId = nil }) {
                confirmCard(title: "删除文件夹？",
                            message: AttributedString("将删除文件夹 ") + AttributedString(name) + AttributedString("。里面的录音不会被删除，会回到「未分类」。"),
                            confirm: "删除", onCancel: { library.confirmDeleteFolderId = nil }, onConfirm: { library.confirmDeleteFolder() })
            }
        }
    }

    // MARK: toast

    @ViewBuilder private var toast: some View {
        if let t = app.toastText {
            VStack { Spacer()
                HStack(spacing: 9) { Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(pal.ok); Text(t).font(.system(size: 13, weight: .medium)) }
                    .foregroundStyle(pal.toastText).padding(.horizontal, 18).padding(.vertical, 11)
                    .background(pal.toastBg, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    .padding(.bottom, 26)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: 复用件

    /// 已标注人名的可选列表（输入时模糊过滤；点选填入）。
    @ViewBuilder private func peoplePicker(current: String) -> some View {
        let matches = library.suggestedPeople(for: current)
        if !matches.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("已标注的人 · 点选直接填入").font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.text3)
                FlowLayout(spacing: 7) {
                    ForEach(matches.prefix(16), id: \.self) { p in
                        let sel = p == current
                        Button { library.renameSpeaker?.value = p } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "person.fill").font(.system(size: 9))
                                Text(p).font(.system(size: 12.5, weight: .medium))
                            }
                            .foregroundStyle(sel ? .white : pal.text)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(sel ? pal.accent : pal.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .stroke(sel ? .clear : pal.border, corner: 8)
                        }
                        .buttonStyle(.plainHit).hoverCursor()
                    }
                }
            }
            .padding(.top, 12)
        }
    }

    @ViewBuilder private func confirmCard(title: String, message: AttributedString, confirm: String, onCancel: @escaping () -> Void, onConfirm: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
            Text(message).font(.system(size: 13)).foregroundStyle(pal.text2).lineSpacing(2).padding(.top, 8)
            HStack(spacing: 9) { Spacer(); secondaryBtn("取消", action: onCancel); dangerBtn(confirm, action: onConfirm) }.padding(.top, 20)
        }
        .frame(width: 380)
    }
    private func fieldLabel(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(pal.text3)
    }
    private func primaryBtn(_ t: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 16).frame(height: 34).background(pal.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous)) }.buttonStyle(.plainHit).hoverCursor()
    }
    private func secondaryBtn(_ t: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.text).padding(.horizontal, 16).frame(height: 34).background(pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(pal.borderStrong, corner: 9) }.buttonStyle(.plainHit).hoverCursor()
    }
    private func dangerBtn(_ t: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(t).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 16).frame(height: 34).background(pal.rec, in: RoundedRectangle(cornerRadius: 9, style: .continuous)) }.buttonStyle(.plainHit).hoverCursor()
    }
}

/// 居中模态：半透明背景 + 卡片；点背景关闭。
struct ModalScrim<Content: View>: View {
    let pal: Palette
    let onClose: () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        ZStack {
            Color.black.opacity(0.32).ignoresSafeArea().onTapGesture(perform: onClose)
            content
                .padding(22)
                .background(pal.elev, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .stroke(pal.borderStrong, corner: 16)
        }
        .transition(.opacity)
    }
}

struct CheckBox: View {
    @Binding var on: Bool
    let pal: Palette
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? pal.accent : .clear).frame(width: 18, height: 18)
                .stroke(on ? pal.accent : pal.borderStrong, corner: 5, width: 1.5)
            if on { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
        }
        .onTapGesture { on.toggle() }.hoverCursor()
    }
}

/// 易错变体的换行标签流。
struct WrapVariants: View {
    let variants: [String]
    let pal: Palette
    let onRemove: (Int) -> Void
    var body: some View {
        FlowLayout(spacing: 7) {
            ForEach(Array(variants.enumerated()), id: \.offset) { i, v in
                HStack(spacing: 7) {
                    Text(v).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(pal.text)
                    Button { onRemove(i) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(pal.text3) }.buttonStyle(.plainHit).hoverCursor()
                }
                .padding(.leading, 11).padding(.trailing, 8).padding(.vertical, 5)
                .background(pal.inset, in: RoundedRectangle(cornerRadius: 8)).stroke(pal.border, corner: 8)
            }
        }
    }
}

/// 简单流式布局（标签换行）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 7
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
