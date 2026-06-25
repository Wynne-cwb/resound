import Foundation
import PDFKit
import Vision
import ImageIO
import CoreGraphics
import AppKit

/// 富格式文档解析（P3）——把 PDF/docx/pptx/HTML/图片解析成结构化 markdown，喂进现有索引/问答/纪要链路。
/// 全用 macOS 原生框架（PDFKit/Vision/Compression/XMLParser），零外部依赖。
/// **失败不抛**：任何格式解析不出都返回空 markdown + warnings，让上层照常建文档 + 留档原件 + 提示用户。
public struct ExtractResult {
    public var markdown: String       // 提取出的结构化正文（写 content.md）
    public var sourceFormat: String   // pdf | docx | pptx | html | image | markdown | txt
    public var warnings: [String]     // 解析告警（空正文/加密/OCR无字…），上层提示用

    public init(markdown: String, sourceFormat: String, warnings: [String] = []) {
        self.markdown = markdown
        self.sourceFormat = sourceFormat
        self.warnings = warnings
    }
}

private let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "bmp", "gif"]
private let ocrLanguages = ["zh-Hans", "zh-Hant", "en-US"]

/// 单一入口：按扩展名分派到各格式提取器。同步函数——调用方在后台线程跑（OCR 慢）。
public func extractDocument(url: URL) -> ExtractResult {
    let ext = url.pathExtension.lowercased()
    switch ext {
    case "md", "markdown", "txt":
        let t = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return ExtractResult(markdown: t, sourceFormat: ext == "txt" ? "txt" : "markdown",
                             warnings: t.isEmpty ? ["文件为空或非 UTF-8 文本"] : [])
    case "pdf":  return extractPDF(url)
    case "docx": return extractDocx(url)
    case "pptx": return extractPptx(url)
    case "html", "htm": return extractHTML(url)
    default:
        if imageExts.contains(ext) { return extractImage(url) }
        // 未知扩展名：尝试当 UTF-8 文本，不行就告警
        if let t = try? String(contentsOf: url, encoding: .utf8), !t.isEmpty {
            return ExtractResult(markdown: t, sourceFormat: "txt")
        }
        let w = "不支持的文件类型：.\(ext)"
        AppLog.log("📄 extractDocument 跳过：\(w)（\(url.lastPathComponent)）")
        return ExtractResult(markdown: "", sourceFormat: ext.isEmpty ? "txt" : ext, warnings: [w])
    }
}

// MARK: - 图片 OCR（Vision）

private func loadCGImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// 对一张 CGImage 跑 Vision 文字识别，返回识别到的行（按视觉顺序）。
private func ocrLines(_ cg: CGImage) -> [String] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = ocrLanguages
    req.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do {
        try handler.perform([req])
    } catch {
        AppLog.error("OCR perform", error)
        return []
    }
    return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

private func extractImage(_ url: URL) -> ExtractResult {
    guard let cg = loadCGImage(url) else {
        return ExtractResult(markdown: "", sourceFormat: "image", warnings: ["无法读取图片"])
    }
    let md = ocrLines(cg).joined(separator: "\n")
    let empty = md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return ExtractResult(markdown: md, sourceFormat: "image",
                         warnings: empty ? ["未识别到文字（OCR 无结果）"] : [])
}

// MARK: - PDF（PDFKit 文本层 + 排版推断标题；扫描件回退 OCR）

