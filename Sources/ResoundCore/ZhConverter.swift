import Foundation

/// 繁→简字符级归一（OpenCC TSCharacters 表）。清理 WhisperKit 中文输出的繁简混输。
/// 字符级足够清理 ASR 输出（沒→没、問→问、馬→马…）；少数需短语级的留待后续。
public final class ZhConverter {
    public static let shared = ZhConverter()
    private let map: [Character: Character]

    private init() {
        var m: [Character: Character] = [:]
        if let url = Bundle.module.url(forResource: "TSCharacters", withExtension: "txt"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            for line in s.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("#") { continue }
                let parts = line.split(separator: "\t")
                guard parts.count >= 2, let key = parts[0].first else { continue }
                // value 可能有多个候选（空格分隔），取第一个
                if let simp = parts[1].split(separator: " ").first?.first {
                    m[key] = simp
                }
            }
        }
        map = m
    }

    public func convert(_ s: String) -> String {
        String(s.map { map[$0] ?? $0 })
    }

    public func normalize(_ t: Transcript) -> Transcript {
        let segs = t.segments.map { seg in
            Transcript.Segment(
                id: seg.id, start: seg.start, end: seg.end,
                text: convert(seg.text),
                words: seg.words.map { Transcript.Word(w: convert($0.w), start: $0.start, end: $0.end) },
                track: seg.track)
        }
        return Transcript(language: t.language, segments: segs)
    }
}
