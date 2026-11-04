import XCTest
import AVFoundation
@testable import ResoundCore

/// 分轨去重（`TrackDedup`）：用合成「音节」信号固定四条底线——
/// 无副本不动原混音、两个方向的滞后都认得出、非重复内容不被压、副本确实被压低。
/// 真实会议上的效果见 DECISIONS 2026-11-02（MOSS 对比），这里只守行为不回退。
final class TrackDedupTests: XCTestCase {
    let sr = 16000

    /// Speech-like bursts: noise modulated by random 150–400ms syllables, active only inside `active`.
    func syllables(seconds: Double, seed: UInt64, active: (Double) -> Bool = { _ in true }) -> [Float] {
        var rng = SplitMix(seed: seed)
        let n = Int(seconds * Double(sr))
        var out = [Float](repeating: 0, count: n)
        var i = 0
        while i < n {
            let len = Int(Double(sr) * (0.15 + 0.25 * rng.unit()))
            let gap = Int(Double(sr) * (0.05 + 0.2 * rng.unit()))
            let amp = Float(0.1 + 0.3 * rng.unit())
            if active(Double(i) / Double(sr)) {
                for k in 0..<min(len, n - i) {
                    let w = sin(Float.pi * Float(k) / Float(len))
                    out[i + k] = amp * w * Float(rng.unit() * 2 - 1)
                }
            }
            i += len + gap
        }
        return out
    }

    func delayed(_ x: [Float], ms: Int, gain: Float) -> [Float] {
        let d = ms * sr / 1000
        return [Float](repeating: 0, count: d) + x.dropLast(d).map { $0 * gain }
    }

    func noise(_ n: Int, level: Float, seed: UInt64) -> [Float] {
        var rng = SplitMix(seed: seed)
        return (0..<n).map { _ in level * Float(rng.unit() * 2 - 1) }
    }

    func add(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 + $1 } }

    func wav(_ x: [Float]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dedup-test-\(UUID().uuidString).wav")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sr), channels: 1, interleaved: false)!
        let f = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count))!
        x.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        buf.frameLength = AVAudioFrameCount(x.count)
        try f.write(from: buf)
        return url
    }

    func read(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
        try f.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }

    func energyDB(_ x: [Float], _ range: Range<Double>) -> Double {
        let a = Int(range.lowerBound * Double(sr)), b = min(x.count, Int(range.upperBound * Double(sr)))
        let e = x[a..<b].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(b - a)
        return 10 * log10(e + 1e-12)
    }

    func testIndependentTracksLeaveMixUntouched() throws {
        let mic = add(syllables(seconds: 40, seed: 1), noise(40 * sr, level: 0.002, seed: 11))
        let sys = add(syllables(seconds: 40, seed: 2), noise(40 * sr, level: 0.002, seed: 12))
        XCTAssertNil(try TrackDedup.dedupMix(mic: wav(mic), sys: wav(sys)))
    }

    func testDetectsSystemTrackAsLateCopy() throws {
        // room voice A on the mic comes back through Meet 250ms later on the system track
        let a = syllables(seconds: 40, seed: 3)
        let mic = add(a, noise(a.count, level: 0.002, seed: 13))
        let sys = add(delayed(a, ms: 250, gain: 1.5), noise(a.count, level: 0.0005, seed: 14))
        let r = try XCTUnwrap(TrackDedup.dedupMix(mic: wav(mic), sys: wav(sys)))
        XCTAssertGreaterThan(r.report.sysLateFraction, 0.8)
        XCTAssertEqual(Double(r.report.sysLateMedianMs ?? 0), 250, accuracy: 30)
        XCTAssertLessThan(r.report.micLateFraction, 0.1)
    }

    func testDetectsMicAsSpeakerEcho() throws {
        // remote voice on the system track replayed by the laptop speaker into the mic 70ms later
        let a = syllables(seconds: 40, seed: 4)
        let sys = add(a, noise(a.count, level: 0.0005, seed: 15))
        let mic = add(delayed(a, ms: 70, gain: 0.5), noise(a.count, level: 0.002, seed: 16))
        let r = try XCTUnwrap(TrackDedup.dedupMix(mic: wav(mic), sys: wav(sys)))
        XCTAssertGreaterThan(r.report.micLateFraction, 0.8)
        XCTAssertEqual(Double(r.report.micLateMedianMs ?? 0), 70, accuracy: 30)
        XCTAssertGreaterThan(r.report.keptSysFraction, 0.5)   // cleaner track keeps the voice
    }

    func testSuppressesCopyButKeepsOwnVoice() throws {
        // remote voice A (echoed into the mic) during 0–30s; the local user B speaks alone 30–40s
        let a = syllables(seconds: 40, seed: 5, active: { $0 < 30 })
        let b = syllables(seconds: 40, seed: 6, active: { $0 >= 30 })
        let sys = add(a, noise(a.count, level: 0.0005, seed: 17))
        let mic = add(add(delayed(a, ms: 70, gain: 0.8), b), noise(a.count, level: 0.002, seed: 18))
        let r = try XCTUnwrap(TrackDedup.dedupMix(mic: wav(mic), sys: wav(sys)))
        let out = try read(r.url)
        let raw = zip(mic, sys).map { max(-1, min(1, 0.8 * $0 + 0.8 * $1)) }
        // echo removed: during A the mix loses most of the mic's copy (raw ≈ A + 0.8A → ~2 dB louder)
        XCTAssertLessThan(energyDB(out, 5..<28) - energyDB(raw, 5..<28), -1.5)
        let echoOnly = zip(out, sys).map { $0 - 0.8 * $1 }   // what is left besides the kept system track
        let echoRaw = zip(raw, sys).map { $0 - 0.8 * $1 }
        XCTAssertLessThan(energyDB(echoOnly, 5..<28) - energyDB(echoRaw, 5..<28), -8)
        // the user's own voice (not in the system track) passes through
        XCTAssertEqual(energyDB(out, 31..<39), energyDB(raw, 31..<39), accuracy: 1.0)
    }
}

/// Deterministic PRNG so the synthetic signals are reproducible.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
