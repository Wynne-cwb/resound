import Foundation

/// 智能推算：给录音建议文件夹、给文档建议 tag。纯函数、无副作用——只调 LLM 返回结构化建议，
/// **不读写 vault、不存状态**（编排/存储/落地由 App 层负责）。无合适项一律返回 nil/空，绝不硬凑。
///
/// 设计见 docs/superpowers/specs/2026-06-26-auto-classify-folder-tag-design.md（路径 2：独立分类器）。
public struct AutoClassifier {
    let chat: ChatClient
    /// 文档正文喂模型的字数上限（与 MarkdownTidier/摘要量级一致，防长文档撑爆 prompt）。
    let maxContentChars: Int

    public init(config: Config, model: String? = nil, maxContentChars: Int = 16000) {
        self.chat = ChatClient(config: config, modelOverride: model ?? config.correctModel)
        self.maxContentChars = maxContentChars
    }

    // MARK: 录音 → 文件夹（单选）

    /// 二选一：`existingId`（命中现有）或 `newName`（提议新建）；都为 nil 表示无建议。
    public struct FolderSuggestion: Equatable {
        public let existingId: String?
        public let newName: String?
        public init(existingId: String? = nil, newName: String? = nil) {
            self.existingId = existingId; self.newName = newName
        }
    }

    public func suggestFolder(summary: String, title: String,
                              existingFolders: [LibraryFolder]) async throws -> FolderSuggestion? {
        let names = existingFolders.map { $0.name }
        let folderList = names.isEmpty ? "（暂无文件夹）" : names.map { "- \($0)" }.joined(separator: "\n")
        let system = """
        你帮用户把会议录音归入文件夹。根据录音标题与摘要，从「现有文件夹」里挑**最合适的一个**。
        按顺序判断：
        1. 若某个现有文件夹的主题/对象/系列与本录音明显吻合（同一个人的 1-on-1、同一个产品/项目/团队），就**果断选它**，不要犹豫。
        2. 现有文件夹都不沾边、但录音主题清晰值得单独成组，才提议一个简洁新文件夹名（中文优先、3-8 字，概括主题/系列）。
        3. 只有当主题模糊、信息不足、且无现有文件夹合适时，才不归类。
        只输出 JSON，不要解释：
        - 选现有：{"action":"existing","folder":"<现有文件夹的完整名字，逐字照抄>"}
        - 提新建：{"action":"new","folder":"<新文件夹名>"}
        - 不归类：{"action":"none"}
        """
        let user = """
        现有文件夹：
        \(folderList)

        录音标题：\(title)
        录音摘要：
        \(summary.prefix(maxContentChars))
        """
        let raw = try await chat.complete(system: system, user: user, maxTokens: 200, temperature: 0)
        guard let obj = parseJSONObject(raw),
              let action = (obj["action"] as? String)?.lowercased() else { return nil }
        switch action {
        case "existing":
            guard let name = (obj["folder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let f = matchFolder(name, in: existingFolders) else { return nil }
            return FolderSuggestion(existingId: f.id)
        case "new":
            guard let name = cleanName(obj["folder"]) else { return nil }
            // 提的新名若大小写不敏感命中现有 → 归并为选中现有，避免重复建。
            if let f = matchFolder(name, in: existingFolders) { return FolderSuggestion(existingId: f.id) }
            return FolderSuggestion(newName: name)
        default:
            return nil
        }
    }

    // MARK: 文档 → tag（0-2 个核心）

    public struct TagSuggestion: Equatable {
        public let tag: String
        public let isNew: Bool
        public init(tag: String, isNew: Bool) { self.tag = tag; self.isNew = isNew }
    }

    public func suggestTags(content: String, title: String,
                            existingTags: [String]) async throws -> [TagSuggestion] {
        let tagList = existingTags.isEmpty ? "（暂无 tag）" : existingTags.map { "- \($0)" }.joined(separator: "\n")
        let system = """
        你帮用户给文档打 tag。根据标题与正文，给出**最核心的 1-2 个** tag（主题/类型/项目）。
        规则：
        - **只要正文有可辨认的主题（绝大多数文档都有），就必须给至少 1 个 tag**；能复用下面「现有 tag」就复用，没有合适的就提议简洁新 tag（中文优先、2-6 字）。
        - 1 个够准就给 1 个，别为凑数硬加第 2 个；最多 2 个。
        - **仅当**正文完全空白、纯乱码、或短到毫无主题时，才返回空数组——这是极少数情况。
        只输出 JSON，不要解释：
        {"tags":[{"name":"<tag>","new":true 或 false}]}
        """
        let user = """
        现有 tag：
        \(tagList)

        文档标题：\(title)
        文档正文：
        \(content.prefix(maxContentChars))
        """
        // 空结果对有主题的文档应是罕见例外；推理模型在 temp 0 下仍偶发返回空 → 空则重试一次兜底。
        for attempt in 0..<2 {
            let raw = try await chat.complete(system: system, user: user, maxTokens: 200, temperature: 0)
            let out = parseTagSuggestions(raw, existingTags: existingTags)
            if !out.isEmpty || attempt == 1 { return out }
        }
        return []
    }

    private func parseTagSuggestions(_ raw: String, existingTags: [String]) -> [TagSuggestion] {
        guard let obj = parseJSONObject(raw), let arr = obj["tags"] as? [[String: Any]] else { return [] }
        var out: [TagSuggestion] = []
        var seen = Set<String>()
        for item in arr.prefix(2) {
            guard let name = cleanName(item["name"]) else { continue }
            let key = name.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            // 命中现有 tag（大小写不敏感）→ 标记为复用、并用现有写法。
            if let existing = existingTags.first(where: { $0.lowercased() == key }) {
                out.append(TagSuggestion(tag: existing, isNew: false))
            } else {
                out.append(TagSuggestion(tag: name, isNew: true))
            }
        }
        return out
    }

    // MARK: helpers

    private func matchFolder(_ name: String, in folders: [LibraryFolder]) -> LibraryFolder? {
        let key = name.lowercased()
        return folders.first { $0.name.lowercased() == key }
    }

    private func cleanName(_ any: Any?) -> String? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

/// 从模型输出里抽出 JSON 对象：容忍 ```json 围栏、前后多余文字（取第一个 `{` 到最后一个 `}`）。
func parseJSONObject(_ raw: String) -> [String: Any]? {
    guard let lo = raw.firstIndex(of: "{"), let hi = raw.lastIndex(of: "}"), lo < hi else { return nil }
    let slice = String(raw[lo...hi])
    return (try? JSONSerialization.jsonObject(with: Data(slice.utf8))) as? [String: Any]
}
