import Foundation

/// 问答前的查询规划（v2）：让 LLM 从问题里抽出
/// ① 检索形状 shape（qa / digest / timeline / compare）
/// ② 过滤条件 filters（录音时间 / 说话人 / 来源，可组合）
/// ③ 近因意图 recency（"最新/现状"→ 按录音日期加权）
/// ④ compare 的两个集合 compareSets
/// 传入今天日期+星期作锚点，能解析"昨天/上周三/这个月"等中文时间表达。
/// 失败/判不准一律安全回退到「无过滤的普通问答」，绝不空手挡死（见 plan() 末尾兜底）。
public struct QueryPlanner {
    let chat: ChatClient
    public init(chat: ChatClient) { self.chat = chat }

    public enum Shape: String { case qa, digest, timeline, compare }
    public enum Source: String { case recording, document, both }

    /// compare 的单个集合（各自带过滤条件 + 给用户看的标签）。
    public struct FilterSet {
        public let label: String
        public let dateFrom: String?
        public let dateTo: String?
        public let speakers: [String]?
        public init(label: String, dateFrom: String?, dateTo: String?, speakers: [String]?) {
            self.label = label; self.dateFrom = dateFrom; self.dateTo = dateTo; self.speakers = speakers
        }
        public var dateRange: Index.DateRange? {
            if let f = dateFrom, let t = dateTo { return (from: f, to: t) }
            return nil
        }
    }

    public struct Plan {
        public let query: String          // 清洗后的检索词（话题；话题里的时间词保留）
        public let dateFrom: String?      // yyyy-MM-dd（含）—— 仅"录音发生时间"
        public let dateTo: String?
        public let speakers: [String]?    // 按说话人筛（chunks.person_id）
        public let source: Source         // recording / document / both
        public let shape: Shape
        public let recency: Bool          // "最新/现状"→ 近因加权
        public let compareSets: [FilterSet]?

        public init(query: String, dateFrom: String?, dateTo: String?,
                    speakers: [String]? = nil, source: Source = .both,
                    shape: Shape = .qa, recency: Bool = false, compareSets: [FilterSet]? = nil) {
            self.query = query; self.dateFrom = dateFrom; self.dateTo = dateTo
            self.speakers = speakers; self.source = source
            self.shape = shape; self.recency = recency; self.compareSets = compareSets
        }

        public var dateRange: Index.DateRange? {
            if let f = dateFrom, let t = dateTo { return (from: f, to: t) }
            return nil
        }
        /// 是否带了任何过滤（时间/人/来源），供调试 chip 展示。
        public var hasFilter: Bool {
            dateRange != nil || (speakers?.isEmpty == false) || source != .both
        }
    }

