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
}
