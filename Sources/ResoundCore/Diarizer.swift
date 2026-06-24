import Foundation
import CoreML
import FluidAudio

public enum DiarBackend: String, CaseIterable {
    case manager      // FluidAudio DiarizerManager（在线聚类，分不开相似嗓音）
    case sortformer   // FluidAudio Sortformer（≤4 人，身份最稳）
    case offline      // FluidAudio OfflineDiarizerManager（pyannote community-1 + VBx，任意人数，17.7% DER@AMI）
}

public struct DiarSeg {
    public let spk: String
    public let start: Double
    public let end: Double
}

/// Sortformer 配置 + 算力单一出处（DiarModelCache 加载与 runDiarization 推理必须一致）。
/// 见 DECISIONS 2026-06-23「Sortformer 提速（ANE + highContext）」：
/// - `computeUnits = .all`（含 ANE）：推理比 .cpuAndGPU 快 ~2.5x；首次 ANE 编译一次性 ~150-200s，落盘缓存、后续加载 ~6s。
/// - `highContextV2_1`（chunkLen 340）：推理调用从 ~437 次降到 ~8 次，叠加 ANE 实测 RTF ~59x（692s 1-on-1 推理 ~12s）。
///   实测多人会仍检出 4 簇（与默认档一致 → ≥4 回退逐窗法的路由不变、多人会零风险）；
///   2 人 1-on-1 检出 3 簇（比默认档 4 簇更接近真实 2，过检更少、下游幽灵说话人更少）。
public let sortformerConfig: SortformerConfig = .highContextV2_1
public let sortformerComputeUnits: MLComputeUnits = .all

/// 重模型进程级缓存：Sortformer / DiarizerManager / silero-VAD / CAM++ 声纹模型，
/// 都是冷加载/冷编译很贵（CoreML/ONNX）。批量导入时每个文件各加载一次会把 GPU/CPU
/// 抢爆、拖卡整个系统合成器；这里加载一次后复用（worker 串行执行，单实例复用安全）。
public actor DiarModelCache {
    public static let shared = DiarModelCache()
    private init() {}

    private var sortformerModels: SortformerModels?
    private var managerModels: DiarizerModels?
    private var vadManager: VadManager?
    private var embedders: [String: SpeakerEmbedder] = [:]

    func sortformer() async throws -> SortformerModels {
        if let m = sortformerModels { return m }
        let m = try await SortformerModels.loadFromHuggingFace(config: sortformerConfig, computeUnits: sortformerComputeUnits)
        sortformerModels = m; return m
    }
    func manager() async throws -> DiarizerModels {
        if let m = managerModels { return m }
        let m = try await DiarizerModels.downloadIfNeeded()
        managerModels = m; return m
    }
    func vad() async throws -> VadManager {
        if let v = vadManager { return v }
        let v = try await VadManager(); vadManager = v; return v
    }
    func embedder(model: String) throws -> SpeakerEmbedder {
        if let e = embedders[model] { return e }
        let e = try SpeakerEmbedder(model: model); embedders[model] = e; return e
    }
}

/// 跑分割（从文件）：解码音频后委托给 samples 版。offline 后端需要 URL，单独走。
public func runDiarization(audio: URL, backend: DiarBackend, threshold: Float,
                           log: (String) -> Void = { print($0) }) async throws -> [DiarSeg] {
    if backend == .offline {
        return try await runOfflineDiarization(audio: audio, log: log)
    }
    let samples = try AudioConverter().resampleAudioFile(audio)
    return try await runDiarization(samples: samples, backend: backend, threshold: threshold, log: log)
}

