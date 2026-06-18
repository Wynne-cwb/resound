import Foundation

/// LLM 重排：把 hybrid 召回的候选交给 chat 模型按相关度重排，取前 topK。
public struct Reranker {
    let chat: ChatClient
    public init(chat: ChatClient) { self.chat = chat }

    public func rerank(query: String, candidates: [SearchHit], topK: Int) async throws -> [SearchHit] {
        guard !candidates.isEmpty else { return [] }

        let system = """
        你是检索重排器。根据用户查询，从候选段落中选出最相关的，按相关度从高到低排序。
        只输出一个 JSON 整数数组（段落编号，从 1 开始），最多 \(topK) 个，不要任何解释或代码块。
        例如：[3,1,7]
        """
        var listing = ""
        for (i, c) in candidates.enumerated() {
            listing += "[\(i + 1)] \(c.text.prefix(300))\n"
        }
        let user = "查询：\(query)\n\n候选段落：\n\(listing)\n只输出 JSON 数组，最多 \(topK) 个编号。"

        let raw = try await chat.complete(system: system, user: user)
        let order = parseIntArray(raw)

        // 按 LLM 给的顺序映射回候选；越界/重复丢弃
        var seen = Set<Int>()
        var result: [SearchHit] = []
        for n in order where n >= 1 && n <= candidates.count && !seen.contains(n) {
            seen.insert(n)
            result.append(candidates[n - 1])
            if result.count == topK { break }
        }
        // LLM 给得不足 topK，用原 RRF 顺序补齐
        if result.count < topK {
            for (i, c) in candidates.enumerated() where !seen.contains(i + 1) {
                result.append(c)
                if result.count == topK { break }
            }
        }
        return result
    }
}

/// 从模型输出里抽第一个 [ ... ] 整数数组。
func parseIntArray(_ s: String) -> [Int] {
    guard let lo = s.firstIndex(of: "["), let hi = s[lo...].firstIndex(of: "]") else { return [] }
    let inner = s[s.index(after: lo)..<hi]
    return inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" })
        .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
}
