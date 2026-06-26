import SwiftUI
import Markdown

// 原生 Markdown 渲染器：swift-markdown 解析成 AST → 递归渲染成原生 SwiftUI。
// 取代 MarkdownUI（它每块一棵嵌套视图树、整篇一次性布局 = 性能瓶颈）。
// 段落塌缩成单个 Text(AttributedString)，整篇从「几百棵块树」→「几百个廉价 Text」，布局快一个量级。
// 设计见 docs/superpowers/specs/2026-06-26-native-markdown-renderer-design.md。

struct MarkdownNative: View {
    let text: String
    let pal: Palette

    // 解析缓存：按原文缓存 Document，切页/重建视图不重跑 cmark 解析。
    private static var cache: [String: Document] = [:]
    private static func parse(_ s: String) -> Document {
        if let d = cache[s] { return d }
        if cache.count > 48 { cache.removeAll() }
        let d = Document(parsing: s)
        cache[s] = d
        return d
    }

    var body: some View {
        let _ = Perf.body("SummaryMarkdown(parse)")   // 解析已缓存；此计数=视图重建（含布局）
        let blocks = Array(Self.parse(text).blockChildren)
        // LazyVStack：顶层块虚拟化——只有屏幕内的块才构建 AttributedString + 布局。
        // 大文档从「一次性布局 100+ 块」降到「只布局可见的 ~15 块」，打开/切页成本断崖下降。
        // 所有调用点都在 ScrollView 内，故能真正惰性实例化。
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                MDBlock(markup: b, pal: pal, depth: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

// MARK: - 行内样式 → AttributedString

private struct MDStyle {
    var size: CGFloat = 13.5
    var weight: Font.Weight = .regular
    var italic = false
    var mono = false
    var strike = false
    var color: Color
    var bg: Color? = nil
    var link: URL? = nil
}

private func mdStyled(_ s: String, _ st: MDStyle) -> AttributedString {
    var a = AttributedString(s)
    var font = Font.system(size: st.size, weight: st.weight, design: st.mono ? .monospaced : .default)
    if st.italic { font = font.italic() }
    a.font = font
    a.foregroundColor = st.color
    if let bg = st.bg { a.backgroundColor = bg }
    if st.strike { a.strikethroughStyle = .single }
    if let link = st.link { a.link = link }
    return a
}

/// 把一串行内节点合成 AttributedString（粗/斜/删除线/行内代码/链接/换行）。
private func mdInline(_ inlines: [Markup], _ st: MDStyle, _ pal: Palette) -> AttributedString {
    var out = AttributedString()
    for child in inlines { out.append(mdInlineOne(child, st, pal)) }
    return out
}

private func mdInlineOne(_ m: Markup, _ st: MDStyle, _ pal: Palette) -> AttributedString {
    switch m {
    case let t as Markdown.Text:
        return mdStyled(t.string, st)
    case let s as Strong:
        var n = st; n.weight = .semibold; return mdInline(Array(s.children), n, pal)
    case let e as Emphasis:
        var n = st; n.italic = true; return mdInline(Array(e.children), n, pal)
    case let sk as Strikethrough:
        var n = st; n.strike = true; return mdInline(Array(sk.children), n, pal)
    case let c as InlineCode:
        var n = st; n.mono = true; n.size = st.size * 0.9; n.color = pal.accent; n.bg = pal.accentSoft
        return mdStyled(c.code, n)
    case let l as Markdown.Link:
        var n = st; n.color = pal.accent
        if let d = l.destination, let u = URL(string: d) { n.link = u }
        return mdInline(Array(l.children), n, pal)
    case let img as Markdown.Image:
        let alt = img.plainText
        return mdStyled(alt.isEmpty ? "🖼" : "🖼 \(alt)", st)
    case is SoftBreak:
        return AttributedString(" ")
    case is LineBreak:
        return mdStyled("\n", st)
    default:
        // 未知行内容器 → 递归子节点；叶子 → 退化为纯文本
        if m.childCount > 0 { return mdInline(Array(m.children), st, pal) }
        return mdStyled((m as? PlainTextConvertibleMarkup)?.plainText ?? "", st)
    }
}

// MARK: - 块级渲染（递归）

private struct MDBlock: View {
    let markup: Markup
    let pal: Palette
    let depth: Int            // 列表嵌套深度（顶层 0）

    var body: some View {
        switch markup {
        case let h as Heading:        heading(h)
        case let p as Paragraph:      paragraph(p)
        case let ul as UnorderedList: MDList(items: Array(ul.listItems), ordered: false, start: 1, pal: pal, depth: depth)
        case let ol as OrderedList:   MDList(items: Array(ol.listItems), ordered: true, start: Int(ol.startIndex), pal: pal, depth: depth)
        case let bq as BlockQuote:    quote(bq)
        case let cb as CodeBlock:     codeBlock(cb)
        case let t as Markdown.Table: MDTable(table: t, pal: pal)
        case is ThematicBreak:        Rectangle().fill(pal.border).frame(height: 1).padding(.vertical, 8)
        default:                      fallback()
        }
    }

    // h1–h4：1.5/1.28/1.12/1.0 em，粗体（h4 半粗），accent 色；上下 margin 对齐旧主题。
    private func heading(_ h: Heading) -> some View {
        let lv = min(max(h.level, 1), 4)
        let size: CGFloat = [20.25, 17.28, 15.12, 13.5][lv - 1]
        let weight: Font.Weight = lv == 4 ? .semibold : .bold
        let top: CGFloat = [16, 16, 14, 12][lv - 1]
        let bottom: CGFloat = [10, 8, 6, 6][lv - 1]
        let st = MDStyle(size: size, weight: weight, color: pal.accent)
        return SwiftUI.Text(mdInline(Array(h.children), st, pal))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, top).padding(.bottom, bottom)
    }

    private func paragraph(_ p: Paragraph) -> some View {
        let st = MDStyle(color: pal.text)
        return SwiftUI.Text(mdInline(Array(p.children), st, pal))
            .lineSpacing(6)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, depth > 0 ? 0 : 12)   // 列表内段落不撑额外间距
    }

    // 引用块：左侧 3pt accent 竖条 + 内容 text2 色（递归）。
    private func quote(_ bq: BlockQuote) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(pal.accent.opacity(0.5)).frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(bq.blockChildren.enumerated()), id: \.offset) { _, b in
                    MDBlock(markup: b, pal: pal.quoteToned, depth: depth)
                }
            }
            .padding(.leading, 12)
        }
        .padding(.bottom, 12)
    }

    private func codeBlock(_ cb: CodeBlock) -> some View {
        SwiftUI.Text(cb.code.hasSuffix("\n") ? String(cb.code.dropLast()) : cb.code)
            .font(.system(size: 12.5, design: .monospaced))
            .foregroundStyle(pal.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(pal.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.bottom, 12)
            .textSelection(.enabled)
    }

    private func fallback() -> some View {
        SwiftUI.Text((markup as? PlainTextConvertibleMarkup)?.plainText ?? "")
            .font(.system(size: 13.5)).foregroundStyle(pal.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, depth > 0 ? 0 : 12)
    }
}

