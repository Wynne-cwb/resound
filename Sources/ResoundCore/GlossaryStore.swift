import Foundation

/// 专有词表的结构化读写（事实源 vault/glossary.txt）。
///
/// 文件格式（见 [Glossary]）：一行一条，`规范词 = 变体1, 变体2`，或只写规范词。
/// [Glossary] 负责消费（偏置 + 纠正）；本类型负责 App 设置页的增删改。
public struct GlossaryEntry: Identifiable, Hashable {
    public var id: String { canonical }
    public var canonical: String          // 规范词（正确写法）
    public var variants: [String]         // 易错变体（转录后替换回规范词）

    public init(canonical: String, variants: [String] = []) {
        self.canonical = canonical
        self.variants = variants
    }
}

public enum GlossaryStore {
    /// 文件头注释（重写时保留，提示用户这份由 App 管理）。
    private static let header = """
    # Resound 专有词表 —— 由 App「设置 › 专有词表」管理。
    # 格式：规范词 = 易错变体1, 易错变体2   （只写规范词也有效，仅做偏置）
    """

    public static func fileURL(vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent("glossary.txt")
    }

    /// 读出结构化词条（保持文件顺序；跳过注释/空行）。
    public static func load(vaultRoot: URL) -> [GlossaryEntry] {
        guard let s = try? String(contentsOf: fileURL(vaultRoot: vaultRoot), encoding: .utf8) else { return [] }
        var out: [GlossaryEntry] = []
        for raw in s.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let eq = line.firstIndex(of: "=") {
                let canonical = line[..<eq].trimmingCharacters(in: .whitespaces)
                let variants = line[line.index(after: eq)...]
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if !canonical.isEmpty { out.append(GlossaryEntry(canonical: canonical, variants: variants)) }
            } else {
                out.append(GlossaryEntry(canonical: line))
            }
        }
        return out
    }

    /// 覆盖写回（保留头注释；丢弃用户自定义注释 —— 词表已由 App 接管）。
    public static func save(_ entries: [GlossaryEntry], vaultRoot: URL) throws {
        var lines = [header, ""]
        for e in entries {
            let canonical = e.canonical.trimmingCharacters(in: .whitespaces)
            guard !canonical.isEmpty else { continue }
            let variants = e.variants.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            lines.append(variants.isEmpty ? canonical : "\(canonical) = \(variants.joined(separator: ", "))")
        }
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(to: fileURL(vaultRoot: vaultRoot), atomically: true, encoding: .utf8)
    }
}
