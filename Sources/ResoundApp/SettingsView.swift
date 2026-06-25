import SwiftUI
import AppKit
import ResoundCore

struct SettingsView: View {
    @EnvironmentObject var vm: SettingsModel
    @EnvironmentObject var providers: ProvidersModel
    @Environment(\.palette) var pal
    @State private var tab: Tab = .ai

    enum Tab: String, CaseIterable, Identifiable {
        case ai, storage, permissions, general, vocab
        var id: String { rawValue }
        var label: String {
            switch self { case .ai: return "AI 服务"; case .storage: return "存储与同步"; case .permissions: return "权限"; case .general: return "通用"; case .vocab: return "专有词表" }
        }
        var icon: String {
            switch self { case .ai: return "sparkles"; case .storage: return "externaldrive"; case .permissions: return "lock.shield"; case .general: return "gearshape"; case .vocab: return "character.book.closed" }
        }
    }

    var body: some View {
        let _ = Perf.body("SettingsView")
        return VStack(spacing: 0) {
            header
            HStack(spacing: 0) {
                rail
                Rectangle().fill(pal.border).frame(width: 1)
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { vm.load() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in vm.refreshStatus() }
    }

    // MARK: 顶部标题

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("设置").font(.system(size: 21, weight: .bold)).foregroundStyle(pal.text)
            HStack(spacing: 7) {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(pal.ok)
                Text("所有处理都在这台 Mac 上完成。音频和转录文稿都不会离开你的设备。")
                    .font(.system(size: 12.5)).foregroundStyle(pal.text2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 17)
        .overlay(alignment: .bottom) { Rectangle().fill(pal.border).frame(height: 1) }
    }

    // MARK: 左侧子导航

    private var rail: some View {
        VStack(spacing: 3) {
            railRow(.ai, attn: providers.needsOnboarding)
            railRow(.storage)
            railRow(.permissions, attn: vm.needsAttention)
            railRow(.general)
            railRow(.vocab)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 14)
        .frame(width: 206)
        .background(pal.sidebar)
    }

    private func railRow(_ t: Tab, attn: Bool = false) -> some View {
        let on = tab == t
        return Button { tab = t } label: {
            HStack(spacing: 10) {
                Image(systemName: t.icon).font(.system(size: 15, weight: .medium)).frame(width: 18)
                Text(t.label).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                if attn { Circle().fill(pal.warn).frame(width: 7, height: 7) }
            }
            .foregroundStyle(on ? pal.accent : pal.text2)
            .padding(.horizontal, 11).padding(.vertical, 8)
            .background(on ? pal.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }.buttonStyle(.plainHit).hoverCursor()
    }

    // MARK: 右侧内容（单区）

    private var content: some View {
        ScrollView {
            Group {
                switch tab {
                case .ai: ProvidersSection()
                case .storage: StorageContent()
                case .permissions: permissionsContent
                case .general: generalContent
                case .vocab: VocabContent()
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 34).padding(.top, 26).padding(.bottom, 56)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.bg)
    }

    // MARK: 权限

    private var permissionsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("权限", "在「系统设置 → 隐私与安全性」中授权后返回，这里会自动刷新状态。")
            VStack(spacing: 0) {
                ForEach(vm.permRows) { p in
                    HStack(spacing: 14) {
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
                    .padding(.horizontal, 18).padding(.vertical, 14)
                    if p.id != vm.permRows.last?.id { Rectangle().fill(pal.border).frame(height: 1) }
                }
            }
            .background(pal.elev, in: RoundedRectangle(cornerRadius: 13, style: .continuous)).stroke(pal.border, corner: 13)
            .padding(.top, 18)
        }
    }

    // MARK: 通用

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("通用", "这些开关随手即改、立即生效。")
            VStack(spacing: 0) {
                toggleRow("开机自启", "自动启动 Resound 并保持监听。", $vm.launchAtLogin, last: false)
                toggleRow("常驻菜单栏", "始终可从 macOS 菜单栏访问。", $vm.menuBarResident, last: false)
                toggleRow("自动检测会议", "检测到 Google Meet 会议时提示录音；关闭后不再检测。", $vm.autoDetect, last: false)
                toggleRow("自动开始录音", "检测到会议直接开始录音，无需确认；关则弹窗询问。", $vm.autoStartRec, last: false)
                toggleRow("自动停止录音", "会议结束直接停止并转写；关则弹「停止录音？」一键确认。", $vm.autoStopRec, last: true)
            }
            .background(pal.elev, in: RoundedRectangle(cornerRadius: 13, style: .continuous)).stroke(pal.border, corner: 13)
            .padding(.top, 18)
        }
    }

    private func toggleRow(_ label: String, _ desc: String, _ binding: Binding<Bool>, last: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                    Text(desc).font(.system(size: 12)).foregroundStyle(pal.text2)
                }
                Spacer()
                SwitchToggle(on: binding, pal: pal)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            if !last { Rectangle().fill(pal.border).frame(height: 1) }
        }
    }

    private func sectionTitle(_ t: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(t).font(.system(size: 17, weight: .bold)).foregroundStyle(pal.text)
            Text(sub).font(.system(size: 12.5)).foregroundStyle(pal.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 存储与同步（录音库目录 + git 同步，独立子视图：本地 @State 草稿）

private struct StorageContent: View {
    @EnvironmentObject var vm: SettingsModel
    @Environment(\.palette) var pal
    @State private var cfg = SettingsModel.EditConfig()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("存储与同步").font(.system(size: 17, weight: .bold)).foregroundStyle(pal.text)
                Text("录音、转录与索引都保存在你选择的目录中。可选地把它纳入 git 版本管理。")
                    .font(.system(size: 12.5)).foregroundStyle(pal.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }

            label("录音库目录").padding(.top, 20)
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(pal.accentSoft)
                    Image(systemName: "folder").font(.system(size: 18)).foregroundStyle(pal.accent)
                }.frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    if cfg.vaultPath.isEmpty {
                        Text("尚未设置目录").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.warn)
                        Text("选择一个目录后才能开始录音。").font(.system(size: 12)).foregroundStyle(pal.text2)
                    } else {
                        Text(cfg.vaultPath).font(.system(size: 13.5, design: .monospaced)).foregroundStyle(pal.text)
                            .lineLimit(1).truncationMode(.middle)
                        Text("录音、文稿、索引都在这里。").font(.system(size: 12)).foregroundStyle(pal.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { vm.pickVaultPath() } label: {
                    Text("选择目录…").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text)
                        .padding(.horizontal, 14).frame(height: 34)
                        .background(pal.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).stroke(pal.borderStrong, corner: 8)
                }.buttonStyle(.plainHit).hoverCursor()
            }
            .padding(.horizontal, 18).padding(.vertical, 15)
            .background(pal.elev, in: RoundedRectangle(cornerRadius: 13, style: .continuous)).stroke(pal.border, corner: 13)
            .padding(.top, 11)

            label("版本同步").padding(.top, 24)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动推送到 git").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                    Text("每次新增或更新录音后，自动 commit & push 到目录所在的 git 仓库（仅文本，音频不进 git）。")
                        .font(.system(size: 12)).foregroundStyle(pal.text2).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                SwitchToggle(on: $cfg.vaultAutoPush, pal: pal)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .background(pal.elev, in: RoundedRectangle(cornerRadius: 13, style: .continuous)).stroke(pal.border, corner: 13)
            .padding(.top, 11)

            HStack(spacing: 13) {
                Button { vm.saveConfig(cfg) } label: {
                    Text("保存").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).frame(height: 36)
                        .background(pal.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }.buttonStyle(.plainHit).hoverCursor()
                Text("改动即时生效，保存仅把目录变更写入配置。").font(.system(size: 12)).foregroundStyle(pal.text3)
            }
            .padding(.top, 20)
        }
        .onAppear { cfg = vm.editConfig }
        .onChange(of: vm.editConfig) { _, new in cfg = new }
    }

    private func label(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(pal.text3)
    }
}

