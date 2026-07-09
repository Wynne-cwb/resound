import Foundation

// MARK: - 「向本场提问」每条录音的对话持久化（按 recId 分桶）
//
// 与 Ask Resound 的全局 conversations.json 分开：这里是「绑定到某条录音」的轻量问答，
// 切换录音/重启 App 都应保留各自的对话，故落盘到独立文件，按 recordingId 索引。

struct StoredRecCite: Codable {
    var speaker: String
    var time: Double        // 片段起点秒（点击跳转/定位用）
    var snippet: String
    var docId: String? = nil     // 旧数据缺省 nil（向后兼容）：非空 = 关联文档引用
    var docTitle: String? = nil
}
struct StoredRecMsg: Codable, Identifiable {
    var id = UUID()
    var isUser: Bool
    var text: String
    var cites: [StoredRecCite] = []
    var ts: Date
}

/// 落盘：~/Library/Application Support/Resound/rec-chats.json —— { recId: [消息…] }（本地 App 状态，不进 vault）。
struct RecAskStore {
    private var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Resound/rec-chats.json")
    }
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    func load() -> [String: [StoredRecMsg]] {
        guard let data = try? Data(contentsOf: url),
              let map = try? Self.decoder.decode([String: [StoredRecMsg]].self, from: data) else { return [:] }
        return map
    }

    func save(_ map: [String: [StoredRecMsg]]) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 不存空桶，保持文件干净
        let pruned = map.filter { !$0.value.isEmpty }
        if let data = try? Self.encoder.encode(pruned) { try? data.write(to: url, options: .atomic) }
    }
}
