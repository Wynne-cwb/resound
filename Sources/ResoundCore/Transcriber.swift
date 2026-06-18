import Foundation
import WhisperKit

public struct TranscribeResult {
    public let transcript: Transcript
    public let modelName: String   // 写进 provenance.asr_model
}

/// WhisperKit 封装：音频 → 词级时间戳转录 → 契约 Transcript。
public struct Transcriber {
    public let model: String

    public init(model: String = "large-v3") {
        self.model = model
    }

    public func transcribe(audio: URL) async throws -> TranscribeResult {
        let pipe = try await WhisperKit(WhisperKitConfig(model: model))

        let options = DecodingOptions(wordTimestamps: true)
        let results = try await pipe.transcribe(audioPath: audio.path, decodeOptions: options)

        var segments: [Transcript.Segment] = []
        var idx = 0
        for result in results {
            for seg in result.segments {
                let words: [Transcript.Word] = (seg.words ?? []).map { wt in
                    Transcript.Word(
                        w: wt.word.trimmingCharacters(in: .whitespaces),
                        start: Double(wt.start),
                        end: Double(wt.end)
                    )
                }
                segments.append(
                    Transcript.Segment(
                        id: idx,
                        start: Double(seg.start),
                        end: Double(seg.end),
                        text: cleanWhisperText(seg.text),
                        words: words
                    )
                )
                idx += 1
            }
        }

        let language = results.first?.language ?? "unknown"
        return TranscribeResult(
            transcript: Transcript(language: language, segments: segments),
            modelName: "whisperkit-\(model)"
        )
    }
}

/// 去掉 WhisperKit 的特殊 token（<|...|>），返回干净文本。
func cleanWhisperText(_ s: String) -> String {
    let cleaned = s.replacingOccurrences(
        of: "<\\|[^|]*\\|>", with: "", options: .regularExpression
    )
    return cleaned.trimmingCharacters(in: .whitespaces)
}
