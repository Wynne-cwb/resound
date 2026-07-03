import AppKit
import Markdown

// Markdown → NSAttributedString（供「复制带样式的文本」用）。
// 与屏幕渲染（MarkdownNative）分离：这里只为剪贴板服务，产出带真实 NSFont/段落样式的富文本，
// 写 RTF 到 NSPasteboard——粘到 Notion / Word / Mail 能保留粗体、标题、列表、代码块。
// 颜色刻意保持中性（正文不设前景色，交给目标应用的默认文字色），跨浅/深色文档都可读。
enum MarkdownAttributed {
    static func make(_ text: String) -> NSAttributedString {
        let doc = Document(parsing: text)
        let out = NSMutableAttributedString()
        for block in doc.blockChildren { appendBlock(block, into: out, depth: 0) }
        // 去掉结尾多余空行
        while out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }

    // MARK: 行内样式

    private struct IStyle {
        var size: CGFloat = 13.5
        var bold = false
        var italic = false
        var mono = false
        var strike = false
        var link: URL? = nil
        var color: NSColor? = nil
    }

    private static func font(_ st: IStyle) -> NSFont {
        if st.mono { return .monospacedSystemFont(ofSize: st.size, weight: st.bold ? .semibold : .regular) }
        var traits: NSFontTraitMask = []
        if st.bold { traits.insert(.boldFontMask) }
        if st.italic { traits.insert(.italicFontMask) }
        let base = NSFont.systemFont(ofSize: st.size)
        return traits.isEmpty ? base : NSFontManager.shared.convert(base, toHaveTrait: traits)
    }

