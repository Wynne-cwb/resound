import Foundation

/// 转录后 AI 校对：在**不改原意**的前提下，修正 ASR 文本里的同音/形近错别字、错误分词、术语写法。
///
/// 关键设计——**保持段边界与时间戳不变**：
/// 不把全文当成一坨重写（那样会丢逐句时间戳、破坏 seek/说话人映射），而是把段落以
/// 「带行号的有序列表」整批送入（模型仍能看到上下文），逐行返回 `[行号] 修正文本`，按行号回填。
/// 任一批次返回行数对不上（模型跑偏/漏行）→ 该批次整体回退原文，绝不打乱对齐。
public struct TranscriptCorrector {
    let chat: ChatClient
    let glossaryTerms: [String]
    /// 已确认的「软更正」错听例子（错→对）。来自 [CorrectionLearner]：那些太短/模糊、不适合做
    /// 确定性子串替换的更正，改用上下文判断在这里 few-shot 提示模型。
    let mishearExamples: [(wrong: String, right: String)]
    let batchSize: Int

    public init(chat: ChatClient, glossaryTerms: [String] = [],
                mishearExamples: [(wrong: String, right: String)] = [], batchSize: Int = 40) {
        self.chat = chat
        self.glossaryTerms = glossaryTerms
        self.mishearExamples = mishearExamples
        self.batchSize = batchSize
    }

    /// 返回校对后的 transcript 与改动段数。失败的批次静默回退原文。
    /// 批次之间互相独立 → **并发跑**（限流 maxConcurrent），长录音从「串行 N 次 LLM」降到「约 N/并发 轮」。
    public func correct(_ transcript: Transcript, maxConcurrent: Int = 5,
                        log: (String) -> Void = { print($0) }) async throws -> (transcript: Transcript, changed: Int) {
        let segs = transcript.segments
        guard !segs.isEmpty else { return (transcript, 0) }
        let batches = stride(from: 0, to: segs.count, by: batchSize)
            .map { Array(segs[$0..<min($0 + batchSize, segs.count)]) }

        // 限流并发：每个批次返回 (批次号, 修正映射)，失败批次给空映射（回退原文）。
        var maps = [Int: [Int: String]]()
        var done = 0
        try await withThrowingTaskGroup(of: (Int, [Int: String]).self) { group in
            var next = 0
            let prime = min(maxConcurrent, batches.count)
            for _ in 0..<prime { let i = next; next += 1; group.addTask { (i, (try? await self.correctBatch(batches[i])) ?? [:]) } }
            while let (bi, map) = try await group.next() {
                maps[bi] = map; done += 1
                log("  ✍️ 校对批次 \(done)/\(batches.count)")
                if next < batches.count { let i = next; next += 1; group.addTask { (i, (try? await self.correctBatch(batches[i])) ?? [:]) } }
            }
        }

        // 按批次顺序回填（顺序无关，但保持确定性）。
        var corrected = segs
        var idxById = [Int: Int](); for (i, s) in corrected.enumerated() { idxById[s.id] = i }
        var changed = 0
        for bi in 0..<batches.count {
            guard let map = maps[bi] else { continue }
            for seg in batches[bi] {
                guard let nt = map[seg.id], nt != seg.text, let idx = idxById[seg.id] else { continue }
                corrected[idx] = Transcript.Segment(id: seg.id, start: seg.start, end: seg.end, text: nt, words: seg.words, track: seg.track)
                changed += 1
            }
        }
        return (Transcript(language: transcript.language, segments: corrected), changed)
    }

    private func correctBatch(_ batch: [Transcript.Segment], log: (String) -> Void = { _ in }) async throws -> [Int: String] {
        let termsBlock = glossaryTerms.isEmpty ? "（无）" : glossaryTerms.prefix(200).joined(separator: "、")
        let misheardBlock = mishearExamples.isEmpty ? "" : """

        【已确认的错听纠正】根据用户历史更正，以下写法基本可判定是错听，遇到时按右侧规范写法改正（仍要结合上下文判断、对不上时保持原样）：
        \(mishearExamples.prefix(80).map { "  「\($0.wrong)」→「\($0.right)」" }.joined(separator: "\n"))
        """
        let system = """
        你是中文会议转录校对员。把语音转录(ASR)文本里的明显错误改正，严格保持原意、语气和口语风格。
        只改这些：同音/近音错别字、明显错误的分词、专有名词与术语的写法。
        绝不做这些：改写润色、调整语序、增删句子、合并或拆分行、改变口语词（嗯/那个/对/啊/就是）、翻译。

        【重点：英文专名的读音错听】这是中英混说会议，ASR 常把英文专有名词按读音听错——
        错成读音相近的另一个英文词（例：platform notification → "Premium Notification"/"Plan Phone"；
        Polaris → "Paris"；AfterShip OS → "AOS"），或音译成中文（例：Share → "学"；PM → "片"）。
        请主动利用你对英文发音的了解：当某处的词（无论是英文还是中文音译）读音明显接近术语表里的某个术语、
        且在上下文里就该是那个术语时，改成术语表的规范写法。拿不准、读音差很远、或上下文对不上时，**保持原样**，宁可不改也不要瞎猜。
        术语表：\(termsBlock)\(misheardBlock)

        输入每行格式为「[行号] 原文」。请逐行输出「[行号] 修正后文本」：行号与输入一一对应、数量一致、顺序不变；
        无需修改的行也原样输出该行。只输出这些行，不要任何解释、标题或额外文字。
        """
        let user = batch
            .map { "[\($0.id)] \($0.text.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
        // 温度从 0 微调到 0.3：纯 0 太死板、不敢碰可疑的英文专名错听；0.3 给一点判断空间，
        // 又靠下方覆盖率闸 + 「拿不准就别改」约束兜住对齐与口语风格。
        let out = try await chat.complete(system: system, user: user, maxTokens: 4096, temperature: 0.3)

        var map: [Int: String] = [:]
        for raw in out.split(whereSeparator: \.isNewline) {
            let s = raw.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("["), let close = s.firstIndex(of: "]"),
                  let id = Int(s[s.index(after: s.startIndex)..<close]) else { continue }
            let text = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { map[id] = text }
        }
        // 安全闸：覆盖率不足 3/4（模型漏行/跑偏）→ 放弃该批次，全回退原文，宁可不改也不错位。
        let covered = batch.filter { map[$0.id] != nil }.count
        if covered < batch.count * 3 / 4 {
            log("  ⚠️ 校对批次覆盖 \(covered)/\(batch.count)，回退原文")
            return [:]
        }
        return map
    }
}
