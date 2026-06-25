import SwiftUI
import AppKit

// MARK: - 颜色工具

extension Color {
    /// 0xRRGGBB 十六进制 → Color（可带 alpha）。
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

// MARK: - 调色板（还原设计稿的浅/深双套 token）

// Equatable 是性能关键：Palette 作为 environment 值注入全树，SwiftUI 只有在它「可判等且不等」时
// 才会让下游 @Environment(\.palette) 读者失效。非 Equatable 时 SwiftUI 保守地把每次注入都当变更 →
// 侧栏折叠/toast/切页等任一 AppModel 变更都会每帧重建 Palette → 整棵树（含 Ask 的 Markdown）重渲染。
// 成员全是 Bool/Color（均 Equatable），编译器自动合成 == 即可。
struct Palette: Equatable {
    let isDark: Bool
    let bg, sidebar, titlebar, elev, inset: Color
    let text, text2, text3: Color
    let border, borderStrong: Color
    let accent, accentSoft: Color
    let doc, docSoft: Color
    let rec, recSoft: Color
    let ok, warn, warnSoft, warnBorder: Color
    let hover: Color
    let toastBg, toastText: Color

    static func make(dark: Bool) -> Palette {
        if dark {
            return Palette(
                isDark: true,
                bg: Color(hex: 0x1d1d20), sidebar: Color(hex: 0x252529), titlebar: Color(hex: 0x212125),
                elev: Color(hex: 0x2a2a2f), inset: Color(hex: 0x303036),
                text: Color(hex: 0xf3f3f5), text2: Color(hex: 0xa4a4ac), text3: Color(hex: 0x6e6e78),
                border: Color(hex: 0xffffff, alpha: 0.08), borderStrong: Color(hex: 0xffffff, alpha: 0.15),
                accent: Color(hex: 0xe3a35f), accentSoft: Color(hex: 0xe3a35f, alpha: 0.18),
                doc: Color(hex: 0x7aa7e0), docSoft: Color(hex: 0x7aa7e0, alpha: 0.16),
                rec: Color(hex: 0xff6b54), recSoft: Color(hex: 0xff6b54, alpha: 0.16),
                ok: Color(hex: 0x4cc38a), warn: Color(hex: 0xe8b34a),
                warnSoft: Color(hex: 0xe8b34a, alpha: 0.16), warnBorder: Color(hex: 0xe8b34a, alpha: 0.30),
                hover: Color(hex: 0xffffff, alpha: 0.06),
                toastBg: Color(hex: 0x34343a), toastText: Color(hex: 0xf3f3f5))
        } else {
            return Palette(
                isDark: false,
                bg: Color(hex: 0xfcfcfb), sidebar: Color(hex: 0xf1f1ee), titlebar: Color(hex: 0xf6f6f4),
                elev: Color(hex: 0xffffff), inset: Color(hex: 0xf3f3f0),
                text: Color(hex: 0x1d1d1f), text2: Color(hex: 0x6b6b72), text3: Color(hex: 0x9c9ca3),
                border: Color(hex: 0x000000, alpha: 0.075), borderStrong: Color(hex: 0x000000, alpha: 0.13),
                accent: Color(hex: 0xe85f2c), accentSoft: Color(hex: 0xe85f2c, alpha: 0.10),
                doc: Color(hex: 0x3f72b8), docSoft: Color(hex: 0x3f72b8, alpha: 0.10),
                rec: Color(hex: 0xdd4b35), recSoft: Color(hex: 0xdd4b35, alpha: 0.10),
                ok: Color(hex: 0x2e9e6b), warn: Color(hex: 0xbf8a1e),
                warnSoft: Color(hex: 0xbf8a1e, alpha: 0.10), warnBorder: Color(hex: 0xbf8a1e, alpha: 0.25),
                hover: Color(hex: 0x000000, alpha: 0.04),
                toastBg: Color(hex: 0x26262b), toastText: Color(hex: 0xfafafa))
        }
    }

