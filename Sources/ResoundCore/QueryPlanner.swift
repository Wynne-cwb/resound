import Foundation

/// 问答前的查询规划：让 LLM 从问题里抽出时间范围 + 判定是「碎片问答」还是「整场汇总」。
/// 传入今天日期+星期作锚点，能解析"昨天/上周三/这个月/五月初"等任意中文时间表达。
public struct QueryPlanner {
    let chat: ChatClient
    public init(chat: ChatClient) { self.chat = chat }

    public enum Mode: String { case qa, digest }

    public struct Plan {
        public let query: String          // 清洗后的检索词（去掉时间状语）
        public let dateFrom: String?      // yyyy-MM-dd（含）
        public let dateTo: String?        // yyyy-MM-dd（含）
        public let mode: Mode
        public var dateRange: Index.DateRange? {
            if let f = dateFrom, let t = dateTo { return (from: f, to: t) }
            return nil
        }
    }

    /// 规划。失败一律回退到「无时间过滤的普通问答」，不阻断主流程。
    public func plan(_ question: String, history: [ChatTurn] = [], now: Date = Date()) async -> Plan {
        let today = localDate(now)
        let weekday = weekdayZh(now)
        let system = """
        你是检索查询规划器。根据用户问题输出 JSON（只输出 JSON，无其他文字）：
        {"query": string, "date_from": string|null, "date_to": string|null, "mode": "qa"|"digest"}
        规则：
        - 今天是 \(today)（\(weekday)）。把问题中的时间表达解析成具体日期范围（含两端），格式 yyyy-MM-dd。
          例："昨天"→date_from=date_to=昨天；"上周"→上周一到周日；"这个月"→本月1号到今天；无时间→都为 null。
        - mode：要"汇总/总结/回顾/有哪些会议/都聊了啥"这类**整体概览**→"digest"；问**具体事实/细节**→"qa"。
        - query：去掉时间状语后的核心检索词（如"昨天的1on1聊了什么"→"1on1"）；若纯时间概览可保留原问题。
        - 若有对话历史，把当前问题里的指代补全进 query（如历史在聊"张三"，问"他还说了啥"→query 写"张三"）。
        """
        let hist = renderHistory(history)
        let userMsg = hist.isEmpty ? question : "对话历史：\n\(hist)\n当前问题：\(question)"
        do {
            let raw = try await chat.complete(system: system, user: userMsg, maxTokens: 300)
            return parse(raw, fallback: question)
        } catch {
            return Plan(query: question, dateFrom: nil, dateTo: nil, mode: .qa)
        }
    }

    private func parse(_ raw: String, fallback: String) -> Plan {
        // 容错：剥掉 ```json fences
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "{"), let e = s.range(of: "}", options: .backwards) {
            s = String(s[r.lowerBound...e.lowerBound])
        }
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Plan(query: fallback, dateFrom: nil, dateTo: nil, mode: .qa)
        }
        func str(_ k: String) -> String? {
            guard let v = obj[k] as? String, !v.isEmpty, v.lowercased() != "null" else { return nil }
            return v
        }
        let mode = Mode(rawValue: (obj["mode"] as? String) ?? "qa") ?? .qa
        return Plan(query: str("query") ?? fallback,
                    dateFrom: str("date_from"), dateTo: str("date_to"), mode: mode)
    }
}
