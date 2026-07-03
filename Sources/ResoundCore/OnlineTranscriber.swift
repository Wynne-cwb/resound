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
        self.baseURL = config.transcribeBaseURL   // 缺省同 embedding；可在设置里单独配远程转写端点
        self.apiKey = config.transcribeKey
        self.model = config.transcribeModel
        self.language = language
        self.prompt = prompt
    }

    /// 把词表偏置 prompt 截到 API 上限内。**按 UTF-8 字节数算**（aihubmix 的 896 上限是字节数，不是字符数——
    /// 中文一字 3 字节，843 字符可达 915 字节顶破限制）。逐词累加、在 ", " 边界切、不切碎词；
    /// 保留靠前的词——glossary.txt 里用户手写词在前、自动加入的说话人名在后，故优先保手写词。
    static func cappedPrompt(_ s: String, maxBytes: Int = 880) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var out = "", bytes = 0
        for term in s.components(separatedBy: ", ") {
            let add = (out.isEmpty ? 0 : 2) + term.utf8.count   // ", " 占 2 字节
            if bytes + add > maxBytes { break }
            out += (out.isEmpty ? "" : ", ") + term
            bytes += add
        }
        return out
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
            ("timestamp_granularities[]", "word"),   // 词级时间戳：供说话人词级归属 + 句级平滑（第二档）
        ]
        if let language, !language.isEmpty { fields.append(("language", language)) }
        // whisper prompt 有长度上限（aihubmix 实测 896 字符，超了整个请求 HTTP 500 失败）。
        // 词表变长（尤其自动加入的说话人名字）会顶破 → 在逗号边界截断，保留靠前的词（用户手写词优先）。
        if let prompt, !prompt.isEmpty {
            fields.append(("prompt", Self.cappedPrompt(prompt)))
        }

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
        // 顶层 words（词级时间戳，OpenAI verbose_json 格式）——按 start 排序供分配。
        let allWords = (decoded.words ?? [])
            .map { Transcript.Word(w: $0.word, start: $0.start, end: $0.end) }
            .sorted { $0.start < $1.start }
        // 用双指针把词分配进它所属的段（词 start 落在 [seg.start, seg.end] 内）。词按序、段按序 → O(n+m)。
        func wordsIn(_ s: Double, _ e: Double, cursor: inout Int) -> [Transcript.Word] {
            var out: [Transcript.Word] = []
            while cursor < allWords.count && allWords[cursor].start < s { cursor += 1 }  // 跳过落在段前的
            var k = cursor
            while k < allWords.count && allWords[k].start <= e + 0.001 { out.append(allWords[k]); k += 1 }
            return out
        }
        var segments: [Transcript.Segment] = []
        if let segs = decoded.segments, !segs.isEmpty {
            var cursor = 0
            for (i, s) in segs.enumerated() {
                let t = s.text.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                let words = wordsIn(s.start, s.end, cursor: &cursor)
                segments.append(Transcript.Segment(id: i, start: s.start, end: s.end, text: t, words: words))
            }
        } else if let text = decoded.text, !text.isEmpty {
            segments = [Transcript.Segment(id: 0, start: 0, end: decoded.duration ?? 0, text: text, words: allWords)]
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
        let words: [Wrd]?
        struct Seg: Codable { let start: Double; let end: Double; let text: String }
        struct Wrd: Codable { let word: String; let start: Double; let end: Double }
    }
}

public enum TranscribeError: Error, CustomStringConvertible {
    case network(String)
    public var description: String {
        switch self { case .network(let m): return "在线转录失败：\(m)" }
    }
}