    /// 全窗背景：呼应设计稿的对角径向辉光。
    var wallpaper: LinearGradient {
        LinearGradient(colors: isDark
            ? [Color(hex: 0x2e3138), Color(hex: 0x1c1e23), Color(hex: 0x131419)]
            : [Color(hex: 0xeef1f6), Color(hex: 0xdde2ea), Color(hex: 0xd2d8e1)],
            startPoint: .topTrailing, endPoint: .bottomLeading)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.make(dark: false)
}
extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

// MARK: - 复用修饰符

extension View {
    /// 抬升卡片：elev 底 + 细边 + 轻阴影。
    func card(_ pal: Palette, corner: CGFloat = 13, fill: Color? = nil) -> some View {
        background(fill ?? pal.elev, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(pal.border, lineWidth: 1))
    }

    /// 描边（不填充）。
    func stroke(_ color: Color, corner: CGFloat = 9, width: CGFloat = 1) -> some View {
        overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
            .strokeBorder(color, lineWidth: width))
    }

    /// 悬停变手型。
    func hoverCursor() -> some View {
        onHover { $0 ? NSCursor.pointingHand.push() : NSCursor.pop() }
    }
}

/// 等价于 `.plain`，但把整个 label 区域（含 padding / 透明背景）都设为可点区，
/// 避免「只有点到文字/图标才响应」的 SwiftUI macOS 老问题。全 App 统一用它。
struct PlainHitButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}
extension ButtonStyle where Self == PlainHitButtonStyle {
    static var plainHit: PlainHitButtonStyle { PlainHitButtonStyle() }
}

/// 列表行内的操作图标按钮（改名/删除等）。全 App 统一风格：26×26 描边方块，删除态用警示色。
/// 录音列表、文件夹头、对话历史共用，避免各处大小/描边不一致。
struct RowIconButton: View {
    var pal: Palette
    var icon: String
    var danger: Bool = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .foregroundStyle(danger ? pal.rec : pal.text2)
                .frame(width: 26, height: 26)
                .background(pal.elev, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(pal.border, lineWidth: 1))
        }
        .buttonStyle(.plainHit).hoverCursor()
    }
}

/// App 品牌图标（侧栏标识 / 提问页 hero）。优先用打包进 bundle 的真实图标，
/// 取不到（如 swift run 未打包）回退到合成波形标。
struct BrandIcon: View {
    var pal: Palette
    var size: CGFloat
    var bordered: Bool = false   // 侧栏上图标偏浅、与底色接近时加描边

    private static let image: NSImage? = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AppIcon.png"),
           let img = NSImage(contentsOf: url) { return img }
        if let img = NSImage(named: "AppIcon") { return img }
        let app = NSApp.applicationIconImage
        return (app?.isValid == true) ? app : nil
    }()

    var body: some View {
        Group {
            if let img = Self.image {
                Image(nsImage: img).resizable().interpolation(.high)
            } else {
                SidebarLogo(pal: pal, size: size)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if bordered {
                // 贴合图标圆角方形（squircle 约占帧 84%、四边留白 ~8%）描一圈细边
                RoundedRectangle(cornerRadius: size * 0.185, style: .continuous)
                    .inset(by: size * 0.078)
                    .strokeBorder(pal.border, lineWidth: 0.75)
            }
        }
    }
}

/// 波形小标识（助手头像 / 空状态用）。
struct WaveMark: View {
    var pal: Palette
    var height: CGFloat = 11
    var bars: [CGFloat] = [4, 9, 6, 11]
    var color: Color? = nil
    var body: some View {
        let w = max(1.9, height * 0.17)
        HStack(alignment: .bottom, spacing: w * 0.85) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, h in
                RoundedRectangle(cornerRadius: w / 2, style: .continuous)
                    .fill(color ?? pal.accent)
                    .frame(width: w, height: height * (h / bars.max()!))
            }
        }
        .frame(height: height, alignment: .bottom)
    }
}

/// 旋转的 spinner（处理中）。
struct Spinner: View {
    var size: CGFloat = 15
    var color: Color
    @State private var spin = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}
