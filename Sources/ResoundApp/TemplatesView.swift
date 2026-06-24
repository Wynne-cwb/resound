import SwiftUI
import ResoundCore

/// 摘要模板页（侧栏导航独立页）：卡片网格展示每个模板的提示词预览 + 占位符 + 编辑/设默认/删除。
/// 模板 CRUD 状态仍复用 SettingsModel（与设置页共享一份）。
struct TemplatesView: View {
    @EnvironmentObject var settings: SettingsModel
    @Environment(\.palette) var pal

    private let cols = [GridItem(.flexible(), spacing: 15), GridItem(.flexible(), spacing: 15)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.bottom, 26)
                LazyVGrid(columns: cols, spacing: 15) {
                    ForEach(settings.templates) { t in card(t) }
                    addCard
                }
            }
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 40).padding(.top, 34).padding(.bottom, 60)
        }
        .onAppear { if settings.templates.isEmpty { settings.load() } }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("摘要模板").font(.system(size: 22, weight: .bold)).foregroundStyle(pal.text)
                (Text("为不同类型的会议预设结构与侧重。生成摘要时选择对应模板，即可得到贴合场景的纪要。提示词支持占位符 ")
                    .foregroundStyle(pal.text2)
                 + Text("{date} {title} {speakers} {transcript}").font(.system(size: 12, design: .monospaced)).foregroundStyle(pal.text))
                    .font(.system(size: 13)).lineSpacing(3).frame(maxWidth: 580, alignment: .leading)
            }
            Spacer(minLength: 12)
            Button { settings.openNewTemplate() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                    Text("新增模板").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white).padding(.horizontal, 16).frame(height: 38)
                .background(pal.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plainHit).hoverCursor()
        }
    }

    private func card(_ t: SummaryTemplate) -> some View {
        let isDefault = t.id == settings.defaultTplId
        let chips = settings.placeholders.filter { t.prompt.contains($0) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(pal.accent)
                    .frame(width: 34, height: 34)
                    .background(pal.accentSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(t.name).font(.system(size: 15, weight: .bold)).foregroundStyle(pal.text).lineLimit(1)
                Spacer(minLength: 6)
                if isDefault {
                    Text("默认").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(pal.accent)
                        .padding(.horizontal, 9).padding(.vertical, 3).background(pal.accentSoft, in: Capsule())
                }
            }

            // 提示词预览（等宽 + 底部渐隐）
            ZStack(alignment: .bottom) {
                Text(t.prompt)
                    .font(.system(size: 11.5, design: .monospaced)).foregroundStyle(pal.text2)
                    .lineSpacing(3).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(13).frame(height: 120, alignment: .topLeading).clipped()
                LinearGradient(colors: [pal.inset.opacity(0), pal.inset], startPoint: .top, endPoint: .bottom)
                    .frame(height: 44).allowsHitTesting(false)
            }
            .background(pal.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .stroke(pal.border, corner: 10)
            .padding(.top, 13)

            if !chips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(chips, id: \.self) { c in
                        Text(c).font(.system(size: 11, design: .monospaced)).foregroundStyle(pal.text2)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(pal.inset, in: RoundedRectangle(cornerRadius: 6)).stroke(pal.border, corner: 6)
                    }
                }
                .padding(.top, 12)
            }

            HStack(spacing: 7) {
                Button { settings.openEditTemplate(t.id) } label: {
                    HStack(spacing: 6) { Image(systemName: "pencil").font(.system(size: 11, weight: .semibold)); Text("编辑").font(.system(size: 12.5, weight: .semibold)) }
                        .foregroundStyle(pal.text).padding(.horizontal, 14).frame(height: 32)
                        .background(pal.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).stroke(pal.borderStrong, corner: 8)
                }.buttonStyle(.plainHit).hoverCursor()
                if !isDefault {
                    Button { settings.setDefaultTemplate(t.id) } label: {
                        Text("设为默认").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.text2)
                            .padding(.horizontal, 12).frame(height: 32)
                    }.buttonStyle(.plainHit).hoverCursor()
                }
                Spacer(minLength: 0)
                if settings.canDeleteTemplate {
                    Button { settings.confirmTplDeleteId = t.id } label: {
                        Image(systemName: "trash").font(.system(size: 12.5, weight: .medium)).foregroundStyle(pal.text3)
                            .frame(width: 32, height: 32)
                    }.buttonStyle(.plainHit).hoverCursor()
                }
            }
            .padding(.top, 15)
        }
        .padding(16)
        .background(pal.elev, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .stroke(pal.border, corner: 14)
    }

    private var addCard: some View {
        Button { settings.openNewTemplate() } label: {
            VStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 17, weight: .bold)).foregroundStyle(pal.accent)
                    .frame(width: 38, height: 38).background(pal.accentSoft, in: Circle())
                Text("新增模板").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text).padding(.top, 4)
                Text("从空白开始，或让 AI 帮你写").font(.system(size: 12)).foregroundStyle(pal.text2)
            }
            .frame(maxWidth: .infinity).frame(minHeight: 200)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(pal.borderStrong))
        }
        .buttonStyle(.plainHit).hoverCursor()
    }
}
