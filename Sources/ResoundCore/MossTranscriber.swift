import AVFoundation
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
    /// Called with true when transcription pauses because the Mac went offline, false when it resumes
    /// (lets the App show "waiting for network" instead of a spinner that never moves).
    public var onNetworkWait: ((Bool) -> Void)?

    static let maxHotwords = 24
    static let pollInterval: UInt64 = 10 * 1_000_000_000   // 10s
    /// 官方默认 prompt（与模型训练口径一致，改了会伤输出格式）。
    static let defaultPrompt = "请将音频转写为文本，每一段需以起始时间戳和说话人编号（[S01]、[S02]、[S03]…）开头，正文为对应的语音内容，并在段末标注结束时间戳，以清晰标明该段语音范围。"

    /// 分片阈值：超过该时长自动切片并发提交。
    /// ⚠️ 曾定 4800（80 min，依据「MOSS 官方设计 90 分钟」）——**这个依据是错的**。
    /// 2026-07-29 全库取证：0.9B 在 **30–70 分钟**单次输入上就会**静默截断**（转出一部分就停、
    /// 无任何报错、`segments` 非空所以下游看不出异常），80 条录音里 10 条中招、最严重的
    /// 56.4min 只转出 27.5min（丢 51%）。抽验 6 条尾部音量与会议中段相同 → 确认是漏转不是静音尾巴。
    /// 详见 DECISIONS 2026-07-29。
    static let chunkThresholdSec: Double = 1800   // 30 min
    /// 分片目标时长：>阈值时按此长度均匀切片（尾片可能略短）。
    static let chunkTargetSec: Double = 1500      // 25 min
    /// 分片提交并发上限。Modal 按调用自动扩容，但免费额度有限、且并发过高会限流，故设闸。
    static let chunkConcurrency = 5

    public init(config: Config, hotwords: [String] = [], onNetworkWait: ((Bool) -> Void)? = nil) throws {
        guard let s = URL(string: config.mossSubmitURL), let r = URL(string: config.mossResultURL) else {
            throw MossError.badConfig("MOSS endpoint 未配置或不是合法 URL")
        }
        self.submitURL = s
        self.resultURL = r
        self.apiKey = config.mossKey
        self.hotwords = hotwords
        self.onNetworkWait = onNetworkWait
    }

    public struct Output {
        public let result: TranscribeResult
        /// 与 result.transcript.segments 一一对应的说话人标签（"S01"…）。
        public let speakerLabels: [String]
    }

    /// 转写一条音频。超过 `chunkThresholdSec` 会自动切片并发提交并拼接（详见 transcribeChunked）。
    /// `timeout` 缺省 60 分钟（分片模式下作为「单片超时」，整体 wall-clock ≈ 最慢片 timeout）。
    public func transcribe(audio: URL, timeout: TimeInterval = 3600,
                           log: @escaping (String) -> Void = { _ in }) async throws -> Output {
        // 时长探测走 AVFoundation（不依赖外部 ffprobe——没装 ffmpeg 的机器上曾会静默退回单次
        // 提交，长音频于是必被截断，这正是最隐蔽的一条失败路径）。
        let dur = (try? await AVURLAsset(url: audio).load(.duration).seconds) ?? 0
        if dur > Self.chunkThresholdSec {
            return try await transcribeChunked(audio: audio, totalDuration: dur, timeout: timeout, log: log)
        }
        return try await runSinglePass(audio: audio, timeout: timeout, log: log)
    }

    /// 单次提交：submit → 轮询 → 解析。是标准短音频路径，也被 chunked 分片路径内部复用。
    private func runSinglePass(audio: URL, timeout: TimeInterval,
                               log: @escaping (String) -> Void) async throws -> Output {
        // 耗时埋点：上传（本地压缩+网络出口）与 GPU 排队/推理（服务端）是两种性质的等待，分开计时才能定位瓶颈。
        let tUpload = Date()
        // Connectivity failures never escape as "MOSS failed": offline → wait for the network, then
        // resubmit (see ConnectivityPatience). Only server-side errors propagate to the whisper fallback.
        var patience = ConnectivityPatience(what: "MOSS 上传", log: log, onNetworkWait: onNetworkWait)
        var callId = ""
        while true {
            do { callId = try await submit(audio: audio); break }
            catch where NetworkWait.isConnectivityError(error) { _ = try await patience.absorb(error) }
        }
        let uploadSec = Date().timeIntervalSince(tUpload)
        let sizeMB = Double((try? FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int) ?? 0) / 1_048_576
        log(String(format: "   ☁️ MOSS 已提交（%@），⏱ 上传 %.1fs（%.1fMB）→ GPU 推理中…", callId, uploadSec, sizeMB))
        let tGPU = Date()
        var deadline = Date().addingTimeInterval(timeout)
        var pollPatience = ConnectivityPatience(what: "MOSS 结果轮询", log: log, onNetworkWait: onNetworkWait)
        var transientErrors = 0
        var polls = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: Self.pollInterval)
            do {
                polls += 1
                if let data = try await poll(callId: callId) {
                    log(String(format: "   ⏱ GPU 等待 %.1fs（%d 次轮询 @%.0fs，轮询粒度浪费 ≤%.0fs）",
                               Date().timeIntervalSince(tGPU), polls,
                               Double(Self.pollInterval) / 1e9, Double(Self.pollInterval) / 1e9))
                    return try parse(data)
                }
            } catch let e as MossError {
                throw e   // 服务端明确失败：不重试
            } catch where NetworkWait.isConnectivityError(error) {
                // Keep the same call_id: the GPU job keeps running server-side while we are offline,
                // so resume polling instead of resubmitting. Time spent offline does not eat the deadline.
                deadline += try await pollPatience.absorb(error)
                continue
            } catch {
                transientErrors += 1   // 网络抖动：容忍连续 6 次（1 分钟）
                if transientErrors >= 6 { throw error }
                continue
            }
            transientErrors = 0
        }
        throw MossError.timeout(Int(timeout))
    }

    /// 分片路径：切成 chunkTargetSec 每片、chunkConcurrency 并发提交、按时间戳偏移拼接。
    /// 每片说话人 label 加片前缀（P1_S01 / P2_S01 …）。跨片声纹归一需要 CAM++，交给下游做
    ///（`nameSpeakersFromMossDiarization` 的凝聚合并会把跨片同一人并回，实测 cos 0.89–0.93）。
    private func transcribeChunked(audio: URL, totalDuration: Double, timeout: TimeInterval,
                                   log: @escaping (String) -> Void) async throws -> Output {
        let chunkCount = max(1, Int((totalDuration / Self.chunkTargetSec).rounded(.up)))
        let chunkLen = totalDuration / Double(chunkCount)
        log(String(format: "   ✂️ 音频 %.1f min > %.0f min 阈值，切成 %d 片各 ~%.1f min，%d 片并发",
                   totalDuration/60, Self.chunkThresholdSec/60, chunkCount, chunkLen/60, Self.chunkConcurrency))

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moss-chunks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1) 切片（AVFoundation 导出 m4a，零外部依赖；服务端自己会做 16k 归一化）
        struct Slice { let index: Int; let start: Double; let end: Double; let url: URL }
        var slices: [Slice] = []
        for i in 0..<chunkCount {
            let s = Double(i) * chunkLen
            let e = min(s + chunkLen, totalDuration)
            let out = tempDir.appendingPathComponent(String(format: "chunk-%02d.m4a", i))
            _ = try await M4AExporter().exportM4A(from: audio, to: out, range: (s, e))
            slices.append(Slice(index: i, start: s, end: e, url: out))
        }

        // 2) 并发提交 —— TaskGroup + slot 计数保持在 chunkConcurrency
        let concurrency = Self.chunkConcurrency
        // Swift concurrency + non-Sendable closures 里 self 直接捕获会告警，用局部拷贝复用即可
        // 单片解析出 0 段（整片静音）返回 nil 而非抛错——一片没人说话不该让整条录音转写失败。
        let outputs: [Int: Output] = try await withThrowingTaskGroup(of: (Int, Output?).self) { group in
            var iter = slices.makeIterator()
            for _ in 0..<concurrency {
                guard let s = iter.next() else { break }
                group.addTask { [self] in try await self.runChunk(s.index, s.url, s.end - s.start, timeout, log) }
            }
            var collected: [Int: Output] = [:]
            while let (idx, out) = try await group.next() {
                if let out { collected[idx] = out }
                if let s = iter.next() {
                    group.addTask { [self] in try await self.runChunk(s.index, s.url, s.end - s.start, timeout, log) }
                }
            }
            return collected
        }

        // 3) 按片序拼接：时间戳偏移 + speaker label 加片前缀（跨片对齐待 CAM++ 后处理）
        var mergedSegs: [Transcript.Segment] = []
        var mergedLabels: [String] = []
        var segId = 0
        for i in 0..<chunkCount {
            // 缺失只可能是「该片无语音」——真失败已由 TaskGroup 抛出，不会走到这
            guard let out = outputs[i] else { continue }
            let offset = slices[i].start
            for (s, lbl) in zip(out.result.transcript.segments, out.speakerLabels) {
                mergedSegs.append(Transcript.Segment(id: segId,
                                                     start: s.start + offset,
                                                     end: max(s.end, s.start) + offset,
                                                     text: s.text,
                                                     words: [],
                                                     track: nil))
                mergedLabels.append("P\(i + 1)_\(lbl)")
                segId += 1
            }
        }

        guard !mergedSegs.isEmpty else { throw MossError.empty }   // 所有片都无语音
        let language = Self.dominantLanguage(mergedSegs.map(\.text).joined())
        return Output(
            result: TranscribeResult(transcript: Transcript(language: language, segments: mergedSegs),
                                     modelName: "moss-transcribe-diarize-0.9b-chunked"),
            speakerLabels: mergedLabels
        )
    }

    /// 跑一个分片。返回 nil = 该片无语音内容（整片静音），不算失败。
    private func runChunk(_ index: Int, _ url: URL, _ seconds: Double, _ timeout: TimeInterval,
                          _ log: @escaping (String) -> Void) async throws -> (Int, Output?) {
        log("   ▶︎ 片 P\(index + 1) 上传（\(Int(seconds))s 音频）")
        do {
            let out = try await runSinglePass(audio: url, timeout: timeout, log: { _ in })
            log("   ✓ 片 P\(index + 1) 完成（\(out.result.transcript.segments.count) 段）")
            return (index, out)
        } catch MossError.empty {
            log("   ⚠️ 片 P\(index + 1) 无语音内容，跳过（不影响其余片）")
            return (index, nil)
        }
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
        guard !r.segments.isEmpty else { throw MossError.empty }
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
    /// 服务端正常跑完但解析出 0 段（该音频无语音内容）。独立成一种：分片路径要能只跳过这一片，
    /// 部署自检也要能把「合成静音测通了链路」判成成功，都不该当成 badResponse。
    case empty
    case timeout(Int)
    public var description: String {
        switch self {
        case .badConfig(let m): return "MOSS 配置错误：\(m)"
        case .http(let c, let b): return "MOSS HTTP \(c)：\(b)"
        case .badResponse(let m): return "MOSS 响应异常：\(m)"
        case .empty: return "MOSS 返回空转录（该音频无语音内容）"
        case .timeout(let s): return "MOSS 推理超时（>\(s)s）"
        }
    }
}
