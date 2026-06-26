import SwiftUI
import ResoundCore

/// 首次启动引导：必须先配好「对话模型 + 向量模型」（各自验证通过）才能进主界面；
/// 转写可留空兜底到本地 Whisper。复用 CapabilityCard，与设置页同一套交互。
struct OnboardingView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var providers: ProvidersModel
    @Environment(\.palette) var pal

    private var chatOK: Bool { if case .ok = providers.probe[.chat] { return true } else { return false } }
    private var embeddingOK: Bool { if case .ok = providers.probe[.embedding] { return true } else { return false } }
    private var canEnter: Bool { chatOK && embeddingOK && app.vaultReady }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    vaultCard.padding(.top, 16)
                    CapabilityCard(cap: .chat, collapsible: false).padding(.top, 12)
                    CapabilityCard(cap: .embedding, collapsible: false).padding(.top, 12)
                    CapabilityCard(cap: .transcribe, collapsible: false).padding(.top, 12)
                    Color.clear.frame(height: 24)
                }
                .frame(maxWidth: 600, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 40).padding(.top, 48)
            }
            footer
        }
        .background(pal.bg.ignoresSafeArea())
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BrandIcon(pal: pal, size: 44, bordered: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("欢迎使用 Resound").font(.system(size: 22, weight: .bold)).foregroundStyle(pal.text)
                    Text("你的本地会议 wiki：录音 → 转录 → 检索问答").font(.system(size: 13)).foregroundStyle(pal.text2)
                }
            }
            Text("Resound 自己不带模型，请接入任意 OpenAI 兼容的 AI 服务。最少需要一个**对话模型**和一个**向量模型**——可以来自同一个服务商，也可以分开。所有密钥只存在这台 Mac 上。")
                .font(.system(size: 13)).foregroundStyle(pal.text2).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            statusHint
            Spacer()
            Button { if canEnter { app.showOnboarding = false } } label: {
                HStack(spacing: 7) {
                    Text("进入 Resound").font(.system(size: 13.5, weight: .semibold))
                    Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(.white).padding(.horizontal, 20).frame(height: 40)
                .background(canEnter ? pal.accent : pal.borderStrong, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plainHit).hoverCursor().disabled(!canEnter)
        }
        .padding(.horizontal, 40).padding(.vertical, 16)
        .frame(maxWidth: 600).frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Rectangle().fill(pal.border).frame(height: 1) }
        .background(pal.titlebar)
    }

    @ViewBuilder private var statusHint: some View {
        HStack(spacing: 14) {
            stepDot("录音库", ok: app.vaultReady)
            stepDot("对话模型", ok: chatOK)
            stepDot("向量模型", ok: embeddingOK)
        }
    }

    /// 录音库位置：选文件夹 → 自动建好 vault 数据结构（AppModel.chooseVault）。
    private var vaultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(pal.accentSoft)
                    Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(pal.accent)
                }.frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("录音库位置").font(.system(size: 14, weight: .semibold)).foregroundStyle(pal.text)
                    Text("录音、转录、文档都存在这个本地文件夹。选好后 Resound 会自动建好数据结构。")
                        .font(.system(size: 12)).foregroundStyle(pal.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if app.vaultReady { Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(pal.ok) }
            }
            if app.vaultReady && !app.vaultPath.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").font(.system(size: 11)).foregroundStyle(pal.text3)
                    Text(app.vaultPath).font(.system(size: 12, design: .monospaced)).foregroundStyle(pal.text2)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button { app.chooseVault() } label: {
                        Text("更换").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(pal.accent)
                    }.buttonStyle(.plainHit).hoverCursor()
                }
                .padding(.horizontal, 12).frame(height: 38)
                .background(pal.inset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else {
                Button { app.chooseVault() } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 12, weight: .semibold))
                        Text("选择文件夹…").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 16).frame(height: 38)
                    .background(pal.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }.buttonStyle(.plainHit).hoverCursor()
            }
        }
        .padding(16).card(pal, corner: 13)
    }

    private func stepDot(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13)).foregroundStyle(ok ? pal.ok : pal.text3)
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(ok ? pal.text : pal.text3)
        }
    }
}
