import Foundation

public struct Chunk {
    public let index: Int
    public let text: String
    public let start: Double
    public let end: Double
}

/// 把转录的细碎 segment 合并成检索用的 chunk。
/// 当前按字数窗口 + 时间间隔切（说话人轮次留待 diarization 落地后细化）。
public struct Chunker {
    public let targetChars: Int
    public let maxChars: Int
    public let gapSeconds: Double

    public init(targetChars: Int = 300, maxChars: Int = 500, gapSeconds: Double = 4.0) {
        self.targetChars = targetChars
        self.maxChars = maxChars
        self.gapSeconds = gapSeconds
    }

    public func chunk(_ transcript: Transcript) -> [Chunk] {
        var chunks: [Chunk] = []
        var buf = ""
        var start: Double? = nil
        var lastEnd: Double = 0
        var idx = 0

        func flush() {
            let text = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, let s = start {
                chunks.append(Chunk(index: idx, text: text, start: s, end: lastEnd))
                idx += 1
            }
            buf = ""
            start = nil
        }

        for seg in transcript.segments {
            // 大停顿且已有足够内容 → 先在此切开（近似话题/轮次边界）
            if start != nil, seg.start - lastEnd > gapSeconds, buf.count >= targetChars / 2 {
                flush()
            }
            if start == nil { start = seg.start }
            buf += seg.text
            lastEnd = seg.end
            if buf.count >= targetChars { flush() }
            else if buf.count >= maxChars { flush() }
        }
        flush()
        return chunks
    }

    /// 无时间轴文本（文档）切块：按空行/Markdown 标题分段，累积到 targetChars 切；
    /// 单段超 maxChars 硬切。start/end 留 0（文档无时间轴）。
    public func chunk(text: String) -> [Chunk] {
        // 1) 切成 block：空行分隔；Markdown 标题自成一 block（兼作边界 + 上下文锚）
        var blocks: [String] = []
        var cur = ""
        func pushCur() {
            let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { blocks.append(t) }
            cur = ""
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { pushCur(); continue }
            if trimmed.hasPrefix("#") { pushCur(); blocks.append(trimmed); continue }
            cur += (cur.isEmpty ? "" : "\n") + line
        }
        pushCur()

        // 2) 合并 block 到 chunk
        var chunks: [Chunk] = []
        var buf = ""
        var idx = 0
        func flush() {
            let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { chunks.append(Chunk(index: idx, text: t, start: 0, end: 0)); idx += 1 }
            buf = ""
        }
        for b in blocks {
            if b.count > maxChars {
                flush()
                var rest = Substring(b)
                while rest.count > maxChars {
                    let cut = rest.index(rest.startIndex, offsetBy: maxChars)
                    chunks.append(Chunk(index: idx, text: String(rest[..<cut]), start: 0, end: 0)); idx += 1
                    rest = rest[cut...]
                }
                buf = String(rest)
                if buf.count >= targetChars { flush() }
                continue
            }
            buf += (buf.isEmpty ? "" : "\n\n") + b
            if buf.count >= targetChars { flush() }
        }
        flush()
        return chunks
    }
}
