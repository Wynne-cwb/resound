import SwiftUI
import AppKit

/// Resound 视觉主题：通透磨砂 + 柔和阴影 + 波形母题 + 一抹克制的冷蓝；浅/深双模式。
enum Theme {
    static let corner: CGFloat = 14
    static let cardCorner: CGFloat = 16

    /// 克制的冷蓝点缀（按钮 / 用户气泡 / 选中态）。
    static let accent = Color(red: 0.40, green: 0.54, blue: 0.78)

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.45, green: 0.59, blue: 0.80),
                                Color(red: 0.35, green: 0.49, blue: 0.74)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// 全窗背景：冷调近白渐变 + 极淡蓝色辉光（呼应图标涟漪；给磨砂材质"可模糊的底"，治发灰发闷）。深浅双模式。
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.13, green: 0.15, blue: 0.18), Color(red: 0.09, green: 0.10, blue: 0.13)]
                    : [Color(red: 0.97, green: 0.98, blue: 1.0), Color(red: 0.90, green: 0.93, blue: 0.965)],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [Theme.accent.opacity(scheme == .dark ? 0.22 : 0.14), .clear],
                center: .init(x: 0.5, y: 0.12), startRadius: 0, endRadius: 540)
            RadialGradient(
                colors: [Color(red: 0.45, green: 0.62, blue: 0.74).opacity(scheme == .dark ? 0.16 : 0.10), .clear],
                center: .init(x: 0.85, y: 0.9), startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

/// 卡片/气泡：磨砂材质 + 细边 + 柔和阴影。
struct SoftCard: ViewModifier {
    var corner: CGFloat = Theme.cardCorner
    var material: Material = .ultraThinMaterial
    func body(content: Content) -> some View {
        content
            .background(material, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.07), radius: 9, y: 2)
    }
}

extension View {
    func softCard(corner: CGFloat = Theme.cardCorner, material: Material = .ultraThinMaterial) -> some View {
        modifier(SoftCard(corner: corner, material: material))
    }

    /// 鼠标悬停时变手型（可点元素用）。
    func hoverCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// 波形小标识（助手头像 / 空状态用）。
struct WaveMark: View {
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: "waveform")
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }
}
