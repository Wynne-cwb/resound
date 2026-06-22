import Foundation

/// 在线转录：走 aihubmix 的 OpenAI 兼容 `/audio/transcriptions`（whisper-large-v3-turbo）。
/// 本地 WhisperKit 太慢 → 改上传压缩后的 m4a 异步转写，秒级返回带时间戳的段落。
public struct OnlineTranscriber {
    let baseURL: String
    let apiKey: String
    let model: String
    let language: String?
    let prompt: String?

    public init(config: Config, language: String? = nil, prompt: String? = nil) {
        self.baseURL = config.embeddingBaseURL   // aihubmix，与 embedding 同域同 key
        self.apiKey = config.embeddingKey
        self.model = config.transcribeModel
        self.language = language
        self.prompt = prompt
    }

    public func transcribe(audio: URL) async throws -> TranscribeResult {
        let url = URL(string: "\(baseURL)/audio/transcriptions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let boundary = "resound-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var fields: [(String, String)] = [
            ("model", model),
            ("response_format", "verbose_json"),
            ("timestamp_granularities[]", "segment"),
        ]
        if let language, !language.isEmpty { fields.append(("language", language)) }
        if let prompt, !prompt.isEmpty { fields.append(("prompt", prompt)) }

        let audioData = try Data(contentsOf: audio)
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        for (k, v) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n")
            append("\(v)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\n")
        append("Content-Type: audio/m4a\r\n\r\n")
        body.append(audioData)
        append("\r\n--\(boundary)--\r\n")

        let (data, resp) = try await URLSession.shared.upload(for: req, from: body)
        guard let http = resp as? HTTPURLResponse else { throw TranscribeError.network("无响应") }
        guard (200..<300).contains(http.statusCode) else {
            throw TranscribeError.network("HTTP \(http.statusCode)：\(String(data: data, encoding: .utf8) ?? "")")
        }

        let decoded = try JSONDecoder().decode(VerboseResp.self, from: data)
        var segments: [Transcript.Segment] = []
        if let segs = decoded.segments, !segs.isEmpty {
            for (i, s) in segs.enumerated() {
                let t = s.text.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                segments.append(Transcript.Segment(id: i, start: s.start, end: s.end, text: t, words: []))
            }
        } else if let text = decoded.text, !text.isEmpty {
            segments = [Transcript.Segment(id: 0, start: 0, end: decoded.duration ?? 0, text: text, words: [])]
        }
        return TranscribeResult(
            transcript: Transcript(language: decoded.language ?? language ?? "unknown", segments: segments),
            modelName: "aihubmix-\(model)")
    }

    private struct VerboseResp: Codable {
        let language: String?
        let duration: Double?
        let text: String?
        let segments: [Seg]?
        struct Seg: Codable { let start: Double; let end: Double; let text: String }
    }
}

public enum TranscribeError: Error, CustomStringConvertible {
    case network(String)
    public var description: String {
        switch self { case .network(let m): return "在线转录失败：\(m)" }
    }
}
