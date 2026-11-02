import Foundation

/// Per-request LLM usage ledger: one JSON line per chat request in
/// `~/Library/Application Support/Resound/llm-usage.jsonl`.
///
/// Why: on 2026-10-08 DeepSeek billed ~655 requests and the only way to attribute them was to
/// reconstruct call counts from chunk/segment tallies. Recording purpose + token usage (including
/// DeepSeek's prompt-cache hit/miss split) per request makes "where did the requests/tokens go"
/// a lookup (`resound llm-usage`) and gives a baseline before any token optimization.
/// Only counts and labels are written — never prompts, outputs, or keys.
public enum LLMUsageLog {
    public struct Entry: Codable {
        public var ts: String
        public var purpose: String
        public var model: String
        /// HTTP status, or -1 when the request never got a response (network error).
        public var status: Int
        public var promptTokens: Int?
        public var cacheHitTokens: Int?
        public var cacheMissTokens: Int?
        public var completionTokens: Int?
        public var reasoningTokens: Int?
        public var ms: Int
    }

    private static let queue = DispatchQueue(label: "resound.llm-usage")
    private static let maxBytes = 5_000_000

    public static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Resound", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("llm-usage.jsonl")
    }

    static func record(purpose: String, model: String, status: Int, usage: [String: Any]?, started: Date) {
        func int(_ k: String) -> Int? { (usage?[k] as? NSNumber)?.intValue }
        let details = usage?["completion_tokens_details"] as? [String: Any]
        let entry = Entry(
            ts: ISO8601DateFormatter.string(from: started, timeZone: .current,
                                            formatOptions: [.withInternetDateTime]),
            purpose: purpose, model: model, status: status,
            promptTokens: int("prompt_tokens"),
            cacheHitTokens: int("prompt_cache_hit_tokens"),
            cacheMissTokens: int("prompt_cache_miss_tokens"),
            completionTokens: int("completion_tokens"),
            reasoningTokens: (details?["reasoning_tokens"] as? NSNumber)?.intValue,
            ms: Int(Date().timeIntervalSince(started) * 1000))
        guard var line = try? JSONEncoder().encode(entry) else { return }
        line.append(0x0A)
        // sync, not async: a one-line append is cheap, and short-lived CLI processes would otherwise
        // exit before the write lands (the ledger then silently misses CLI runs).
        queue.sync {
            let url = fileURL
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                h.seekToEndOfFile()
                try? h.write(contentsOf: line)
            } else {
                try? line.write(to: url)
            }
            rollIfNeeded(url)
        }
    }

    /// Reads every entry whose local timestamp starts with `prefix` (e.g. "2026-10-08"); nil = all.
    public static func load(prefix: String? = nil) -> [Entry] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(separator: "\n").compactMap { line in
            guard let e = try? dec.decode(Entry.self, from: Data(line.utf8)) else { return nil }
            return (prefix.map { e.ts.hasPrefix($0) } ?? true) ? e : nil
        }
    }

    private static func rollIfNeeded(_ url: URL) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
              size > maxBytes, let data = try? Data(contentsOf: url) else { return }
        // Keep the newer half, starting at a line boundary so no entry is cut in two.
        var tail = data.suffix(maxBytes / 2)
        if let nl = tail.firstIndex(of: 0x0A) { tail = tail[tail.index(after: nl)...] }
        try? Data(tail).write(to: url)
    }
}
