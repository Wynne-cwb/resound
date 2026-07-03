import Foundation

/// 第二档：词级说话人归属 + 句级众数平滑 + 按句重组 spans。
///
/// 行业标准（WhisperX / NeMo / whisper-diarization / pyannote 官方一致，见
/// superpowers/specs/2026-07-02-speaker-attribution-research.md）：
///   1. 每个词按「与 diar 轮次的重叠时长最大」定初始说话人（比整段更细）；
///   2. **句级众数投票平滑**——换人点若落在句子中间（词不以句末标点结尾），把该句整句按词众数归一
///      （众数 ≥ 半数才覆写，句窗上限 maxWordsPerSentence，找不到句边界就保守不改）。这是关键护栏：
///      diar 边界不准 → 只信「句子结构」这个语言学信号，换人只允许发生在句末标点处；
///   3. 按平滑后的说话人变化重组成 spans（切点永远落词/句边界，不产生亚词碎片）。
///
/// 2026-06-24「换人切句」回退的根因正是缺了第 2 步（当时在 diar 边界硬切 + 打补丁去毛刺）。本实现补上。
/// 段无词级时间戳（words 空）时该段整体按 wholeSegmentSpeaker 归属（回退第一档的段级重叠投票）。
public enum SpeakerAttribution {

    /// 中英文句末标点。
    static let sentenceEnders: Set<Character> = ["。", "！", "？", ".", "!", "?", "；", ";", "…"]

    struct WordSpk {
        let start: Double
        let end: Double
        let text: String
        var spk: String
        let endsSentence: Bool   // 该词文本以句末标点结尾
    }

    /// - Parameters:
    ///   - wordSpeaker: 词区间 → 说话人名（词级重叠投票，已映射到最终名字）；返回 nil 用段级兜底。
    ///   - wholeSegmentSpeaker: 段区间 → 说话人名（第一档段级重叠投票），供无词段/词归属失败兜底。
    public static func attribute(
        segments: [Transcript.Segment],
        wordSpeaker: (Double, Double) -> String?,
        wholeSegmentSpeaker: (Double, Double) -> String?,
        maxWordsPerSentence: Int = 50,
        log: (String) -> Void = { _ in }
    ) -> [SpeakerSeg] {
        // 1) 摊平成词流；无词的段落造一个「伪词」占位（整段一个说话人）。
        var words: [WordSpk] = []
        for seg in segments {
            let segSpk = wholeSegmentSpeaker(seg.start, seg.end) ?? "?"
            if seg.words.isEmpty {
                words.append(WordSpk(start: seg.start, end: seg.end, text: seg.text,
                                     spk: segSpk, endsSentence: true))   // 整段视作一句
            } else {
                for w in seg.words {
                    let spk = wordSpeaker(w.start, w.end) ?? segSpk
                    let trimmed = w.w.trimmingCharacters(in: .whitespaces)
                    let ends = trimmed.last.map { sentenceEnders.contains($0) } ?? false
                    words.append(WordSpk(start: w.start, end: w.end, text: w.w, spk: spk, endsSentence: ends))
                }
            }
        }
        guard !words.isEmpty else { return [] }

        // 2) 句级众数投票平滑：换人点落句中 → 找该句 [lo,hi]（以句末标点为界）→ 众数归一。
        var smoothed = 0
        var k = 0
        while k < words.count - 1 {
            if words[k].spk != words[k + 1].spk && !words[k].endsSentence {
                // 换人发生在句子内部（k 不是句尾）→ 定位包含 k 与 k+1 的整句边界
                let lo = sentenceStart(words, around: k, maxWords: maxWordsPerSentence)
                let hi = sentenceEnd(words, around: k, maxWords: maxWordsPerSentence)
                if lo >= 0 && hi >= 0 && hi > lo {
                    // 众数
                    var tally: [String: Int] = [:]
                    for i in lo...hi { tally[words[i].spk, default: 0] += 1 }
                    if let (mode, cnt) = tally.max(by: { $0.value < $1.value }),
                       cnt >= (hi - lo + 1) / 2 + (hi - lo + 1) % 2,   // ≥ 半数（向上取整）
                       mode != "?" {
                        for i in lo...hi where words[i].spk != mode { words[i].spk = mode; smoothed += 1 }
                    }
                    k = hi + 1   // 跳到句尾之后
                    continue
                }
            }
            k += 1
        }
        if smoothed > 0 { log("   ✏️ 句级众数平滑：修正 \(smoothed) 个句中错词") }

        // 3) 按说话人变化重组 spans（切点=词边界）。
        var out: [SpeakerSeg] = []
        var i = 0
        while i < words.count {
            var j = i
            while j + 1 < words.count && words[j + 1].spk == words[i].spk { j += 1 }
            out.append(SpeakerSeg(start: words[i].start, end: words[j].end, speaker: words[i].spk))
            i = j + 1
        }
        return out
    }

    /// 从 idx 向左找句首：越过同一句（无句末标点）的词，直到上一句的句末标点之后或窗上限。
    private static func sentenceStart(_ w: [WordSpk], around idx: Int, maxWords: Int) -> Int {
        var lo = idx
        var steps = 0
        while lo > 0 && steps < maxWords {
            if w[lo - 1].endsSentence { break }   // 上一词是句尾 → lo 即句首
            lo -= 1; steps += 1
        }
        return steps < maxWords ? lo : -1
    }

    /// 从 idx+1 向右找句尾：直到遇到句末标点或窗上限。
    private static func sentenceEnd(_ w: [WordSpk], around idx: Int, maxWords: Int) -> Int {
        var hi = idx + 1
        var steps = 0
        while hi < w.count && steps < maxWords {
            if w[hi].endsSentence { return hi }
            hi += 1; steps += 1
        }
        return -1   // 窗内没找到句尾 → 放弃（保守不改）
    }
}
