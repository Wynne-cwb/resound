import Foundation

/// 文档排版整理（P3）——把 PDF 文本层 / 图片 OCR 提取出的、排版混乱的文本，用快速模型（correctModel）
/// 在**严格保持语义**的前提下整理成可读 Markdown：合并错误断行、识别标题/列表/表格、去乱码空白。
/// （关键是明确的 reflow prompt——给够"删页眉页脚/合并标题/重建表格"的授权，flash 即可胜任。）
///
/// 安全第一：**绝不增删改/总结/翻译内容**；任何异常、模型吞内容（输出骤短）→ 回退原文。
/// 长文按行分批（每批受 maxBatchChars 限制）、限并发整理后按序拼回，避免超模型上下文。
public struct MarkdownTidier {
    let chat: ChatClient
    private let maxBatchChars = 4000
    private let maxConcurrent = 4

    public init(chat: ChatClient) { self.chat = chat }

    public func tidy(_ raw: String, log: (String) -> Void = { _ in }) async -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 40 else { return raw }   // 太短不值当整理

        let batches = Self.segment(raw, maxChars: maxBatchChars)
        var out: [String] = []
        var idx = 0
        while idx < batches.count {
            let upper = min(idx + maxConcurrent, batches.count)
            let wave = Array(batches[idx..<upper])
            let tidied: [String] = await withTaskGroup(of: (Int, String).self) { group in
                for (i, b) in wave.enumerated() {
                    group.addTask { (i, await self.tidyBatch(b)) }
                }
                var tmp = [String](repeating: "", count: wave.count)
                for await (i, s) in group { tmp[i] = s }
                return tmp
            }
            out.append(contentsOf: tidied)
            idx = upper
        }
        let joined = out.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // 全局安全闸：整理后字数 < 原始一半 → 判定模型把内容吞了 → 回退原文。
        if joined.count < trimmed.count / 2 {
            log("  ⚠️ 排版整理结果异常偏短（\(joined.count)/\(trimmed.count)），回退原始提取文本")
            return raw
        }
        return joined
    }

    /// 整理单批；失败/可疑（输出骤短）→ 回退该批原文，保证不丢内容。
    private func tidyBatch(_ batch: String) async -> String {
        let base = batch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return batch }
        let system = """
        你是文档排版整理助手。下面是从 PDF / 图片 OCR 自动提取的文本，**断行混乱、夹杂大量版式噪声**。
        任务：在**保留全部实质信息**（事实、数据、结论、表格里的内容）的前提下，整理成**干净、易读的 Markdown**。

        请积极地做这些（这是整理重点，别畏手畏脚）：
        - 把被硬换行拆开的同一句 / 同一段接回成完整段落；
        - **删除重复出现的页眉 / 页脚 / 页码 / 导出水印**——例如每页重复的网址、"x/11" 这类页码、"Press 'space' for AI" 提示、导出时间戳等噪声；
        - 把被拆成几行的标题合并成一个标题，按层级用 # / ## / ###；
        - 把挤在一起或散开错位的表格重建成 Markdown 表格（| 列 | 列 |）；
        - 列表用 - 或 1.；删掉 OCR 乱码和多余空行。

        不要做：改写措辞、总结、翻译、增加原文没有的信息、改动数字 / 专有名词 / 术语的写法。
        实质内容一字不丢，但版式噪声该删就删。直接输出整理后的 Markdown，不要任何开场白、解释或代码围栏。
        """
        do {
            let out = try await chat.complete(system: system, user: batch, maxTokens: 8192, temperature: 0.3)
            let cleaned = Self.stripCodeFence(out).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count < base.count / 2 { return batch }   // 吞内容/截断 → 回退本批
            return cleaned
        } catch {
            AppLog.error("排版整理批次失败（回退原文）", error)
            return batch
        }
    }

    /// 按行累积切批，尽量不在行内截断（PDF/OCR 的行本就有边界）。
    static func segment(_ text: String, maxChars: Int) -> [String] {
        var batches: [String] = []
        var cur = ""
        for line in text.components(separatedBy: "\n") {
            if !cur.isEmpty, cur.count + line.count + 1 > maxChars {
                batches.append(cur); cur = ""
            }
            cur += (cur.isEmpty ? "" : "\n") + line
        }
        if !cur.isEmpty { batches.append(cur) }
        return batches.isEmpty ? [text] : batches
    }

    /// 去掉模型偶尔自作主张加的 ``` / ```markdown 代码围栏。
    static func stripCodeFence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
            if t.hasSuffix("```") { t = String(t.dropLast(3)) }
        }
        return t
    }
}

/// 对 PDF / 图片 OCR 的提取结果做排版整理；其它格式或无 config 时原样返回。App 与 CLI 共用。
public func tidiedExtraction(_ result: ExtractResult, config: Config?, model: String? = nil,
                             log: @escaping (String) -> Void = { _ in }) async -> ExtractResult {
    guard let config,
          result.sourceFormat == "pdf" || result.sourceFormat == "image",
          !result.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return result }
    // 默认用快速模型 correctModel（v4-flash）：配上明确的 reflow prompt 后实测能稳定整理
    // （标题合并/删页眉页脚/重建表格）。需要时可用 model 覆盖成更强模型。
    let tidyModel = model ?? config.correctModel
    log("🪄 排版整理中（\(tidyModel)）…")
    let chat = ChatClient(config: config, modelOverride: tidyModel)
    let tidied = await MarkdownTidier(chat: chat).tidy(result.markdown, log: log)
    var r = result
    r.markdown = tidied
    return r
}
