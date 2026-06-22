import Foundation
import CSherpaOnnx

/// sherpa-onnx 声纹提取器的 Swift 薄封装。
/// 加载一个 3D-Speaker ONNX 模型，对 16kHz 单声道 float PCM 提取 L2 可归一的 embedding。
/// C API 内存契约：ComputeEmbedding 返回的指针必须 DestroyEmbedding；这里拷成 [Float] 后立即释放。
public final class SpeakerEmbedder {
    private let impl: OpaquePointer
    public let dim: Int

    /// - Parameter model: 声纹模型 .onnx 路径（CAM++ `3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced`）
    public init(model: String, numThreads: Int = 2) throws {
        var created: OpaquePointer?
        model.withCString { mp in
            "cpu".withCString { pp in
                var cfg = SherpaOnnxSpeakerEmbeddingExtractorConfig()
                cfg.model = mp
                cfg.num_threads = Int32(numThreads)
                cfg.debug = 0
                cfg.provider = pp
                created = SherpaOnnxCreateSpeakerEmbeddingExtractor(&cfg)
            }
        }
        guard let impl = created else {
            throw SpeakerError.modelLoadFailed(model)
        }
        self.impl = impl
        self.dim = Int(SherpaOnnxSpeakerEmbeddingExtractorDim(impl))
    }

    deinit {
        SherpaOnnxDestroySpeakerEmbeddingExtractor(impl)
    }

    /// 对一段 16kHz 单声道 float 样本提取声纹（已 L2 归一化，便于 cosine 比对）。
    /// 样本太短（<0.3s）或无效返回 nil。
    public func embed(_ samples: [Float], sampleRate: Int = 16000) -> [Float]? {
        guard samples.count >= Int(0.3 * Double(sampleRate)) else { return nil }
        let stream = SherpaOnnxSpeakerEmbeddingExtractorCreateStream(impl)
        defer { SherpaOnnxDestroyOnlineStream(stream) }
        samples.withUnsafeBufferPointer { buf in
            SherpaOnnxOnlineStreamAcceptWaveform(stream, Int32(sampleRate), buf.baseAddress, Int32(buf.count))
        }
        SherpaOnnxOnlineStreamInputFinished(stream)
        guard SherpaOnnxSpeakerEmbeddingExtractorIsReady(impl, stream) == 1 else { return nil }
        guard let p = SherpaOnnxSpeakerEmbeddingExtractorComputeEmbedding(impl, stream) else { return nil }
        defer { SherpaOnnxSpeakerEmbeddingExtractorDestroyEmbedding(p) }
        var v = [Float](UnsafeBufferPointer(start: p, count: dim))
        l2normalize(&v)
        return v
    }
}

public enum SpeakerError: Error, CustomStringConvertible {
    case modelLoadFailed(String)
    public var description: String {
        switch self {
        case .modelLoadFailed(let m): return "声纹模型加载失败：\(m)"
        }
    }
}

/// 就地 L2 归一化。
@inline(__always)
func l2normalize(_ v: inout [Float]) {
    var ss: Float = 0
    for x in v { ss += x * x }
    let n = ss.squareRoot()
    if n > 0 { for i in v.indices { v[i] /= n } }
}

/// 两个等长向量的 cosine（假定已 L2 归一化时等于点积；这里仍按通用 cosine 算，稳健）。
public func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    let d = (na.squareRoot() * nb.squareRoot())
    return d > 0 ? dot / d : 0
}