/// 跑分割（从已解码样本，16k mono）：避免与上游重复解码同一文件。
public func runDiarization(samples: [Float], backend: DiarBackend, threshold: Float,
                           log: (String) -> Void = { print($0) }) async throws -> [DiarSeg] {
    switch backend {
    case .manager:
        log("⬇️  DiarizerManager 模型…")
        let models = try await DiarModelCache.shared.manager()
        let d = DiarizerManager(config: DiarizerConfig(clusteringThreshold: threshold))
        d.initialize(models: models)
        return try d.performCompleteDiarization(samples).segments.map {
            DiarSeg(spk: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    case .sortformer:
        log("⬇️  Sortformer 模型（\(sortformerConfig.modelVariant.map { "\($0)" } ?? "default"), ANE）…")
        let models = try await DiarModelCache.shared.sortformer()
        let d = SortformerDiarizer(config: sortformerConfig)
        d.initialize(models: models)
        let result = try d.processComplete(samples)
        return result.speakers.values.flatMap { $0.finalizedSegments }.map {
            DiarSeg(spk: "\($0.speakerLabel)", start: Double($0.startTime), end: Double($0.endTime))
        }
    case .offline:
        throw ConfigError.missing("offline diarizer 需用 runDiarization(audio:) 入口")
    }
}

/// offline 后端（实验用，已知会崩）：保留 URL 入口。
private func runOfflineDiarization(audio: URL, log: (String) -> Void) async throws -> [DiarSeg] {
    // ⚠️ 已知坏：FluidAudio 0.15.4 离线 diarizer 在本机 embedding 提取(chunk 0)硬崩 SIGBUS/SIGSEGV，
    // 与算力无关——已验证 cpuOnly 也崩（见 DECISIONS 2026-06-23）。**勿接入 production**（硬崩无法 try/catch）。
    // 仅留作 CLI 实验：等 FluidAudio 修复或本仓 vendor+patch 后可启用（届时去掉 4 人上限回退）。
    log("⚠️ Offline diarizer 已知会崩（FluidAudio 0.15.4 bug），仅供实验…")
    let manager = OfflineDiarizerManager(config: .default)
    manager.initialize(models: try await loadOfflineModelsCPUOnly())   // cpuOnly：仍崩，留作记录
    let result = try await manager.process(audio)
    return result.segments.map {
        DiarSeg(spk: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
    }
}

/// 用 **cpuOnly** 加载离线 diarizer 的全部模型（绕开官方 load() 硬编码的 `.all`——ANE 推理在本机崩）。
/// 复用公开的 `DownloadUtils.loadModels(computeUnits:)` + 公开的 `OfflineDiarizerModels.init`，
/// pldaPsi 直接读 `plda-parameters.json`（与官方私有逻辑一致：取 tensors.psi.data_base64 的 Float 数组）。
private func loadOfflineModelsCPUOnly() async throws -> OfflineDiarizerModels {
    let dir = OfflineDiarizerModels.defaultModelsDirectory()
    let names = [
        ModelNames.OfflineDiarizer.segmentationPath,
        ModelNames.OfflineDiarizer.embeddingPath,
        ModelNames.OfflineDiarizer.pldaRhoPath,
        ModelNames.OfflineDiarizer.fbankPath,
    ]
    let models = try await DownloadUtils.loadModels(
        .diarizer, modelNames: names, directory: dir, computeUnits: .cpuOnly, variant: "offline")
    guard let seg = models[ModelNames.OfflineDiarizer.segmentationPath],
          let emb = models[ModelNames.OfflineDiarizer.embeddingPath],
          let plda = models[ModelNames.OfflineDiarizer.pldaRhoPath],
          let fbank = models[ModelNames.OfflineDiarizer.fbankPath] else {
        throw ConfigError.missing("offline diarizer 模型未找到")
    }
    return OfflineDiarizerModels(
        segmentationModel: seg, fbankModel: fbank, embeddingModel: emb,
        pldaRhoModel: plda, pldaPsi: try loadPLDAPsi(from: dir), compilationDuration: 0)
}

private func loadPLDAPsi(from directory: URL) throws -> [Double] {
    let candidates = [
        "plda-parameters.json",
        "speaker-diarization/plda-parameters.json",
        "speaker-diarization-coreml/plda-parameters.json",
        "speaker-diarization-offline/plda-parameters.json",
    ].map { directory.appendingPathComponent($0) }
    guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
        throw ConfigError.missing("plda-parameters.json")
    }
    let data = try Data(contentsOf: url)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tensors = root["tensors"] as? [String: Any],
          let psi = tensors["psi"] as? [String: Any],
          let b64 = psi["data_base64"] as? String,
          let decoded = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters]) else {
        throw ConfigError.missing("plda psi 解码失败")
    }
    var floats = [Float](repeating: 0, count: decoded.count / MemoryLayout<Float>.size)
    _ = floats.withUnsafeMutableBytes { decoded.copyBytes(to: $0) }
    return floats.map(Double.init)
}

