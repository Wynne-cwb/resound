import Foundation

// MARK: - 智能推算建议的派生存储（App Support，不进 vault）
//
// 未确认的「文件夹/tag 建议」只存在这里；用户采纳才写回 vault 事实源（library.json / document.yaml）。
// 录音建议与文档建议分两个文件，各由 LibraryModel / DocumentsModel 独立拥有，避免共写一个文件。
// 设计见 docs/superpowers/specs/2026-06-26-auto-classify-folder-tag-design.md。

/// 录音 → 文件夹建议（单选）。folderId 与 newName 二选一；dismissed 后不再冒泡。
struct FolderSuggestionRecord: Codable, Equatable {
    var folderId: String?
    var newName: String?
    var dismissed: Bool = false
    var hasContent: Bool { folderId != nil || newName != nil }
}

struct TagSuggestionItem: Codable, Equatable { var tag: String; var isNew: Bool }

/// 文档 → tag 建议（0-2 个，整组接受）。
struct TagSuggestionRecord: Codable, Equatable {
    var tags: [TagSuggestionItem]
    var dismissed: Bool = false
    var hasContent: Bool { !tags.isEmpty }
}

/// 通用按 id 分桶的 JSON 存储（~/Library/Application Support/Resound/<name>）。
struct SuggestionStore<Record: Codable> {
    let fileName: String
    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Resound/\(fileName)")
    }
    func load() -> [String: Record] {
        guard let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: Record].self, from: data) else { return [:] }
        return map
    }
    func save(_ map: [String: Record]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if let data = try? enc.encode(map) { try? data.write(to: url, options: .atomic) }
    }
}
