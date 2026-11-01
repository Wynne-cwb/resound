import Foundation

/// 转录结果（在线 whisper / MOSS 共用）。原与本地 WhisperKit 封装同文件，
/// 2026-11-01 移除本地模型后抽出独立保留。
public struct TranscribeResult {
    public let transcript: Transcript
    public let modelName: String   // 写进 provenance.asr_model

    public init(transcript: Transcript, modelName: String) {
        self.transcript = transcript
        self.modelName = modelName
    }
}
