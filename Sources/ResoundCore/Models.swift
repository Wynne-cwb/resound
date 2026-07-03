import Foundation

/// transcript.json — schema: resound.transcript/1
public struct Transcript: Codable {
    public let schema: String
    public let language: String
    public let segments: [Segment]

    public init(language: String, segments: [Segment]) {
        self.schema = "resound.transcript/1"
        self.language = language
        self.segments = segments
    }

    public struct Segment: Codable {
        public let id: Int
        public let start: Double
        public let end: Double
        public let text: String
        public let words: [Word]
        /// 分轨录音时段落来自哪条轨："mic"（本地麦克风）/ "system"（线上系统音频）。
        /// 混音转录/旧数据为 nil。留作说话人归属先验 + 调试。
        public let track: String?

        public init(id: Int, start: Double, end: Double, text: String, words: [Word], track: String? = nil) {
            self.id = id
            self.start = start
            self.end = end
            self.text = text
            self.words = words
            self.track = track
        }
    }

    public struct Word: Codable {
        public let w: String
        public let start: Double
        public let end: Double

        public init(w: String, start: Double, end: Double) {
            self.w = w
            self.start = start
            self.end = end
        }
    }

    public func jsonData() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try enc.encode(self)
    }
}

/// recording.yaml — schema: resound.recording/1
/// 人可编辑，手写 YAML（依赖少；将来需要解析时再引入 Yams）。
public struct RecordingManifest {
    public let id: String
    public let title: String
    public let recordedAt: String   // ISO8601, 带时区
    public let durationSec: Int
    public let source: String
    public let language: String
    public let tags: [String]
    public let audioFile: String
    public let asrModel: String

    public init(id: String, title: String, recordedAt: String, durationSec: Int,
                source: String, language: String, tags: [String],
                audioFile: String, asrModel: String) {
        self.id = id
        self.title = title
        self.recordedAt = recordedAt
        self.durationSec = durationSec
        self.source = source
        self.language = language
        self.tags = tags
        self.audioFile = audioFile
        self.asrModel = asrModel
    }

    public func yaml() -> String {
        let tagList = tags.map { yamlQuote($0) }.joined(separator: ", ")
        return """
        schema: resound.recording/1
        id: \(yamlQuote(id))
        title: \(yamlQuote(title))
        recorded_at: \(recordedAt)
        duration_sec: \(durationSec)
        source: \(yamlQuote(source))
        language: \(yamlQuote(language))
        tags: [\(tagList)]
        audio_file: \(yamlQuote(audioFile))

        provenance:
          asr_model: \(yamlQuote(asrModel))
          diarization_model: null
          speaker_embed_model: null

        """
    }
}

/// 最小 YAML 字符串转义：双引号包裹，转义反斜杠与双引号。
func yamlQuote(_ s: String) -> String {
    let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}
