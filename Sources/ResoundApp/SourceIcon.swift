import SwiftUI
import AppKit
import ResoundCore

/// MCP 来源品牌图标加载（打包进 App 资源的 SVG，NSImage 原生矢量渲染，按 kind 缓存）。
enum MCPIcons {
    private static var cache: [String: NSImage] = [:]

    /// 黑白单色 logo（随主题着色）；彩色 logo 原样渲染。
    static func isMonochrome(_ kind: MCPSourceKind) -> Bool {
        kind == .notion || kind == .custom
    }

    static func image(for kind: MCPSourceKind) -> NSImage? {
        let name = kind.rawValue   // notion/atlassian/google/figma/custom → 文件名（custom=mcp.svg）
        let file = kind == .custom ? "mcp" : name
        if let c = cache[file] { return c }
        guard let url = Bundle.module.url(forResource: file, withExtension: "svg", subdirectory: "MCPIcons"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[file] = img
        return img
    }

    /// 取不到图标时的字母兜底。
    static func letter(_ kind: MCPSourceKind?) -> String {
        switch kind {
        case .notion: return "N"; case .atlassian: return "J"; case .google: return "G"
        case .figma: return "F"; case .custom, .none: return "#"
        }
    }
}

/// 来源图标方块：品牌 SVG 居中（彩色原样 / 黑白随主题），取不到回退字母。kind=nil（未知来源）走通用 MCP 标。
struct SourceIcon: View {
    var kind: MCPSourceKind?
    var size: CGFloat
    @Environment(\.palette) var pal

    var body: some View {
        let resolved = kind ?? .custom
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(pal.inset)
            if let img = MCPIcons.image(for: resolved) {
                if MCPIcons.isMonochrome(resolved) {
                    Image(nsImage: img).resizable().renderingMode(.template).scaledToFit()
                        .foregroundStyle(pal.text).frame(width: size * 0.54, height: size * 0.54)
                } else {
                    Image(nsImage: img).resizable().renderingMode(.original).scaledToFit()
                        .frame(width: size * 0.58, height: size * 0.58)
                }
            } else {
                Text(MCPIcons.letter(kind)).font(.system(size: size * 0.42, weight: .bold, design: .monospaced)).foregroundStyle(pal.text2)
            }
        }
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: size * 0.27).strokeBorder(pal.border, lineWidth: 1))
    }
}