    /// 规划。失败一律回退到「无时间过滤的普通问答」，不阻断主流程。
    public func plan(_ question: String, history: [ChatTurn] = [], now: Date = Date()) async -> Plan {
        let today = localDate(now)
        let weekday = weekdayZh(now)
        let system = """
        你是检索查询规划器。根据用户问题输出 JSON（只输出 JSON，无其他文字）：
        {"query": string,
         "shape": "qa"|"digest"|"timeline"|"compare",
         "filters": {"date_from": string|null, "date_to": string|null, "speakers": [string]|null, "source": "recording"|"document"|"both"},
         "recency": boolean,
         "compare_sets": null | [ {"label": string, "date_from": string|null, "date_to": string|null, "speakers": [string]|null},  {...} ]}

        今天是 \(today)（\(weekday)）。规则：

        【shape 选哪种】
        - "qa"：问具体事实/细节，或"谁负责 X""X 是什么"——精准定位。默认值。
        - "digest"：要概览/汇总/回顾，或"有哪些会、聊了啥"，或**跨较大时间范围的主题回顾**（如"今年做了哪些管理改进"）。
        - "timeline"：要"怎么演变/发展历程/关键节点/一步步到现在"。
        - "compare"：出现"A 和 B 的区别/差异/不同/对比/相比/各自"等，要对照两组 → 必须同时给出 compare_sets 的两个集合。

        【filters.date_from / date_to —— 仅用于按"录音发生的时间"筛选】
        - 只有当时间词描述"这场录音/会议/对话发生在什么时候"才填日期范围（含两端，yyyy-MM-dd）。
          例："昨天的1on1"→昨天；"上周开了哪些会"→上周一到周日；"这个月录的"→本月1号到今天；"6月有哪些会"→6月。
        - **若时间词只是被讨论话题的一部分**（修饰"规划/计划/目标/预算/路线图"等名词，问的是内容而非录音时间），则两端必须 null、时间词保留在 query。
          例："下半年的规划是什么""Q3 的目标""明年的计划""2025年的预算怎么定的"——这些 date_from/date_to 都为 null。

        【filters.speakers —— 按说话人筛】
        - 出现具体人名且语义是"按这个人筛内容"（"Jerry 都说过什么""Hydra 最近关心啥"）→ 填人名数组。
        - **"我/我们/自己" 指提问者本人，不是可筛选的说话人**：遇到"我和 Jerry""Jerry 和我聊了啥"，只填 ["Jerry"]，忽略"我"；不要因为出现"我"就把 speakers 置空。
        - 若人名是"被问的答案"（"谁负责 OS 迁移"）→ speakers 为 null，走 qa。

        【filters.source —— 来源】
        - 明确"那份文档里/根据文档"→ "document"；"会上/录音里"→ "recording"；默认 "both"。

        【recency —— 近因意图】
        - 出现"最新/目前/现在/现状/截至现在"且问的是某事的当前状态 → true（让最近的讨论优先）；否则 false。

        【compare_sets —— 仅 shape=compare】
        - 解析出要对比的两个集合，各自带 label + 过滤条件（如"这周 vs 上周的1on1"→两个集合各带日期范围）。其它 shape 一律 null。

        【query】
        - 核心检索词。去掉的是"录音时间状语"（"昨天的1on1聊了什么"→"1on1"）；**话题里的时间词要保留**（"下半年的规划"→"下半年的规划"）。
        - 若有对话历史，把当前问题里的指代补全进 query（历史在聊"张三"，问"他还说了啥"→query 写"张三"）。

        【示例】（假设今天 2026-06-26 周五）
        - "这周和上周的1on1有什么不同" →
          {"query":"1on1","shape":"compare","filters":{"date_from":null,"date_to":null,"speakers":null,"source":"both"},"recency":false,"compare_sets":[{"label":"这周","date_from":"2026-06-22","date_to":"2026-06-26","speakers":null},{"label":"上周","date_from":"2026-06-15","date_to":"2026-06-21","speakers":null}]}
        - "我和 Jerry 都聊过什么" →
          {"query":"聊过的内容","shape":"qa","filters":{"date_from":null,"date_to":null,"speakers":["Jerry"],"source":"both"},"recency":false,"compare_sets":null}
        - "OS 下半年的规划是什么" →
          {"query":"下半年的规划","shape":"qa","filters":{"date_from":null,"date_to":null,"speakers":null,"source":"both"},"recency":false,"compare_sets":null}
        - "OS 目前最新的迁移策略" →
          {"query":"迁移策略","shape":"qa","filters":{"date_from":null,"date_to":null,"speakers":null,"source":"both"},"recency":true,"compare_sets":null}
        """
        let hist = renderHistory(history)
        let userMsg = hist.isEmpty ? question : "对话历史：\n\(hist)\n当前问题：\(question)"
        do {
            let raw = try await chat.complete(system: system, user: userMsg, maxTokens: 500)
            return dropFutureRange(parse(raw, fallback: question), today: today)
        } catch {
            return Plan(query: question, dateFrom: nil, dateTo: nil)
        }
    }

    private func parse(_ raw: String, fallback: String) -> Plan {
        // 容错：剥掉 ```json fences，截取首尾大括号。
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "{"), let e = s.range(of: "}", options: .backwards) {
            s = String(s[r.lowerBound...e.lowerBound])
        }
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Plan(query: fallback, dateFrom: nil, dateTo: nil)
        }
        let filters = obj["filters"] as? [String: Any] ?? [:]
        func str(_ d: [String: Any], _ k: String) -> String? {
            guard let v = d[k] as? String, !v.isEmpty, v.lowercased() != "null" else { return nil }
            return v
        }
        func speakerList(_ d: [String: Any]) -> [String]? {
            guard let arr = d["speakers"] as? [Any] else { return nil }
            let names = arr.compactMap { ($0 as? String).flatMap { $0.isEmpty ? nil : $0 } }
            return names.isEmpty ? nil : names
        }
        let shape = Shape(rawValue: (obj["shape"] as? String) ?? "qa") ?? .qa
        let source = Source(rawValue: (filters["source"] as? String) ?? "both") ?? .both
        let recency = (obj["recency"] as? Bool) ?? false

        var compareSets: [FilterSet]? = nil
        if shape == .compare, let arr = obj["compare_sets"] as? [[String: Any]], arr.count >= 2 {
            compareSets = arr.prefix(2).enumerated().map { (i, d) in
                FilterSet(label: str(d, "label") ?? "集合\(i + 1)",
                          dateFrom: str(d, "date_from"), dateTo: str(d, "date_to"),
                          speakers: speakerList(d))
            }
        }
        return Plan(query: str(obj, "query") ?? fallback,
                    dateFrom: str(filters, "date_from"), dateTo: str(filters, "date_to"),
                    speakers: speakerList(filters), source: source,
                    shape: shape, recency: recency, compareSets: compareSets)
    }

    /// 防御：纯未来的日期范围不可能是「录音发生时间」（录音只存在于过去）。
    /// 多半是把话题里的时间词（如"下半年的规划"）误当成了录音筛选 → 丢弃范围，退回无过滤。
    private func dropFutureRange(_ p: Plan, today: String) -> Plan {
        guard let from = p.dateFrom, from > today else { return p }
        return Plan(query: p.query, dateFrom: nil, dateTo: nil,
                    speakers: p.speakers, source: p.source,
                    shape: p.shape, recency: p.recency, compareSets: p.compareSets)
    }
}