private func extractPDF(_ url: URL) -> ExtractResult {
    guard let doc = PDFDocument(url: url) else {
        return ExtractResult(markdown: "", sourceFormat: "pdf", warnings: ["无法打开 PDF"])
    }
    if doc.isEncrypted && doc.isLocked {
        return ExtractResult(markdown: "", sourceFormat: "pdf", warnings: ["PDF 已加密，无法解析"])
    }
    let n = doc.pageCount

    // 第一遍：取各页 attributedString + 统计正文字号众数（按字符数加权）
    var pages: [NSAttributedString] = []
    var sizeHist: [Int: Int] = [:]
    for i in 0..<n {
        let a = doc.page(at: i)?.attributedString ?? NSAttributedString()
        pages.append(a)
        a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { val, range, _ in
            let s = Int((((val as? NSFont)?.pointSize) ?? 0).rounded())
            if s > 0 { sizeHist[s, default: 0] += range.length }
        }
    }
    let bodySize = CGFloat(sizeHist.max { $0.value < $1.value }?.key ?? 12)

    // 第二遍：按字号映射标题层级，组装 markdown
    var out = ""
    var textChars = 0
    for (i, a) in pages.enumerated() {
        let md = markdownFromPDFAttr(a, bodySize: bodySize)
        textChars += md.trimmingCharacters(in: .whitespacesAndNewlines).count
        if !md.isEmpty {
            out += md
            if i < pages.count - 1 { out += "\n\n" }
        }
    }

    // 扫描件判定：几乎无文本层 → 渲染每页走 OCR
    if textChars < max(20, n * 5) {
        var ocrOut = ""
        var any = false
        for i in 0..<n {
            guard let p = doc.page(at: i), let cg = renderPDFPage(p) else { continue }
            let lines = ocrLines(cg)
            if !lines.isEmpty { any = true; ocrOut += lines.joined(separator: "\n") + "\n\n" }
        }
        if any {
            return ExtractResult(markdown: ocrOut.trimmingCharacters(in: .whitespacesAndNewlines),
                                 sourceFormat: "pdf", warnings: ["PDF 无文本层，已用 OCR 提取（扫描件）"])
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExtractResult(markdown: trimmed, sourceFormat: "pdf",
                             warnings: trimmed.isEmpty ? ["PDF 文本极少且 OCR 无结果"] : [])
    }
    return ExtractResult(markdown: out.trimmingCharacters(in: .whitespacesAndNewlines), sourceFormat: "pdf")
}

/// 把一页 attributedString 转 markdown：按行取最大字号，相对正文字号映射 ## / ###。
private func markdownFromPDFAttr(_ attr: NSAttributedString, bodySize: CGFloat) -> String {
    guard attr.length > 0 else { return "" }
    var out = ""
    var line = ""
    var lineMaxSize: CGFloat = 0

    func flush() {
        let t = line.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty {
            if lineMaxSize >= bodySize * 1.4 { out += "## \(t)\n\n" }
            else if lineMaxSize >= bodySize * 1.2 { out += "### \(t)\n\n" }
            else { out += "\(t)\n" }
        }
        line = ""
        lineMaxSize = 0
    }

    let full = attr.string as NSString
    attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { val, range, _ in
        let size = ((val as? NSFont)?.pointSize) ?? bodySize
        let s = full.substring(with: range)
        for ch in s {
            if ch == "\n" || ch == "\r" {
                flush()
            } else {
                line.append(ch)
                lineMaxSize = max(lineMaxSize, size)
            }
        }
    }
    flush()
    return out
}

/// 渲染 PDF 页到位图（供扫描件 OCR）。2x 提清晰度。
private func renderPDFPage(_ page: PDFPage, scale: CGFloat = 2) -> CGImage? {
    let rect = page.bounds(for: .mediaBox)
    let w = Int(rect.width * scale), h = Int(rect.height * scale)
    guard w > 0, h > 0, w < 20_000, h < 20_000,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -rect.minX, y: -rect.minY)
    if let ref = page.pageRef { ctx.drawPDFPage(ref) }
    return ctx.makeImage()
}

// MARK: - docx（OOXML：mini-unzip + XMLParser → 标题/列表/表格）

private func extractDocx(_ url: URL) -> ExtractResult {
    guard let zip = MiniZip(url: url), let xml = zip.data(for: "word/document.xml") else {
        return ExtractResult(markdown: "", sourceFormat: "docx", warnings: ["无法读取 docx（可能损坏或加密）"])
    }
    let delegate = DocxDelegate()
    let parser = XMLParser(data: xml)
    parser.delegate = delegate
    parser.parse()
    let md = delegate.markdown()
    return ExtractResult(markdown: md, sourceFormat: "docx",
                         warnings: md.isEmpty ? ["docx 未提取到文本"] : [])
}