public func diarizeSmoke(audio: URL, backend: DiarBackend = .sortformer, threshold: Float = 0.7,
                         log: (String) -> Void = { print($0) }) async throws -> String {
    log("🗣  diarization（\(backend.rawValue)）…")
    let segs = try await runDiarization(audio: audio, backend: backend, threshold: threshold, log: log)
    var bySpeaker: [String: (count: Int, dur: Double)] = [:]
    for s in segs {
        bySpeaker[s.spk, default: (0, 0)].count += 1
        bySpeaker[s.spk, default: (0, 0)].dur += (s.end - s.start)
    }
    var out = "说话人数: \(bySpeaker.count)，段数: \(segs.count)\n"
    for (spk, v) in bySpeaker.sorted(by: { $0.value.dur > $1.value.dur }) {
        out += String(format: "  %@: %d 段, 共 %.0fs\n", spk, v.count, v.dur)
    }
    return out
}

// MARK: - 用 ground-truth 转录评测 diarization

/// 解析 "HH:MM:SS 说话人" 行 → (秒, 说话人)。文本/中文行不匹配会被跳过。
func parseGroundTruth(_ url: URL) -> [(t: Double, speaker: String)] {
    guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var out: [(Double, String)] = []
    for line in s.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: " ", maxSplits: 1).map { String($0) }
        guard parts.count == 2 else { continue }
        let tc = parts[0].split(separator: ":")
        guard tc.count == 3, let h = Int(tc[0]), let m = Int(tc[1]), let sec = Int(tc[2]) else { continue }
        out.append((Double(h * 3600 + m * 60 + sec), parts[1].trimmingCharacters(in: .whitespaces)))
    }
    return out
}

public func diarizeEval(audio: URL, transcript: URL, backend: DiarBackend = .sortformer,
                        threshold: Float = 0.7, log: (String) -> Void = { print($0) }) async throws -> String {
    let gt = parseGroundTruth(transcript)
    let gtSpeakers = Set(gt.map { $0.speaker }).sorted()
    log("📄 ground truth: \(gt.count) 条发言，\(gtSpeakers.count) 人: \(gtSpeakers.joined(separator: "/"))")

    log("🗣  diarization（\(backend.rawValue)）…")
    let segs = try await runDiarization(audio: audio, backend: backend, threshold: threshold, log: log)

    func diarAt(_ t: Double) -> String? {
        if let hit = segs.first(where: { $0.start <= t && t <= $0.end }) { return hit.spk }
        return segs.min(by: { abs(($0.start + $0.end) / 2 - t) < abs(($1.start + $1.end) / 2 - t) })?.spk
    }

    var pairs: [(gt: String, diar: String)] = []
    for u in gt { if let d = diarAt(u.t) { pairs.append((u.speaker, d)) } }

    var diarToGt: [String: [String: Int]] = [:]
    for p in pairs { diarToGt[p.diar, default: [:]][p.gt, default: 0] += 1 }
    let mapping = diarToGt.mapValues { $0.max(by: { $0.value < $1.value })!.key }

    let correct = pairs.filter { mapping[$0.diar] == $0.gt }.count
    let acc = pairs.isEmpty ? 0 : Double(correct) * 100 / Double(pairs.count)
    let diarCount = Set(segs.map { $0.spk }).count

    var report = """
    === diarization 评测（\(backend.rawValue)）===
    GT 说话人数: \(gtSpeakers.count)  |  diar 检出: \(diarCount)  |  段数: \(segs.count)
    发言级标注准确率: \(String(format: "%.1f%%", acc))（\(correct)/\(pairs.count)）
    --- 簇→人 映射 ---
    """
    for (d, counts) in diarToGt.sorted(by: { $0.value.values.reduce(0,+) > $1.value.values.reduce(0,+) }) {
        let total = counts.values.reduce(0, +)
        let detail = counts.sorted { $0.value > $1.value }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
        report += "\n  diar[\(d)] → \(mapping[d] ?? "?")  (\(total) 条: \(detail))"
    }
    return report
}