    private static func styled(_ s: String, _ st: IStyle) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: font(st)]
        if let c = st.color { attrs[.foregroundColor] = c }
        if st.strike { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = st.link {
            attrs[.link] = link
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attrs[.foregroundColor] = NSColor.linkColor
        }
        return NSAttributedString(string: s, attributes: attrs)
    }

    private static func appendInline(_ m: Markup, _ st: IStyle, into out: NSMutableAttributedString) {
        switch m {
        case let t as Markdown.Text:
            out.append(styled(t.string, st))
        case let s as Strong:
            var n = st; n.bold = true
            for c in s.children { appendInline(c, n, into: out) }
        case let e as Emphasis:
            var n = st; n.italic = true
            for c in e.children { appendInline(c, n, into: out) }
        case let sk as Strikethrough:
            var n = st; n.strike = true
            for c in sk.children { appendInline(c, n, into: out) }
        case let c as InlineCode:
            var n = st; n.mono = true; n.size = st.size * 0.92
            out.append(styled(c.code, n))
        case let l as Markdown.Link:
            var n = st
            if let d = l.destination, let u = URL(string: d) { n.link = u }
            for c in l.children { appendInline(c, n, into: out) }
        case let img as Markdown.Image:
            let alt = img.plainText
            out.append(styled(alt.isEmpty ? "🖼" : "🖼 \(alt)", st))
        case is SoftBreak:
            out.append(styled(" ", st))
        case is LineBreak:
            out.append(styled("\n", st))
        default:
            if m.childCount > 0 { for c in m.children { appendInline(c, st, into: out) } }
            else { out.append(styled((m as? PlainTextConvertibleMarkup)?.plainText ?? "", st)) }
        }
    }

    // MARK: 块级

    private static func para(spacingAfter: CGFloat, spacingBefore: CGFloat = 0, indent: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacing = spacingAfter
        p.paragraphSpacingBefore = spacingBefore
        p.firstLineHeadIndent = indent
        p.headIndent = indent
        p.lineSpacing = 2
        return p
    }

    // 把一段富文本收尾：补换行、整段套段落样式、拼进输出。
    private static func finish(_ a: NSMutableAttributedString, _ ps: NSParagraphStyle, into out: NSMutableAttributedString) {
        a.append(NSAttributedString(string: "\n"))
        a.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: a.length))
        out.append(a)
    }

    private static func appendBlock(_ m: Markup, into out: NSMutableAttributedString, depth: Int) {
        switch m {
        case let h as Heading:
            let sizes: [CGFloat] = [20, 17, 15, 13.5]
            let lv = min(max(h.level, 1), 4)
            var st = IStyle(size: sizes[lv - 1]); st.bold = true
            let a = NSMutableAttributedString()
            for c in h.children { appendInline(c, st, into: a) }
            finish(a, para(spacingAfter: 4, spacingBefore: 10, indent: CGFloat(depth) * 18), into: out)

        case let p as Paragraph:
            let a = NSMutableAttributedString()
            for c in p.children { appendInline(c, IStyle(), into: a) }
            finish(a, para(spacingAfter: 8, indent: CGFloat(depth) * 18), into: out)

        case let ul as UnorderedList:
            for item in ul.listItems { appendListItem(item, ordered: false, index: 0, into: out, depth: depth) }

        case let ol as OrderedList:
            var i = Int(ol.startIndex)
            for item in ol.listItems { appendListItem(item, ordered: true, index: i, into: out, depth: depth); i += 1 }

        case let bq as BlockQuote:
            for b in bq.blockChildren { appendBlock(b, into: out, depth: depth + 1) }

        case let cb as CodeBlock:
            var st = IStyle(size: 12.5); st.mono = true
            let code = cb.code.hasSuffix("\n") ? String(cb.code.dropLast()) : cb.code
            let a = NSMutableAttributedString(string: code, attributes: [.font: font(st)])
            finish(a, para(spacingAfter: 8, indent: 8), into: out)

        case let t as Markdown.Table:
            appendTable(t, into: out)

        case is ThematicBreak:
            let a = NSMutableAttributedString(string: "————————", attributes: [.font: font(IStyle())])
            finish(a, para(spacingAfter: 8), into: out)

        default:
            let a = NSMutableAttributedString(string: (m as? PlainTextConvertibleMarkup)?.plainText ?? "", attributes: [.font: font(IStyle())])
            finish(a, para(spacingAfter: 8, indent: CGFloat(depth) * 18), into: out)
        }
    }

    private static func appendListItem(_ item: ListItem, ordered: Bool, index: Int, into out: NSMutableAttributedString, depth: Int) {
        let indent = CGFloat(depth) * 20 + 18
        let marker: String
        if let cb = item.checkbox { marker = cb == .checked ? "☑" : "☐" }
        else if ordered { marker = "\(index)." }
        else { marker = ["•", "◦", "▪"][depth % 3] }

        var first = true
        for block in item.blockChildren {
            if let p = block as? Paragraph {
                let line = NSMutableAttributedString()
                let prefix = first ? "\(marker)\t" : ""
                if !prefix.isEmpty { line.append(NSAttributedString(string: prefix, attributes: [.font: font(IStyle())])) }
                for c in p.children { appendInline(c, IStyle(), into: line) }
                let ps = NSMutableParagraphStyle()
                ps.firstLineHeadIndent = CGFloat(depth) * 20
                ps.headIndent = indent
                ps.paragraphSpacing = 3
                ps.lineSpacing = 2
                ps.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                finish(line, ps, into: out)
                first = false
            } else {
                appendBlock(block, into: out, depth: depth + 1)
            }
        }
    }

    private static func appendTable(_ table: Markdown.Table, into out: NSMutableAttributedString) {
        func rowString(_ cells: [Markdown.Table.Cell], header: Bool) {
            let a = NSMutableAttributedString()
            var st = IStyle(); st.bold = header
            for (i, cell) in cells.enumerated() {
                if i > 0 { a.append(NSAttributedString(string: "  |  ", attributes: [.font: font(IStyle())])) }
                for c in cell.children { appendInline(c, st, into: a) }
            }
            finish(a, para(spacingAfter: 2), into: out)
        }
        rowString(Array(table.head.cells), header: true)
        for row in table.body.rows { rowString(Array(row.cells), header: false) }
    }
}

// MARK: - 剪贴板写入

enum RichCopy {
    /// 复制带样式文本：RTF（富文本目标保留格式）+ 纯文本兜底。
    static func styled(_ markdown: String) {
        let att = MarkdownAttributed.make(markdown)
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if let rtf = try? att.data(from: NSRange(location: 0, length: att.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            item.setData(rtf, forType: .rtf)
        }
        item.setString(att.string, forType: .string)
        pb.writeObjects([item])
    }

    /// 复制原始 Markdown 源码（纯文本）。
    static func plain(_ markdown: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(markdown, forType: .string)
    }
}
