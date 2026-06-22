import Foundation

// MARK: - 持久化模型（存盘用，与 ChatVM.Msg 互转）

struct StoredCite: Codable, Identifiable {
    var id = UUID()
    var speaker, meeting, time, snippet, recId: String
    var t: Double
}
struct StoredSource: Codable, Identifiable {
    var id = UUID()
    var title, date, recId: String
}
struct StoredMsg: Codable, Identifiable {
    var id = UUID()
    var isUser: Bool
    var text: String
    var timeRange: String?
    var isDigest = false
    var cites: [StoredCite] = []
    var sources: [StoredSource] = []
}
struct Conversation: Codable, Identifiable {
    var id = UUID()
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [StoredMsg]
    var customTitle: Bool?   // 用户手动重命名过 → 不再被首条提问自动覆盖

    /// 会话预览：首条助手回答（截 38 字）→ 否则首条用户提问。
    var preview: String {
        if let a = messages.first(where: { !$0.isUser })?.text, !a.isEmpty {
            return String(a.replacingOccurrences(of: "\n", with: " ").prefix(38))
        }
        if let u = messages.first(where: { $0.isUser })?.text { return String(u.prefix(38)) }
        return "新对话"
    }
}

// MARK: - 落盘：~/Library/Application Support/Resound/conversations.json（本地 App 状态，不进 vault）

struct ChatStore {
    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Resound/conversations.json")
    }
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    /// 读全部对话，按最近更新倒序。
    func load() -> [Conversation] {
        guard let data = try? Data(contentsOf: url),
              let list = try? Self.decoder.decode([Conversation].self, from: data) else { return [] }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ list: [Conversation]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(list) { try? data.write(to: url, options: .atomic) }
    }
}
