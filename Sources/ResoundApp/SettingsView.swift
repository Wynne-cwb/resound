import SwiftUI
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

                sectionHeader("就绪状态").padding(.top, 26)
                groupCard { ForEach(vm.configRows) { r in
                    row(last: r.id == vm.configRows.last?.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.label).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                            Text(r.value).font(.system(size: 12, design: .monospaced)).foregroundStyle(pal.text2).lineLimit(1)
                        }
                        Spacer()
                        badge(r.ok ? "已就绪" : "未配置", ok: r.ok)
                    }
                } }

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

                templatesSection
                vocabSection
            }
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 60)
        }
        .onAppear { vm.load() }
    }

    // MARK: 模板

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionHeader("摘要模板")
                Spacer()
                addButton("新增模板") { vm.openNewTemplate() }
            }
            .padding(.top, 30)
            Text("不同会议适合不同侧重。提示词支持占位符 ")
                .font(.system(size: 12)).foregroundStyle(pal.text2)
            + Text("{date} {title} {speakers} {transcript}").font(.system(size: 12, design: .monospaced)).foregroundStyle(pal.text)
            groupCard(topPad: 11) { ForEach(vm.templates) { t in
                row(last: t.id == vm.templates.last?.id) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(t.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                            if t.id == vm.defaultTplId { Text("默认").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(pal.accent).padding(.horizontal, 8).padding(.vertical, 2).background(pal.accentSoft, in: Capsule()) }
                        }
                        Text(t.prompt.replacingOccurrences(of: "\n", with: " ")).font(.system(size: 12, design: .monospaced)).foregroundStyle(pal.text2).lineLimit(1)
                    }
                    Spacer()
                    if t.id != vm.defaultTplId {
                        Button { vm.setDefaultTemplate(t.id) } label: { Text("设为默认").font(.system(size: 12)).foregroundStyle(pal.text2) }.buttonStyle(.plainHit).hoverCursor()
                    }
                    smallIcon("pencil") { vm.openEditTemplate(t.id) }
                    if vm.canDeleteTemplate { smallIcon("trash", danger: true) { vm.confirmTplDeleteId = t.id } }
                }
            } }
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
                groupCard(topPad: 11) { ForEach(vm.vocab) { v in
                    row(last: v.id == vm.vocab.last?.id) {
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
    private func badge(_ t: String, ok: Bool) -> some View {
        Text(t).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ok ? pal.ok : pal.text2)
            .padding(.horizontal, 11).padding(.vertical, 4)
            .background(ok ? pal.ok.opacity(0.12) : pal.inset, in: Capsule())
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