// 引用块内文字用 text2 色：复制一份调色板、把 text 调成 text2。
private extension Palette {
    var quoteToned: Palette {
        Palette(isDark: isDark, bg: bg, sidebar: sidebar, titlebar: titlebar, elev: elev, inset: inset,
                       text: text2, text2: text2, text3: text3, border: border, borderStrong: borderStrong,
                       accent: accent, accentSoft: accentSoft, doc: doc, docSoft: docSoft, rec: rec, recSoft: recSoft,
                       ok: ok, warn: warn, warnSoft: warnSoft, warnBorder: warnBorder, hover: hover,
                       toastBg: toastBg, toastText: toastText)
    }
}

// MARK: - 列表（多级嵌套）

private struct MDList: View {
    let items: [ListItem]
    let ordered: Bool
    let start: Int
    let pal: Palette
    let depth: Int

    private func bullet() -> String { ["•", "◦", "▪"][depth % 3] }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    marker(index: i, checkbox: item.checkbox)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(item.blockChildren.enumerated()), id: \.offset) { _, b in
                            MDBlock(markup: b, pal: pal, depth: depth + 1)
                        }
                    }
                }
            }
        }
        .padding(.leading, depth == 0 ? 0 : 18)   // 每深一层缩进 18
        .padding(.bottom, depth == 0 ? 12 : 0)
    }

    @ViewBuilder private func marker(index: Int, checkbox: Checkbox?) -> some View {
        if let cb = checkbox {
            SwiftUI.Text(cb == .checked ? "☑" : "☐")
                .font(.system(size: 13.5)).foregroundStyle(pal.text2)
        } else {
            SwiftUI.Text(ordered ? "\(start + index)." : bullet())
                .font(.system(size: 13.5)).foregroundStyle(pal.text2)
                .frame(minWidth: 16, alignment: .trailing)
        }
    }
}

// MARK: - 表格（GFM）

private struct MDTable: View {
    let table: Markdown.Table
    let pal: Palette

    var body: some View {
        let aligns = table.columnAlignments
        let headCells = Array(table.head.cells)
        let bodyRows = Array(table.body.rows).map { Array($0.cells) }
        return VStack(spacing: 0) {
            row(cells: headCells, aligns: aligns, header: true)
            ForEach(Array(bodyRows.enumerated()), id: \.offset) { _, cells in
                Divider().overlay(pal.border)
                row(cells: cells, aligns: aligns, header: false)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(pal.border, lineWidth: 1))
        .padding(.bottom, 12)
    }

    private func row(cells: [Markdown.Table.Cell], aligns: [Markdown.Table.ColumnAlignment?], header: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { i, cell in
                let a = i < aligns.count ? aligns[i] : nil
                let st = MDStyle(weight: header ? .semibold : .regular, color: pal.text)
                if i > 0 { Rectangle().fill(pal.border).frame(width: 1) }
                SwiftUI.Text(mdInline(Array(cell.children), st, pal))
                    .frame(maxWidth: .infinity, alignment: alignment(a))
                    .padding(.horizontal, 10).padding(.vertical, 7)
            }
        }
        .background(header ? pal.inset : Color.clear)
    }

    private func alignment(_ a: Markdown.Table.ColumnAlignment?) -> Alignment {
        switch a { case .center: return .center; case .right: return .trailing; default: return .leading }
    }
}