// MARK: - 专有词表（智能建议收件箱 + 搜索 + 列表，独立子视图：本地 @State 过滤）

private struct VocabContent: View {
    @EnvironmentObject var vm: SettingsModel
    @Environment(\.palette) var pal
    @State private var filter = ""

    private var filtered: [GlossaryEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return vm.vocab }
        return vm.vocab.filter { $0.canonical.lowercased().contains(q) || $0.variants.contains { $0.lowercased().contains(q) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("专有词表").font(.system(size: 17, weight: .bold)).foregroundStyle(pal.text)
                    Text("填「规范词」让转录更倾向于正确写出它（预防听错）；填「易错变体」会在转录后把这些错误写法自动替换回规范词（兜底纠正）。")
                        .font(.system(size: 12.5)).foregroundStyle(pal.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { vm.openNewVocab() } label: {
                    HStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 12, weight: .bold)); Text("新增词条").font(.system(size: 12.5, weight: .semibold)) }
                        .foregroundStyle(.white).padding(.horizontal, 13).frame(height: 32)
                        .background(pal.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }.buttonStyle(.plainHit).hoverCursor()
            }

            if !vm.suggestions.isEmpty { suggestionsInbox.padding(.top, 18) }

            if vm.vocab.isEmpty {
                emptyState.padding(.top, 18)
            } else {
                if vm.vocab.count > 8 { searchBar.padding(.top, 18) }
                let list = filtered
                if list.isEmpty {
                    Text("没有匹配「\(filter)」的词条")
                        .font(.system(size: 13)).foregroundStyle(pal.text2).frame(maxWidth: .infinity).multilineTextAlignment(.center)
                        .padding(26).background(pal.inset, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(pal.borderStrong))
                        .padding(.top, 14)
                } else {
                    VStack(spacing: 0) {
                        ForEach(list) { v in
                            vocabRow(v)
                            if v.id != list.last?.id { Rectangle().fill(pal.border).frame(height: 1) }
                        }
                    }
                    .background(pal.elev, in: RoundedRectangle(cornerRadius: 13, style: .continuous)).stroke(pal.border, corner: 13)
                    .padding(.top, 14)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.text3)
            TextField("在 \(vm.vocab.count) 条词条中搜索…", text: $filter)
                .textFieldStyle(.plain).font(.system(size: 13.5)).foregroundStyle(pal.text)
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(pal.text3) }
                    .buttonStyle(.plainHit).hoverCursor()
            }
        }
        .padding(.horizontal, 12).frame(height: 38)
        .background(pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(pal.borderStrong, corner: 9)
    }

    private func vocabRow(_ v: GlossaryEntry) -> some View {
        HStack(spacing: 12) {
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
            iconBtn("pencil") { vm.openEditVocab(v.id) }
            iconBtn("trash", danger: true) { vm.confirmVocabDeleteId = v.id }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func iconBtn(_ name: String, danger: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 13)).foregroundStyle(pal.text2).frame(width: 28, height: 28) }
            .buttonStyle(.plainHit).hoverCursor()
    }

    private var emptyState: some View {
        VStack(spacing: 0) {
            Image(systemName: "character.book.closed").font(.system(size: 30)).foregroundStyle(pal.text3)
            Text("还没有专有词表").font(.system(size: 15, weight: .semibold)).foregroundStyle(pal.text).padding(.top, 13)
            Text("把常被转录听错的人名、产品名、项目代号、缩写加进来。例如规范词 Qwen3、易错变体 昆3 —— 转录把它听成「昆3」时会自动纠正回 Qwen3。")
                .font(.system(size: 13)).foregroundStyle(pal.text2).multilineTextAlignment(.center).lineSpacing(2).frame(maxWidth: 420).padding(.top, 6)
            Button { vm.openNewVocab() } label: {
                HStack(spacing: 7) { Image(systemName: "plus").font(.system(size: 12, weight: .bold)); Text("新增第一条词条").font(.system(size: 13, weight: .semibold)) }
                    .foregroundStyle(.white).padding(.horizontal, 16).frame(height: 34)
                    .background(pal.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }.buttonStyle(.plainHit).hoverCursor().padding(.top, 20)
        }
        .frame(maxWidth: .infinity).padding(30)
        .background(pal.inset, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(pal.borderStrong))
    }

    // 智能错词标注收件箱
    private var suggestionsInbox: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "wand.and.stars").font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.accent)
                Text("智能建议").font(.system(size: 13, weight: .bold)).foregroundStyle(pal.text)
                Text("\(vm.suggestions.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.accent)
                    .padding(.horizontal, 9).padding(.vertical, 2).background(pal.bg, in: Capsule())
                Spacer()
                Text("检测到你反复手动做过的更正").font(.system(size: 11.5)).foregroundStyle(pal.text2)
            }
            .padding(.horizontal, 16).padding(.vertical, 13).background(pal.accentSoft)
            ForEach(vm.suggestions) { s in
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 9) {
                            Text(s.from).font(.system(size: 13.5, design: .monospaced)).foregroundStyle(pal.text3).strikethrough(color: pal.text3)
                            Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(pal.text3)
                            Text(s.to).font(.system(size: 13.5, weight: .semibold, design: .monospaced)).foregroundStyle(pal.text)
                        }
                        HStack(spacing: 8) {
                            Text(s.hardReplace ? "自动替换" : "AI 校对")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(pal.accent)
                                .padding(.horizontal, 7).padding(.vertical, 1.5).background(pal.accentSoft, in: Capsule())
                            Text("已更正 \(s.count) 次").font(.system(size: 11)).foregroundStyle(pal.text3)
                        }
                    }
                    Spacer()
                    Button { vm.acceptSuggestion(s) } label: {
                        HStack(spacing: 5) { Image(systemName: "plus").font(.system(size: 11, weight: .bold)); Text("加入词表").font(.system(size: 12, weight: .semibold)) }
                            .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 30).background(pal.accent, in: Capsule())
                    }.buttonStyle(.plainHit).hoverCursor()
                    Button { vm.dismissSuggestion(s) } label: {
                        Text("忽略").font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text2).padding(.horizontal, 11).frame(height: 30)
                    }.buttonStyle(.plainHit).hoverCursor()
                }
                .padding(.horizontal, 16).padding(.vertical, 13)
                .overlay(alignment: .top) { Rectangle().fill(pal.border).frame(height: 1) }
            }
        }
        .background(pal.elev, in: RoundedRectangle(cornerRadius: 13, style: .continuous)).stroke(pal.border, corner: 13)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
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