private final class DocxDelegate: NSObject, XMLParserDelegate {
    private var blocks: [String] = []
    private var paraText = ""
    private var style = ""
    private var isListItem = false
    private var inText = false
    // 表格
    private var inTable = false
    private var tableRows: [[String]] = []
    private var currentRow: [String] = []
    private var cellText = ""
    private var inCell = false

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName qn: String?, attributes a: [String: String]) {
        switch el {
        case "w:p":
            if !inTable { paraText = ""; style = ""; isListItem = false }
        case "w:pStyle":
            if !inTable, let v = a["w:val"] { style = v }
        case "w:numPr":
            if !inTable { isListItem = true }
        case "w:t":
            inText = true
        case "w:tbl":
            inTable = true; tableRows = []
        case "w:tr":
            currentRow = []
        case "w:tc":
            inCell = true; cellText = ""
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters s: String) {
        guard inText else { return }
        if inCell { cellText += s } else { paraText += s }
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName qn: String?) {
        switch el {
        case "w:t":
            inText = false
        case "w:p":
            if !inTable {
                let t = paraText.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { blocks.append(formatPara(t, style: style, list: isListItem)) }
                paraText = ""
            }
        case "w:tc":
            inCell = false
            currentRow.append(cellText.trimmingCharacters(in: .whitespacesAndNewlines))
        case "w:tr":
            tableRows.append(currentRow)
        case "w:tbl":
            inTable = false
            let table = formatTable(tableRows)
            if !table.isEmpty { blocks.append(table) }
            tableRows = []
        default: break
        }
    }

    private func formatPara(_ t: String, style: String, list: Bool) -> String {
        let s = style.lowercased()
        if s.contains("title") { return "# \(t)" }
        if s.contains("heading1") || s == "1" { return "# \(t)" }
        if s.contains("heading2") || s == "2" { return "## \(t)" }
        if s.contains("heading3") || s == "3" { return "### \(t)" }
        if s.contains("heading") { return "#### \(t)" }
        if list { return "- \(t)" }
        return t
    }

    private func formatTable(_ rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "" }
        let cols = rows.map(\.count).max() ?? 0
        guard cols > 0 else { return "" }
        func norm(_ r: [String]) -> String {
            var c = r
            while c.count < cols { c.append("") }
            let cells = c.map { $0.replacingOccurrences(of: "|", with: "\\|")
                                  .replacingOccurrences(of: "\n", with: " ") }
            return "| " + cells.joined(separator: " | ") + " |"
        }
        var lines = [norm(rows[0])]
        lines.append("| " + Array(repeating: "---", count: cols).joined(separator: " | ") + " |")
        for r in rows.dropFirst() { lines.append(norm(r)) }
        return lines.joined(separator: "\n")
    }

    func markdown() -> String {
        blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - pptx（按幻灯片提 <a:t>）

private func extractPptx(_ url: URL) -> ExtractResult {
    guard let zip = MiniZip(url: url) else {
        return ExtractResult(markdown: "", sourceFormat: "pptx", warnings: ["无法读取 pptx"])
    }
    let slides = zip.entries
        .filter { $0.name.hasPrefix("ppt/slides/slide") && $0.name.hasSuffix(".xml") }
        .sorted { slideNumber($0.name) < slideNumber($1.name) }
    guard !slides.isEmpty else {
        return ExtractResult(markdown: "", sourceFormat: "pptx", warnings: ["pptx 无幻灯片或已损坏"])
    }
    var out = ""
    for (i, e) in slides.enumerated() {
        out += "## 第 \(i + 1) 页\n\n"
        guard let xml = zip.data(for: e) else { out += "（无法读取）\n\n"; continue }
        let delegate = PptxSlideDelegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        parser.parse()
        let texts = delegate.texts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        out += texts.isEmpty ? "（无文本）\n\n" : texts.joined(separator: "\n") + "\n\n"
    }
    return ExtractResult(markdown: out.trimmingCharacters(in: .whitespacesAndNewlines), sourceFormat: "pptx")
}

private func slideNumber(_ name: String) -> Int {
    let base = (name as NSString).lastPathComponent          // slide12.xml
    let digits = base.drop { !$0.isNumber }.prefix { $0.isNumber }
    return Int(digits) ?? 0
}

private final class PptxSlideDelegate: NSObject, XMLParserDelegate {
    var texts: [String] = []
    private var inT = false
    private var buf = ""

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName qn: String?, attributes: [String: String]) {
        if el == "a:t" { inT = true; buf = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { if inT { buf += s } }
    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName qn: String?) {
        if el == "a:t" { inT = false; texts.append(buf) }
    }
}

// MARK: - HTML（常见标签 → markdown；纯字符串处理，不碰 WebKit/主线程）

private func extractHTML(_ url: URL) -> ExtractResult {
    let raw = (try? String(contentsOf: url, encoding: .utf8))
        ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
    if raw.isEmpty {
        return ExtractResult(markdown: "", sourceFormat: "html", warnings: ["无法读取 HTML"])
    }
    let md = htmlToMarkdown(raw)
    return ExtractResult(markdown: md, sourceFormat: "html",
                         warnings: md.isEmpty ? ["HTML 未提取到文本"] : [])
}

private func htmlToMarkdown(_ html: String) -> String {
    var s = html
    // 去脚本/样式/注释
    s = s.replacingRegex("(?is)<script[^>]*>.*?</script>", with: " ")
    s = s.replacingRegex("(?is)<style[^>]*>.*?</style>", with: " ")
    s = s.replacingRegex("(?is)<!--.*?-->", with: " ")
    // 标题 h1..h6（标签名后须接 '>' 或空白+属性，避免 <hN…> 误匹配同名前缀）
    for lvl in 1...6 {
        let hashes = String(repeating: "#", count: lvl)
        s = s.replacingRegex("(?is)<h\(lvl)(?:\\s[^>]*)?>(.*?)</h\(lvl)\\s*>", with: "\n\n\(hashes) $1\n\n")
    }
    // 列表项
    s = s.replacingRegex("(?is)<li(?:\\s[^>]*)?>(.*?)</li\\s*>", with: "\n- $1")
    // 加粗/斜体（须精确匹配 <b>/<strong>，否则 <body> 会被当 <b>）
    s = s.replacingRegex("(?is)<(?:strong|b)(?:\\s[^>]*)?>(.*?)</(?:strong|b)\\s*>", with: "**$1**")
    s = s.replacingRegex("(?is)<(?:em|i)(?:\\s[^>]*)?>(.*?)</(?:em|i)\\s*>", with: "*$1*")
    // 链接 [text](href)
    s = s.replacingRegex("(?is)<a\\s[^>]*?href=[\"']([^\"']*)[\"'][^>]*>(.*?)</a\\s*>", with: "[$2]($1)")
    // 块级换行
    s = s.replacingRegex("(?i)<br\\s*/?>", with: "\n")
    s = s.replacingRegex("(?is)</(?:p|div|tr|h[1-6]|ul|ol|table|section|article|header|footer)>", with: "\n\n")
    // 删除剩余标签
    s = s.replacingRegex("(?is)<[^>]+>", with: "")
    // 实体解码
    s = decodeEntities(s)
    // 压缩空白
    s = s.replacingRegex("[ \\t]+", with: " ")
    s = s.replacingRegex("\n{3,}", with: "\n\n")
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func decodeEntities(_ s: String) -> String {
    var r = s
    let map = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
               "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
               "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”"]
    for (k, v) in map { r = r.replacingOccurrences(of: k, with: v) }
    return decodeNumericEntities(r)
}

private func decodeNumericEntities(_ s: String) -> String {
    guard let re = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") else { return s }
    let ns = s as NSString
    var result = ""
    var last = 0
    re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
        guard let m = m else { return }
        result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        let isHex = ns.substring(with: m.range(at: 1)).lowercased() == "x"
        let num = ns.substring(with: m.range(at: 2))
        if let code = UInt32(num, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
            result.append(Character(scalar))
        }
        last = m.range.location + m.range.length
    }
    result += ns.substring(from: last)
    return result
}

private extension String {
    /// 便捷正则替换（模板用 $1/$2 引用捕获组）。模式非法时原样返回。
    func replacingRegex(_ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return self }
        let range = NSRange(location: 0, length: (self as NSString).length)
        return re.stringByReplacingMatches(in: self, range: range, withTemplate: template)
    }
}
