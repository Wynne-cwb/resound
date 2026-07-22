import Foundation

/// MOSS-Transcribe-Diarize 云端转写客户端（自部署 Modal 服务，见 experiments/moss-eval/moss_modal.py）。
///
/// 端到端联合模型：一次调用同时产出「转录段 + 说话人标签（S01/S02…）+ 段级时间戳」，
/// 取代「whisper 转录 ⊕ 本地 diarization 事后拼接」。协议是异步两段式（Modal 对 >150s 的
/// 同步请求会转 303 轮询、与长推理不兼容）：POST submit 拿 call_id → GET result 轮询。
public struct MossTranscriber {
    public let submitURL: URL
    public let resultURL: URL
    public let apiKey: String
    /// glossary 偏置词。实测热词列表过长会稀释注意力反而无效（DECISIONS 2026-07-22），
    /// 只取前 `maxHotwords` 个拼进 prompt；术语兜底仍靠下游 glossary 替换 + AI 校对。
    public let hotwords: [String]

    static let maxHotwords = 24
    static let pollInterval: UInt64 = 10 * 1_000_000_000   // 10s
    /// 官方默认 prompt（与模型训练口径一致，改了会伤输出格式）。
    static let defaultPrompt = "请将音频转写为文本，每一段需以起始时间戳和说话人编号（[S01]、[S02]、[S03]…）开头，正文为对应的语音内容，并在段末标注结束时间戳，以清晰标明该段语音范围。"

    public init(config: Config, hotwords: [String] = []) throws {
        guard let s = URL(string: config.mossSubmitURL), let r = URL(string: config.mossResultURL) else {
            throw MossError.badConfig("MOSS endpoint 未配置或不是合法 URL")
        }
        self.submitURL = s
        self.resultURL = r
        self.apiKey = config.mossKey
        self.hotwords = hotwords
    }

    public struct Output {
        public let result: TranscribeResult
        /// 与 result.transcript.segments 一一对应的说话人标签（"S01"…）。
        public let speakerLabels: [String]
    }

    /// 转写一条音频：submit → 轮询 → 解析成现有 Transcript 结构（段级时间戳，无词级）。
    /// `timeout` 缺省 60 分钟（90 分钟长录音 RTF≈0.36 也够）。
    public func transcribe(audio: URL, timeout: TimeInterval = 3600,
                           log: (String) -> Void = { _ in }) async throws -> Output {
        let callId = try await submit(audio: audio)
        log("   ☁️ MOSS 已提交（\(callId)），GPU 推理中…")
        let deadline = Date().addingTimeInterval(timeout)
        var transientErrors = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: Self.pollInterval)
            do {
                if let data = try await poll(callId: callId) {
                    return try parse(data)
                }
            } catch let e as MossError {
                throw e   // 服务端明确失败：不重试
            } catch {
                transientErrors += 1   // 网络抖动：容忍连续 6 次（1 分钟）
                if transientErrors >= 6 { throw error }
                continue
            }
            transientErrors = 0
        }
        throw MossError.timeout(Int(timeout))
    }

    // MARK: - HTTP

    private func submit(audio: URL) async throws -> String {
        let boundary = "resound-\(UUID().uuidString)"
        var req = URLRequest(url: submitURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 300   // 上传大文件留足余量（20 分钟 m4a 约 4MB）
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("max_new_tokens", "65536")
        let prompt = Self.buildPrompt(hotwords: hotwords)
        if prompt != Self.defaultPrompt { field("prompt", prompt) }
        let audioData = try Data(contentsOf: audio)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw MossError.http((resp as? HTTPURLResponse)?.statusCode ?? -1,
                                 String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["call_id"] as? String else {
            throw MossError.badResponse("submit 响应缺 call_id")
        }
        return id
    }

    /// 一次轮询：nil = 还在跑（202）；Data = 完成；抛 MossError = 服务端失败。
    private func poll(callId: String) async throws -> Data? {
        var comps = URLComponents(url: resultURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "call_id", value: callId)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 60
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        switch code {
        case 202: return nil
        case 200: return data
        default:
            throw MossError.http(code, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
    }

    // MARK: - 解析

    private func parse(_ data: Data) throws -> Output {
        struct MossSeg: Codable { let start: Double; let end: Double; let speaker: String; let text: String }
        struct MossResp: Codable { let segments: [MossSeg] }
        let r = try JSONDecoder().decode(MossResp.self, from: data)
        guard !r.segments.isEmpty else { throw MossError.badResponse("MOSS 返回空转录") }
        var segs: [Transcript.Segment] = []
        var labels: [String] = []
        for (i, s) in r.segments.enumerated() {
            let text = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            // MOSS 偶发 end 略小于 start（重叠附和的时间戳噪声）→ 收敛成非负时长
            segs.append(Transcript.Segment(id: i, start: s.start, end: max(s.end, s.start),
                                           text: text, words: [], track: nil))
            labels.append(s.speaker)
        }
        let language = Self.dominantLanguage(segs.map(\.text).joined())
        return Output(result: TranscribeResult(transcript: Transcript(language: language, segments: segs),
                                               modelName: "moss-transcribe-diarize-0.9b"),
                      speakerLabels: labels)
    }

    /// 官方热词格式：默认 prompt 后接「热词提示：w1, w2, …」。列表按 UTF-8 字节上限 400 截断。
    static func buildPrompt(hotwords: [String]) -> String {
        guard !hotwords.isEmpty else { return defaultPrompt }
        var picked: [String] = []
        var bytes = 0
        for w in hotwords.prefix(maxHotwords) {
            let b = w.utf8.count + 2
            if bytes + b > 400 { break }
            picked.append(w); bytes += b
        }
        guard !picked.isEmpty else { return defaultPrompt }
        return defaultPrompt + "热词提示：" + picked.joined(separator: ", ")
    }

    static func dominantLanguage(_ text: String) -> String {
        var cjk = 0, latin = 0
        for sc in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(sc.value) { cjk += 1 }
            else if (65...122).contains(sc.value) { latin += 1 }
        }
        return cjk * 2 >= latin ? "zh" : "en"
    }
}

public enum MossError: Error, CustomStringConvertible {
    case badConfig(String)
    case http(Int, String)
    case badResponse(String)
    case timeout(Int)
    public var description: String {
        switch self {
        case .badConfig(let m): return "MOSS 配置错误：\(m)"
        case .http(let c, let b): return "MOSS HTTP \(c)：\(b)"
        case .badResponse(let m): return "MOSS 响应异常：\(m)"
        case .timeout(let s): return "MOSS 推理超时（>\(s)s）"
        }
    }
}
