import Foundation

/// 把 Notion `notion-fetch` 返回的 "enhanced markdown" 清成标准 markdown。
///
/// Notion 的增强格式把正文混入大量 HTML 式标签（`<page>`/`<ancestor-path>`/`<properties>`/`<table>`/
/// `<details>`/`<span>`/`<empty-block/>`…），并用 **tab 缩进**表嵌套——标准 markdown 渲染器会把标签当 HTML
/// 丢弃、把 tab 缩进当代码块，导致正文显示空白。这里做一次确定性清洗（无 LLM、零成本），用于显示与检索；
/// 原始增强格式仍留档 `original.md`，可随时回溯。
public enum NotionMarkdown {
    /// 是否像 Notion 增强格式（决定要不要清洗，kind 无关）。
    public static func looksLikeEnhanced(_ s: String) -> Bool {
        s.contains("<ancestor-path>") || s.contains("<page url=") || s.contains("<properties>")
            || s.contains("<empty-block") || s.contains("</td>") || s.contains("<details>")
    }

    public static func clean(_ input: String) -> String {
        var s = input

        // 1) 整块噪声移除（祖先路径 / 属性块 / 列宽定义）。
        for block in ["ancestor-path", "properties", "colgroup"] {
            s = s.replacingOccurrences(of: "<\(block)>[\\s\\S]*?</\(block)>", with: "", options: .regularExpression)
        }

        // 2) 表格 → 文本行（`cell | cell`）。先合并相邻单元格，再换行收尾，最后清掉表格标签。
        s = s.replacingOccurrences(of: "</t[dh]>\\s*<t[dh][^>]*>", with: " | ", options: .regularExpression)
        s = s.replacingOccurrences(of: "</tr>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "<tr[^>]*>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "</t[dh]>", with: " | ", options: .regularExpression)
        s = s.replacingOccurrences(of: "<t[dh][^>]*>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "</?table[^>]*>", with: "\n", options: .regularExpression)

        // 3) 其余所有标签整体去除（保留内文），含 <page>/<content>/<details>/<summary>/<span>/<empty-block/> 等。
        s = s.replacingOccurrences(of: "<[^>\\n]+>", with: "", options: .regularExpression)

        // 4) 行级清理。
        var out: [String] = []
        for raw in s.components(separatedBy: "\n") {
            var line = raw
            while line.hasPrefix("\t") { line.removeFirst() }   // 去前导 tab（否则被当代码块）
            if line.hasPrefix("#"), let r = line.range(of: "\\s*\\{[^}]*\\}\\s*$", options: .regularExpression) {
                line.removeSubrange(r)                          // 标题尾部属性 {toggle="true"} 去掉
            }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.contains("|"), t.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: .whitespaces).isEmpty {
                continue                                        // 跳过空表格行（只剩竖线）
            }
            out.append(line)
        }
        s = out.joined(separator: "\n")

        // 5) 折叠多余空行。
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
