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
    private var canEnter: Bool { chatOK && embeddingOK }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    CapabilityCard(cap: .chat, collapsible: false).padding(.top, 16)
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
            stepDot("对话模型", ok: chatOK)
            stepDot("向量模型", ok: embeddingOK)
        }
    }

    private func stepDot(_ label: String, ok: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13)).foregroundStyle(ok ? pal.ok : pal.text3)
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(ok ? pal.text : pal.text3)
        }
    }
}
