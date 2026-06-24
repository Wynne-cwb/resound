import Foundation

/// 一次连通性验证的结果。`ok` 带一句可展示的细节（如探测到的维度），`fail` 带翻译成人话的原因。
public enum ProbeOutcome: Equatable, Sendable {
    case ok(String)
    case fail(String)

    public var isOK: Bool { if case .ok = self { return true } else { return false } }
    public var detail: String { switch self { case .ok(let s): return s; case .fail(let s): return s } }
}

/// 对一个 OpenAI 兼容 Provider 的 chat / embedding / 转写端点发最小真实请求，验证可用性。
public enum ProviderProbe {
    private static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    /// 把 HTTP 状态码 / 网络错误翻译成用户能看懂的中文原因。
    private static func explain(status: Int, body: Data) -> String {
        let snippet = String(data: body, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(200) ?? ""
        switch status {
        case 401, 403: return "API Key 无效或无权限（HTTP \(status)）"
        case 404: return "模型或端点不存在，检查 Base URL 和模型名（HTTP 404）"
        case 429: return "请求过于频繁或额度不足（HTTP 429）"
        case 400: return "请求被拒绝，多半是模型名不对：\(snippet)"
        case 500...599: return "服务端错误（HTTP \(status)）"
        default: return "HTTP \(status)：\(snippet)"
        }
    }

    private static func explain(error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorTimedOut: return "连接超时，检查 Base URL 与网络"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "连不上服务器，检查 Base URL（含 http/https）"
        case NSURLErrorNotConnectedToInternet: return "无网络连接"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted: return "TLS/证书校验失败"
        default: return ns.localizedDescription
        }
    }

    private static func endpoint(_ baseURL: String, _ path: String) -> URL? {
        var b = baseURL.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: b + path)
    }

    // MARK: Chat

    public static func chat(baseURL: String, key: String, model: String) async -> ProbeOutcome {
        guard let url = endpoint(baseURL, "/chat/completions") else { return .fail("Base URL 格式不对") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [["role": "user", "content": "ping"]],
            "max_tokens": 1,
        ])
        do {
            let (data, resp) = try await session().data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { return .fail(explain(status: code, body: data)) }
            // 200 即视为通；顺带确认是合法 JSON
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return .fail("返回不是合法 JSON") }
            return .ok("Chat 可用 · \(model)")
        } catch { return .fail(explain(error: error)) }
    }

    // MARK: Embedding（顺带探测向量维度）

    public static func embedding(baseURL: String, key: String, model: String) async -> (ProbeOutcome, Int?) {
        guard let url = endpoint(baseURL, "/embeddings") else { return (.fail("Base URL 格式不对"), nil) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "input": "ping"])
        do {
            let (data, resp) = try await session().data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard code == 200 else { return (.fail(explain(status: code, body: data)), nil) }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = obj["data"] as? [[String: Any]],
                  let emb = arr.first?["embedding"] as? [Any], !emb.isEmpty else {
                return (.fail("返回里找不到 embedding 向量"), nil)
            }
            let dim = emb.count
            return (.ok("Embedding 可用 · 维度 \(dim)"), dim)
        } catch { return (.fail(explain(error: error)), nil) }
    }

    // MARK: 转写（内存合成极短音频测 /audio/transcriptions）

    public static func transcribe(baseURL: String, key: String, model: String) async -> ProbeOutcome {
        guard let url = endpoint(baseURL, "/audio/transcriptions") else { return .fail("Base URL 格式不对") }
        let wav = makeTinyWAV()
        let boundary = "resound-probe-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n")
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"file\"; filename=\"probe.wav\"\r\n")
        add("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        add("\r\n--\(boundary)--\r\n")
        do {
            let (data, resp) = try await session().upload(for: req, from: body)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code) else { return .fail(explain(status: code, body: data)) }
            return .ok("转写可用 · \(model)")
        } catch { return .fail(explain(error: error)) }
    }

    /// 0.3s / 16kHz / 单声道 / PCM16 的极短 WAV（一点低幅正弦），仅用于验证端点连通。
    private static func makeTinyWAV() -> Data {
        let sampleRate = 16000, seconds = 0.3
        let n = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            let t = Double(i) / Double(sampleRate)
            let v = sin(2 * Double.pi * 440 * t) * 0.2
            let s = Int16(max(-1, min(1, v)) * 32767)
            withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func u32(_ x: UInt32) { withUnsafeBytes(of: x.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ x: UInt16) { withUnsafeBytes(of: x.littleEndian) { d.append(contentsOf: $0) } }
        let byteRate = UInt32(sampleRate * 2)
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + pcm.count)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(byteRate); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }
}
