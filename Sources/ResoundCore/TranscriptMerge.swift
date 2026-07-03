import Foundation

/// 分轨转录合并：麦克风轨 + 系统音频轨两份转录（已在同一时间轴上）→ 一份按时间排序的转录。
/// 去重治「混合会」场景：现场人声被本地麦克风直接收一份、又被现场另一台设备收进线上传回一份
/// （AEC 治不了这种网络级重复）——时间重叠且文本相似的段落只保留系统轨（线路级干净信号）。
public enum TranscriptMerge {

    /// mic/sys 两份转录合并成一份。段落带 track 标记；重编 id。
    public static func merge(mic: Transcript, sys: Transcript, language: String,
                             log: (String) -> Void = { _ in }) -> Transcript {
        let micTagged = mic.segments.map { tagged($0, track: "mic") }
        let sysTagged = sys.segments.map { tagged($0, track: "system") }

        // 去重：mic 段与任一 sys 段时间重叠 >50%（按较短者）且 bigram 相似 ≥0.4 → 视为同一句的重影，丢 mic 保 sys。
        var dropped = 0
        let keptMic = micTagged.filter { m in
            let dup = sysTagged.contains { s in
                overlapRatio(m, s) > 0.5 && bigramJaccard(m.text, s.text) >= 0.4
            }
            if dup { dropped += 1 }
            return !dup
        }
        if dropped > 0 { log("   🔁 分轨去重：丢弃 \(dropped) 段与线上轨重复的麦克风段") }

        let merged = (keptMic + sysTagged).sorted { $0.start < $1.start }
        let renumbered = merged.enumerated().map { i, s in
            Transcript.Segment(id: i, start: s.start, end: s.end, text: s.text, words: s.words, track: s.track)
        }
        return Transcript(language: language, segments: renumbered)
    }

    private static func tagged(_ s: Transcript.Segment, track: String) -> Transcript.Segment {
        Transcript.Segment(id: s.id, start: s.start, end: s.end, text: s.text, words: s.words, track: track)
    }

    /// 时间重叠占较短段时长的比例。
    static func overlapRatio(_ a: Transcript.Segment, _ b: Transcript.Segment) -> Double {
        let inter = min(a.end, b.end) - max(a.start, b.start)
        guard inter > 0 else { return 0 }
        let shorter = max(0.1, min(a.end - a.start, b.end - b.start))
        return inter / shorter
    }

    /// 字符 bigram Jaccard 相似度（去空白/标点后）。中文按字、英文按字符对，够判「同一句话的两份收音」。
    static func bigramJaccard(_ a: String, _ b: String) -> Double {
        let ca = normalized(a), cb = normalized(b)
        guard ca.count >= 2, cb.count >= 2 else { return ca == cb && !ca.isEmpty ? 1 : 0 }
        let ga = bigrams(ca), gb = bigrams(cb)
        let inter = ga.intersection(gb).count
        let union = ga.union(gb).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    private static func normalized(_ s: String) -> [Character] {
        s.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }

    private static func bigrams(_ chars: [Character]) -> Set<String> {
        guard chars.count >= 2 else { return [] }
        var out = Set<String>()
        for i in 0..<(chars.count - 1) { out.insert(String(chars[i]) + String(chars[i + 1])) }
        return out
    }
}
