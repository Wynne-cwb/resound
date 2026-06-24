import SwiftUI
import AppKit
import ResoundCore

struct SettingsView: View {
    @EnvironmentObject var vm: SettingsModel
    @Environment(\.palette) var pal

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("设置").font(.system(size: 22, weight: .bold)).foregroundStyle(pal.text)
                Text("所有处理都在这台 Mac 上完成。音频和转录文稿都不会离开你的设备。")
                    .font(.system(size: 13)).foregroundStyle(pal.text2).padding(.top, 4)
                    .padding(.bottom, 4)

                connectionSection

                sectionHeader("权限").padding(.top, 30)
                groupCard { ForEach(vm.permRows) { p in
                    row(last: p.id == vm.permRows.last?.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.label).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                            Text(p.desc).font(.system(size: 12)).foregroundStyle(pal.text2)
                        }
                        Spacer()
                        if p.granted {
                            HStack(spacing: 6) { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)); Text("已授权").font(.system(size: 12.5, weight: .semibold)) }.foregroundStyle(pal.ok)
                        } else {
                            Button { vm.openSystemSettings(p.label) } label: {
                                Text("打开系统设置…").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 14).frame(height: 32)
                                    .background(pal.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }.buttonStyle(.plainHit).hoverCursor()
                        }
                    }
                } }

                sectionHeader("通用").padding(.top, 30)
                groupCard {
                    toggleRow("开机自启", "自动启动 Resound 并保持监听。", $vm.launchAtLogin, last: false)
                    toggleRow("常驻菜单栏", "始终可从 macOS 菜单栏访问。", $vm.menuBarResident, last: false)
                    toggleRow("自动检测会议", "会议开始时主动提示录音。", $vm.autoDetect, last: false)
                    toggleRow("显示录音提醒", "弹出检测提示，而不是静默录音。", $vm.showReminder, last: true)
                }

                vocabSection
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 60)
        }
        .onAppear { vm.load() }
        // 从「系统设置」授权完回到 App 时，实时刷新权限/就绪状态（否则一直显示「打开系统设置…」）
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.refreshStatus()
        }
    }

    // MARK: 词表

    private var vocabSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionHeader("专有词表")
                Spacer()
                if !vm.vocab.isEmpty { addButton("新增词条") { vm.openNewVocab() } }
            }
            .padding(.top, 30)
            Text("填「规范词」让转录更倾向于正确写出它（预防听错）；填「易错变体」会在转录后把这些错误写法自动替换回规范词（兜底纠正）。只填规范词也有效。")
                .font(.system(size: 12)).foregroundStyle(pal.text2).lineSpacing(2).padding(.top, 6)
            if !vm.suggestions.isEmpty { suggestionsInbox }
            if vm.vocab.isEmpty {
                VStack(spacing: 0) {
                    Image(systemName: "character.book.closed").font(.system(size: 30)).foregroundStyle(pal.text3)
                    Text("还没有专有词表").font(.system(size: 15, weight: .semibold)).foregroundStyle(pal.text).padding(.top, 13)
                    Text("把常被转录听错的人名、产品名、项目代号、缩写加进来。例如规范词 Qwen3、易错变体 昆3 —— 转录把它听成「昆3」时会自动纠正回 Qwen3。")
                        .font(.system(size: 13)).foregroundStyle(pal.text2).multilineTextAlignment(.center).lineSpacing(2).frame(maxWidth: 420).padding(.top, 6)
                    addButton("新增第一条词条", filled: true) { vm.openNewVocab() }.padding(.top, 20)
                }
                .frame(maxWidth: .infinity).padding(30)
                .background(pal.inset, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(pal.borderStrong))
                .padding(.top, 11)
            } else {
                if vm.vocab.count > 8 {   // 词条多时给个搜索框 + 定高滚动，避免设置页被撑得很长
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text3)
                        TextField("搜索词条…", text: $vm.vocabFilter)
                            .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(pal.text)
                        if !vm.vocabFilter.isEmpty {
                            Button { vm.vocabFilter = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(pal.text3) }
                                .buttonStyle(.plainHit).hoverCursor()
                        }
                        Text("\(vm.filteredVocab.count)/\(vm.vocab.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(pal.text3)
                    }
                    .padding(.horizontal, 12).frame(height: 36)
                    .background(pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(pal.borderStrong, corner: 9)
                    .padding(.top, 11)
                }
                let items = vm.filteredVocab
                if items.isEmpty {
                    Text("没有匹配「\(vm.vocabFilter)」的词条").font(.system(size: 12.5)).foregroundStyle(pal.text3)
                        .frame(maxWidth: .infinity).padding(.vertical, 20)
                } else {
                    ScrollView {
                        groupCard(topPad: vm.vocab.count > 8 ? 8 : 11) { ForEach(items) { v in
                            row(last: v.id == items.last?.id) {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(v.canonical).font(.system(size: 14, weight: .semibold, design: .monospaced)).foregroundStyle(pal.text)
                                    if v.variants.isEmpty {
                                        Text("仅预防 · 未设易错变体").font(.system(size: 11.5)).foregroundStyle(pal.text3)
                                    } else {
                                        HStack(spacing: 6) {
                                            Text("易错变体").font(.system(size: 11)).foregroundStyle(pal.text3)
                                            ForEach(v.variants, id: \.self) { vr in
                                                Text(vr).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(pal.text2)
                                                    .padding(.horizontal, 9).padding(.vertical, 2)
                                                    .background(pal.inset, in: RoundedRectangle(cornerRadius: 7)).stroke(pal.border, corner: 7)
                                            }
                                        }
                                    }
                                }
                                Spacer()
                                smallIcon("pencil") { vm.openEditVocab(v.id) }
                                smallIcon("trash", danger: true) { vm.confirmVocabDeleteId = v.id }
                            }
                        } }
                    }
                    .frame(maxHeight: vm.vocab.count > 8 ? 360 : .infinity)
                }
            }
        }
    }

    // 智能错词标注：跨录音累计同样的查找替换后，这里一键加入词表（确认即写回 glossary.txt）。
    private var suggestionsInbox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "wand.and.stars").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.accent)
                Text("待确认的词表建议（\(vm.suggestions.count)）").font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.text)
            }
            Text("这些「错→对」更正你已重复做过，确认后会自动维护词表，以后转录直接纠正。").font(.system(size: 11.5)).foregroundStyle(pal.text2).lineSpacing(2)
            VStack(spacing: 0) {
                ForEach(vm.suggestions) { s in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(s.from).font(.system(size: 13, design: .monospaced)).foregroundStyle(pal.text2).strikethrough(color: pal.text3)
                                Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(pal.text3)
                                Text(s.to).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(pal.text)
                            }
                            HStack(spacing: 6) {
                                Text("已更正 \(s.count) 次").font(.system(size: 10.5)).foregroundStyle(pal.text3)
                                Text(s.hardReplace ? "自动替换" : "AI 校对")
                                    .font(.system(size: 10, weight: .medium)).foregroundStyle(pal.accent)
                                    .padding(.horizontal, 7).padding(.vertical, 1.5)
                                    .background(pal.accentSoft, in: Capsule())
                            }
                        }
                        Spacer()
                        Button { vm.dismissSuggestion(s) } label: {
                            Text("忽略").font(.system(size: 12)).foregroundStyle(pal.text2)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(pal.inset, in: Capsule()).overlay(Capsule().strokeBorder(pal.border))
                        }.buttonStyle(.plain).hoverCursor()
                        Button { vm.acceptSuggestion(s) } label: {
                            Text("加入词表").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(pal.accent, in: Capsule())
                        }.buttonStyle(.plain).hoverCursor()
                    }
                    .padding(.vertical, 9)
                    if s.id != vm.suggestions.last?.id { Divider().overlay(pal.border) }
                }
            }
            .padding(.horizontal, 13)
            .background(pal.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(pal.accentSoft, lineWidth: 1))
        }
        .padding(.top, 13)
    }

    // MARK: 连接与模型（可视化配置 + 导入导出）

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionHeader("连接与模型")
                Spacer()
                Button { vm.importConfig() } label: { miniLabel("square.and.arrow.down", "导入") }.buttonStyle(.plainHit).hoverCursor()
                Button { vm.exportConfig() } label: { miniLabel("square.and.arrow.up", "导出") }.buttonStyle(.plainHit).hoverCursor()
            }
            .padding(.top, 30)
            Text("直接在这里填 API，无需改代码重新编译；保存后即时生效。导出可备份/迁移（含密钥，勿外发）。")
                .font(.system(size: 12)).foregroundStyle(pal.text2).lineSpacing(2).padding(.top, 6)

            groupCard {
                fieldRow("Chat API Key", $vm.editConfig.chatKey, secure: true, last: false)
                fieldRow("Chat Base URL", $vm.editConfig.chatBaseURL, last: false)
                fieldRow("Embedding API Key", $vm.editConfig.embeddingKey, secure: true, last: false)
                fieldRow("Embedding Base URL", $vm.editConfig.embeddingBaseURL, last: false)
                toggleRow("在线转写", "开 = 远程 Whisper API；关 = 本地 WhisperKit（首次下模型，较慢）。",
                          $vm.editConfig.transcribeOnline, last: !vm.editConfig.transcribeOnline)
                if vm.editConfig.transcribeOnline {
                    fieldRow("转写模型", $vm.editConfig.transcribeModel, last: false)
                    fieldRow("转写 Base URL", $vm.editConfig.transcribeBaseURL, placeholder: "缺省同 Embedding", last: false)
                    fieldRow("转写 API Key", $vm.editConfig.transcribeKey, secure: true, placeholder: "缺省同 Embedding", last: true)
                }
            }

            groupCard {
                row(last: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("录音库路径").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text)
                        Text(vm.editConfig.vaultPath.isEmpty ? "未设置" : vm.editConfig.vaultPath)
                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(pal.text2)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { vm.pickVaultPath() } label: {
                        Text("选择…").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(pal.elev, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).stroke(pal.borderStrong, corner: 8)
                    }.buttonStyle(.plainHit).hoverCursor()
                }
                toggleRow("自动推送到 git", "录音库是 git 仓库时，处理完自动 commit+push（仅文本派生物，音频不进 git）。",
                          $vm.editConfig.vaultAutoPush, last: true)
            }

            Button { vm.saveConfig() } label: {
                Text("保存配置").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 34)
                    .background(pal.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }.buttonStyle(.plainHit).hoverCursor().padding(.top, 12)
        }
    }

    private func miniLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 11, weight: .semibold)); Text(text).font(.system(size: 12.5, weight: .semibold)) }
            .foregroundStyle(pal.text).padding(.horizontal, 11).frame(height: 30)
            .background(pal.elev, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).stroke(pal.borderStrong, corner: 8)
    }

    private func fieldRow(_ label: String, _ binding: Binding<String>, secure: Bool = false,
                          placeholder: String = "", last: Bool) -> some View {
        row(last: last) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text)
                Group {
                    if secure { SecureField(placeholder, text: binding) } else { TextField(placeholder, text: binding) }
                }
                .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(pal.text)
                .padding(.horizontal, 10).frame(height: 32)
                .background(pal.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous)).stroke(pal.border, corner: 7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 复用件

    private func sectionHeader(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(pal.text3)
    }
    private func groupCard<C: View>(topPad: CGFloat = 11, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }.card(pal).padding(.top, topPad)
    }
    private func row<C: View>(last: Bool, @ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) { content() }.padding(.horizontal, 18).padding(.vertical, 14)
            if !last { Rectangle().fill(pal.border).frame(height: 1) }
        }
    }
    private func toggleRow(_ label: String, _ desc: String, _ binding: Binding<Bool>, last: Bool) -> some View {
        row(last: last) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                Text(desc).font(.system(size: 12)).foregroundStyle(pal.text2)
            }
            Spacer()
            SwitchToggle(on: binding, pal: pal)
        }
    }
    private func addButton(_ label: String, filled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 12, weight: .bold)); Text(label).font(.system(size: filled ? 13 : 12.5, weight: .semibold)) }
                .foregroundStyle(filled ? .white : pal.text)
                .padding(.horizontal, filled ? 16 : 12).frame(height: filled ? 34 : 30)
                .background(filled ? pal.accent : pal.elev, in: RoundedRectangle(cornerRadius: filled ? 9 : 8, style: .continuous))
                .stroke(filled ? .clear : pal.borderStrong, corner: filled ? 9 : 8)
        }
        .buttonStyle(.plainHit).hoverCursor()
    }
    private func smallIcon(_ name: String, danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 12.5)).foregroundStyle(pal.text2).frame(width: 28, height: 28) }
            .buttonStyle(.plainHit).hoverCursor()
    }
}

/// 自绘开关（药丸 + 滑块）。
struct SwitchToggle: View {
    @Binding var on: Bool
    let pal: Palette
    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? pal.accent : pal.borderStrong).frame(width: 42, height: 25)
            Circle().fill(.white).frame(width: 21, height: 21).padding(2).shadow(color: .black.opacity(0.3), radius: 1, y: 1)
        }
        .frame(width: 42, height: 25)
        .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { on.toggle() } }
        .hoverCursor()
    }
}
