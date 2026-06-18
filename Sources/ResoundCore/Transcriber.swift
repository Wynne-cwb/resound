import Foundation
import CoreML
import WhisperKit

public struct TranscribeResult {
    public let transcript: Transcript
    public let modelName: String   // 写进 provenance.asr_model
}

/// WhisperKit 封装：音频 → 词级时间戳转录 → 契约 Transcript。
public struct Transcriber {
    public let model: String
    public let language: String?        // nil = 自动检测；中英混杂建议显式 "zh"
    public let computeUnits: MLComputeUnits
    public let prompt: String?          // 词表偏置：高频专有名词/术语，提示模型按正确拼写输出
    public let maxFallback: Int         // 温度回退次数；越高越准但越慢（噪声段反复重试）

    /// 默认 computeUnits = .cpuAndGPU：绕开本机 large/small 模型首次 ANE 加载卡死的问题。
    public init(model: String = "large-v3",
                language: String? = nil,
                computeUnits: MLComputeUnits = .cpuAndGPU,
                prompt: String? = nil,
                maxFallback: Int = 5) {
        self.model = model
        self.language = language
        self.computeUnits = computeUnits
        self.prompt = prompt
        self.maxFallback = maxFallback
    }

    public func transcribe(audio: URL) async throws -> TranscribeResult {
        let compute = ModelComputeOptions(
            melCompute: computeUnits,
            audioEncoderCompute: computeUnits,
            textDecoderCompute: computeUnits
        )
        let pipe = try await WhisperKit(
            WhisperKitConfig(model: model, computeOptions: compute)
        )

        // 质量优先解码（慢但更准）：温度回退 + 压缩率/logprob/静音阈值触发重试，VAD 分块。
        var options = DecodingOptions()
        options.task = .transcribe        // 转录原语言，不要翻译成英文
        options.language = language        // 显式指定可避免中英混杂被误判
        options.wordTimestamps = true
        options.temperature = 0.0
        options.temperatureFallbackCount = maxFallback // 识别不确定时逐步升温重试
        options.compressionRatioThreshold = 2.4       // 检测重复/幻觉 → 触发回退
        options.logProbThreshold = -1.0               // 平均 logprob 过低 → 触发回退
        options.noSpeechThreshold = 0.6               // 静音段判定
        options.chunkingStrategy = .vad               // 按语音活动分块，长音频更稳

        // 词表偏置：把高频词编码成 promptTokens 当作解码上文。
        if let prompt, !prompt.isEmpty, let tokenizer = pipe.tokenizer {
            let ids = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !ids.isEmpty {
                options.promptTokens = ids
                options.usePrefillPrompt = true
            }
        }

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
