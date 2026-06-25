import Foundation

// MARK: - 「向本文档提问」每篇文档的对话持久化（按 docId 分桶）
//
// 与录音的 rec-chats.json、全局 conversations.json 都分开：这里是「绑定到某篇文档」的
// 轻量问答，切换文档/重启 App 都应保留各自的对话，故落盘独立文件，按 docId 索引。
// 结构与 RecAskStore 对称，但文档引用没有说话人/时间轴，cite 用文档自身（标题/段落）。

struct StoredDocCite: Codable {
    var snippet: String
}
struct StoredDocMsg: Codable, Identifiable {
    var id = UUID()
    var isUser: Bool
    var text: String
    var cites: [StoredDocCite] = []
    var ts: Date
}

/// 落盘：~/Library/Application Support/Resound/doc-chats.json —— { docId: [消息…] }（本地 App 状态，不进 vault）。
struct DocAskStore {
    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Resound/doc-chats.json")
    }
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    func load() -> [String: [StoredDocMsg]] {
        guard let data = try? Data(contentsOf: url),
              let map = try? Self.decoder.decode([String: [StoredDocMsg]].self, from: data) else { return [:] }
        return map
    }

    func save(_ map: [String: [StoredDocMsg]]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pruned = map.filter { !$0.value.isEmpty }
        if let data = try? Self.encoder.encode(pruned) { try? data.write(to: url, options: .atomic) }
    }
}
