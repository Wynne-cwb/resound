import Foundation
import AVFoundation
import Accelerate

/// 会议分轨去重（只用于 MOSS 转录输入）：麦克风轨与系统轨里常有一条是另一条的**延迟副本**——
/// ①同房间的人说话 → 本机麦克风先收到 → 同事电脑的 Meet 麦克风再收一遍 → 系统轨晚 0.2–0.6s 回来；
/// ②远端声音 → 系统轨 → 笔记本/会议室设备外放 → 麦克风晚 60ms–0.9s 再收一遍。
/// 直接混音送 MOSS，回声会被当成「第二个说话人」、同一句话出现两次（2026-11-02 实测 4 分钟片段 64 对）。
///
/// 做法（与 experiments 原型同参，见 DECISIONS 2026-11-02「麦克风轨 / 系统轨重复语音去重」）：
/// 1. 10ms log-RMS 包络按 8s 窗口互相关，两个方向各自估滞后（±1.5s；滞后会漂移、会跳变，两个方向可并存）；
/// 2. STFT 512/160 + 24 个 mel 频带：用另一轨移位 D（±30ms 容差）预测副本功率，频带耦合按窗口估计；
/// 3. 软增益 max(0.05, 1 − 3·P/|X|²) 压副本——不硬切，真实双讲大部分保留；
/// 4. 保留哪一份按信噪比定（同房间回传时晚到的 Meet 副本反而更干净），压另一份；
/// 5. 0.8·mic + 0.8·sys 混音（与 StreamingMix 同口径），写 16k mono wav。
/// 两轨都检测不到副本 → 返回 nil，调用方用原混音（干净会议零改动）。全程流式：解码成临时 raw float 后 mmap，
/// 按 8s 块处理，不把整场音频读进内存（1.5h 会议两轨约 690MB）。
public enum TrackDedup {

    public struct Report: Sendable {
        public let sysLateFraction: Double   // share of frames where sys carries a delayed copy of mic
        public let micLateFraction: Double   // share of frames where mic carries a delayed copy of sys
        public let sysLateMedianMs: Int?
        public let micLateMedianMs: Int?
        public let keptSysFraction: Double   // among duplicated frames, how often the sys copy was kept
        public var summary: String {
            func part(_ name: String, _ f: Double, _ ms: Int?) -> String? {
                guard f > 0, let ms else { return nil }
                return String(format: "%@晚 %dms（%.0f%%）", name, ms, f * 100)
            }
            let parts = [part("系统轨", sysLateFraction, sysLateMedianMs), part("麦克风", micLateFraction, micLateMedianMs)]
                .compactMap { $0 }
            return parts.joined(separator: "、") + String(format: "，重复处保留%@", keptSysFraction >= 0.5 ? "系统轨" : "麦克风")
        }
    }

    // MARK: parameters (validated in the 2026-11-02 experiment; change together with a re-run of it)

    static let sr = 16000.0
    static let hop = 160                 // 10ms
    static let nfft = 512
    static let bins = nfft / 2 + 1
    static let bands = 24
    // delay tracking (envelope frames)
    static let trackWin = 800, trackHop = 200, maxLag = 150, minLag = 3
    static let corrThreshold: Float = 0.45, sidelobeMargin: Float = 0.15, minEnvStd: Float = 0.3
    static let consistencyReach = 3, consistencyTol = 4, consistencyVotes = 2   // windows (2s hop), frames
    // suppression
    static let block = 800, tol = 3, beta: Float = 3, gainFloor: Float = 0.05
    static let couplingQuantile: Float = 0.7, loudRefShare: Float = 0.3
    /// Below this share of frames in both directions the meeting counts as duplicate-free.
    static let minDuplicateShare = 0.02

    /// Dedup the two aligned tracks and write the mix. nil = no duplicates found (use the original mix).
    public static func dedupMix(mic micURL: URL, sys sysURL: URL,
                                outputDir: URL = FileManager.default.temporaryDirectory,
                                log: (String) -> Void = { _ in }) throws -> (url: URL, report: Report)? {
        guard let r = try run(mic: micURL, sys: sysURL, outputDir: outputDir, synthesize: true, log: log),
              let url = r.url else { return nil }
        return (url, r.report)
    }

    /// Detection only (no audio written): what dedupMix would find. nil = duplicate-free.
    public static func detect(mic micURL: URL, sys sysURL: URL) throws -> Report? {
        try run(mic: micURL, sys: sysURL, outputDir: FileManager.default.temporaryDirectory,
                synthesize: false, log: { _ in })?.report
    }

    private static func run(mic micURL: URL, sys sysURL: URL, outputDir: URL, synthesize doSynth: Bool,
                            log: (String) -> Void) throws -> (url: URL?, report: Report)? {
        let fm = FileManager.default
        let uid = UUID().uuidString
        let micRaw = outputDir.appendingPathComponent("resound-dedup-\(uid)-mic.f32")
        let sysRaw = outputDir.appendingPathComponent("resound-dedup-\(uid)-sys.f32")
        defer { try? fm.removeItem(at: micRaw); try? fm.removeItem(at: sysRaw) }
        let em = try decodeRaw(micURL, to: micRaw)
        let es = try decodeRaw(sysURL, to: sysRaw)

        let n = min(em.count, es.count)
        guard n >= trackWin + 2 * maxLag else { return nil }
        let (lagS, lagM) = trackDelays(em: Array(em[..<n]), es: Array(es[..<n]))
        let fracS = Double(lagS.filter { $0 >= 0 }.count) / Double(n)
        let fracM = Double(lagM.filter { $0 >= 0 }.count) / Double(n)
        guard fracS >= minDuplicateShare || fracM >= minDuplicateShare else { return nil }

        let qm = qualityTrack(em), qs = qualityTrack(es)
        // keep policy per frame: the copy on the higher-SNR track survives
        var keptSys = 0, dupFrames = 0
        for t in 0..<n where lagS[t] >= 0 || lagM[t] >= 0 {
            dupFrames += 1; if qs[t] >= qm[t] { keptSys += 1 }
        }
        let report = Report(
            sysLateFraction: fracS, micLateFraction: fracM,
            sysLateMedianMs: median(lagS.filter { $0 >= 0 }).map { $0 * 10 },
            micLateMedianMs: median(lagM.filter { $0 >= 0 }).map { $0 * 10 },
            keptSysFraction: dupFrames > 0 ? Double(keptSys) / Double(dupFrames) : 1)

        // Suppression plans. Target track X loses the copy that reference R predicts at frame t + sign·D.
        //   sys-late dup, keep mic → sys from mic(t−D);  keep sys → mic from sys(t+D)
        //   mic-late dup, keep sys → mic from sys(t−D);  keep mic → sys from mic(t+D)
        func masked(_ lag: [Int], _ keep: (Int) -> Bool) -> [Int] {
            (0..<n).map { lag[$0] >= 0 && keep($0) ? lag[$0] : -1 }
        }
        let keepMic: (Int) -> Bool = { qm[$0] >= qs[$0] }
        let keepSys: (Int) -> Bool = { qs[$0] >= qm[$0] }
        let sysPlans = [Plan(lag: masked(lagS, keepMic), sign: -1), Plan(lag: masked(lagM, { !keepSys($0) }), sign: +1)]
        let micPlans = [Plan(lag: masked(lagM, keepSys), sign: -1), Plan(lag: masked(lagS, { !keepMic($0) }), sign: +1)]

        guard doSynth else { return (nil, report) }
        let out = outputDir.appendingPathComponent("resound-dedup-\(uid).wav")
        try? fm.removeItem(at: out)
        let micData = try Data(contentsOf: micRaw, options: .alwaysMapped)
        let sysData = try Data(contentsOf: sysRaw, options: .alwaysMapped)
        try micData.withUnsafeBytes { mb in
            try sysData.withUnsafeBytes { sb in
                try synthesize(mic: mb.bindMemory(to: Float.self), sys: sb.bindMemory(to: Float.self),
                               micPlans: micPlans, sysPlans: sysPlans, to: out)
            }
        }
        log("   🔁 分轨去重：" + report.summary)
        return (out, report)
    }

    struct Plan { let lag: [Int]; let sign: Int }

    // MARK: decode + envelope

    /// Stream-decode to 16k mono raw float32 on disk, returning the 10ms log-RMS envelope.
    static func decodeRaw(_ url: URL, to raw: URL) throws -> [Float] {
        guard let r = StreamResampler16k(url: url, leadFrames: 0) else {
            throw NSError(domain: "TrackDedup", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "读不了分轨：\(url.lastPathComponent)"])
        }
        FileManager.default.createFile(atPath: raw.path, contents: nil)
        let fh = try FileHandle(forWritingTo: raw)
        defer { try? fh.close() }
        let cap = 16000
        var buf = [Float](repeating: 0, count: cap)
        var pending: [Float] = []   // samples not yet forming a whole 10ms frame
        var env: [Float] = []
        while true {
            let got = buf.withUnsafeMutableBufferPointer { r.read(into: $0.baseAddress!, cap: cap) }
            if got == 0 { break }
            buf.withUnsafeBufferPointer { fh.write(Data(buffer: UnsafeBufferPointer(rebasing: $0[..<got]))) }
            pending.append(contentsOf: buf[..<got])
            let whole = pending.count / hop * hop
            var i = 0
            while i < whole {
                var ms: Float = 0
                pending.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + i, 1, &ms, vDSP_Length(hop)) }
                env.append(log(sqrt(ms) + 1e-5))
                i += hop
            }
            pending.removeFirst(whole)
        }
        return env
    }

    // MARK: delay tracking

    /// Per envelope frame: sys-late lag (sys[t+D] ≈ mic[t]) and mic-late lag (mic[t+D] ≈ sys[t]), −1 = none.
    /// The weaker direction of a window is accepted only as an interior local max that the main peak's
    /// envelope autocorrelation cannot explain (c_weak > c_main·ac(D_main+D_weak) + margin).
    static func trackDelays(em: [Float], es: [Float]) -> (sysLate: [Int], micLate: [Int]) {
        let n = min(em.count, es.count), W = trackWin, L = maxLag
        func padded(_ x: [Float]) -> [Float] {
            var m: Float = 0; vDSP_meanv(x, 1, &m, vDSP_Length(n))
            return [Float](repeating: m, count: L) + x[..<n] + [Float](repeating: m, count: L)
        }
        let esp = padded(es)
        // prefix sums of the padded sys envelope for O(1) sliding mean/std
        var ps = [Double](repeating: 0, count: esp.count + 1), ps2 = ps
        for i in 0..<esp.count { ps[i + 1] = ps[i] + Double(esp[i]); ps2[i + 1] = ps2[i] + Double(esp[i]) * Double(esp[i]) }

        var starts: [Int] = [], sysL: [Int] = [], micL: [Int] = []  // per-window lag, −1 = none
        var s = 0
        repeat {
            starts.append(s)
            var bestS = -1, bestM = -1
            let a = Array(em[s..<(s + W)])
            if std(a) > minEnvStd && std(Array(es[s..<(s + W)])) > minEnvStd {
                var a0 = a; standardize(&a0)
                var c = [Float](repeating: 0, count: 2 * L + 1)   // c[L + lag]: sys[t+lag] vs mic[t]
                esp.withUnsafeBufferPointer { e in
                    for k in 0...(2 * L) {
                        var dot: Float = 0
                        vDSP_dotpr(a0, 1, e.baseAddress! + s + k, 1, &dot, vDSP_Length(W))
                        let sum = ps[s + k + W] - ps[s + k], sum2 = ps2[s + k + W] - ps2[s + k]
                        let mean = sum / Double(W)
                        let sd = sqrt(max(0, sum2 / Double(W) - mean * mean)) + 1e-9
                        c[k] = dot / (Float(W) * Float(sd))
                    }
                }
                let pos = Array(c[(L + minLag)...])                       // pos[i] → sys late by i+minLag
                let neg = Array(c[0...(L - minLag)].reversed())           // neg[i] → mic late by i+minLag
                let ip = argmax(pos), ineg = argmax(neg)
                // a peak at the search boundary is a slope (e.g. plain co-activity near lag 0), not a copy
                let cs = (0 < ip && ip < pos.count - 1) ? pos[ip] : 0, cm = (0 < ineg && ineg < neg.count - 1) ? neg[ineg] : 0
                let dS = ip + minLag, dM = ineg + minLag
                let sysMain = cs >= cm
                let (cMain, cWeak) = sysMain ? (cs, cm) : (cm, cs)
                if cMain >= corrThreshold {
                    var weakOK = false
                    if cWeak >= corrThreshold {
                        let seg = Array((sysMain ? em : es)[s..<(s + W)])
                        let off = dS + dM
                        let ac = off < W - 50 ? corr(Array(seg[..<(W - off)]), Array(seg[off...])) : 0
                        weakOK = cWeak > cMain * max(ac, 0) + sidelobeMargin
                    }
                    if sysMain { bestS = dS; if weakOK { bestM = dM } }
                    else { bestM = dM; if weakOK { bestS = dS } }
                }
            }
            sysL.append(bestS); micL.append(bestM)
            s += trackHop
        } while s < n - W

        sysL = consistent(sysL); micL = consistent(micL)
        var outS = [Int](repeating: -1, count: n), outM = outS
        for (i, st) in starts.enumerated() {
            var a = st + W / 2 - trackHop / 2, b = a + trackHop
            if i == 0 { a = 0 }
            if i == starts.count - 1 { b = n }
            for t in max(0, a)..<min(n, b) { outS[t] = sysL[i]; outM[t] = micL[i] }
        }
        return (outS, outM)
    }

    /// A real echo path keeps its delay across neighbouring windows (slow drift, or a step that then
    /// holds); a chance correlation peak lands on a random lag. Keep a window's lag only when at least
    /// `consistencyVotes` other windows within ±`consistencyReach` agree within ±`consistencyTol` frames.
    static func consistent(_ lags: [Int]) -> [Int] {
        lags.indices.map { i in
            guard lags[i] >= 0 else { return -1 }
            let lo = max(0, i - consistencyReach), hi = min(lags.count - 1, i + consistencyReach)
            let votes = (lo...hi).filter { $0 != i && lags[$0] >= 0 && abs(lags[$0] - lags[i]) <= consistencyTol }.count
            return votes >= consistencyVotes ? lags[i] : -1
        }
    }

    /// Per-frame quality proxy (dB): speech level (p85) minus noise floor (p10) over a centered ~30s window.
    static func qualityTrack(_ e: [Float]) -> [Float] {
        let db = e.map { $0 * 20 / Float(M_LN10) }
        let n = db.count
        var out = [Float](repeating: 0, count: n)
        var s = 0
        while s < n {
            let seg = Array(db[max(0, s - 1500)..<min(n, s + 1500)]).sorted()
            let v = quantileSorted(seg, 0.85) - quantileSorted(seg, 0.10)
            for t in s..<min(n, s + 500) { out[t] = v }
            s += 500
        }
        return out
    }

    // MARK: STFT suppression + mix

    final class FFT {
        let fwd: vDSP_DFT_Setup, inv: vDSP_DFT_Setup
        let window: [Float]
        init() {
            fwd = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(TrackDedup.nfft), .FORWARD)!
            inv = vDSP_DFT_zrop_CreateSetup(fwd, vDSP_Length(TrackDedup.nfft), .INVERSE)!
            window = (0..<TrackDedup.nfft).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(TrackDedup.nfft)) }
        }
        deinit { vDSP_DFT_DestroySetup(fwd); vDSP_DFT_DestroySetup(inv) }
    }

    /// Spectra of one frame range: packed (re, im) per frame as vDSP returns them (re[0]=DC, im[0]=Nyquist),
    /// plus band powers in scipy's "spectrum" scaling (|DFT|/sum(window)) so thresholds match the prototype.
    struct Spectra {
        var re: [[Float]], im: [[Float]], band: [[Float]]   // [frame][...]
    }

    static func melBands() -> (weights: [[Float]], spread: [[Float]], covered: [Bool]) {
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func imel(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(80), hi = mel(7600)
        let edges = (0..<(bands + 2)).map { imel(lo + (hi - lo) * Double($0) / Double(bands + 1)) }
        var B = [[Float]](repeating: [Float](repeating: 0, count: bins), count: bands)
        for b in 0..<bands {
            let (l, c, r) = (edges[b], edges[b + 1], edges[b + 2])
            for k in 0..<bins {
                let f = Double(k) * sr / 2 / Double(bins - 1)
                B[b][k] = Float(max(0, min((f - l) / (c - l), (r - f) / (r - c))))
            }
        }
        var cov = [Float](repeating: 0, count: bins)
        for b in 0..<bands { for k in 0..<bins { cov[k] += B[b][k] } }
        let spread = (0..<bands).map { b in (0..<bins).map { k in B[b][k] / (cov[k] + 1e-9) } }
        return (B, spread, cov.map { $0 >= 1e-3 })
    }

    static func spectra(_ x: UnsafeBufferPointer<Float>, frames: Range<Int>, fft: FFT, bandW: [[Float]]) -> Spectra {
        let half = nfft / 2
        var sp = Spectra(re: [], im: [], band: [])
        sp.re.reserveCapacity(frames.count); sp.im.reserveCapacity(frames.count); sp.band.reserveCapacity(frames.count)
        var ev = [Float](repeating: 0, count: half), od = ev
        let scale = 1 / Float(2 * 256)   // vDSP forward = 2·DFT; scipy divides by sum(hann512) = 256
        for t in frames {
            let start = t * hop - (nfft - hop)
            for i in 0..<half {
                let a = start + 2 * i, b = a + 1
                ev[i] = (a >= 0 && a < x.count ? x[a] : 0) * fft.window[2 * i]
                od[i] = (b >= 0 && b < x.count ? x[b] : 0) * fft.window[2 * i + 1]
            }
            var re = [Float](repeating: 0, count: half), im = re
            vDSP_DFT_Execute(fft.fwd, ev, od, &re, &im)
            var pw = [Float](repeating: 0, count: bins)
            pw[0] = re[0] * re[0] * scale * scale
            pw[half] = im[0] * im[0] * scale * scale
            for k in 1..<half { pw[k] = (re[k] * re[k] + im[k] * im[k]) * scale * scale }
            var band = [Float](repeating: 0, count: bands)
            for b in 0..<bands { vDSP_dotpr(bandW[b], 1, pw, 1, &band[b], vDSP_Length(bins)) }
            sp.re.append(re); sp.im.append(im); sp.band.append(band)
        }
        return sp
    }

    /// Band gains for target frames `gainFrames` (subset of the context range starting at `ctx0`).
    static func bandGains(target X: Spectra, ref R: Spectra, ctx0: Int, totalFrames T: Int,
                          gainFrames: Range<Int>, coupleFrames: Range<Int>, plan: Plan) -> [[Float]]? {
        func lagAt(_ t: Int) -> Int { t < plan.lag.count ? plan.lag[t] : -1 }
        guard gainFrames.contains(where: { lagAt($0) >= 0 }) else { return nil }
        // delayed reference band power with ±tol tolerance
        var Eh = [[Float]](repeating: [Float](repeating: 0, count: bands), count: gainFrames.count)
        for (j, t) in gainFrames.enumerated() where lagAt(t) >= 0 {
            let center = t + plan.sign * lagAt(t)
            for k in -tol...tol {
                let r = min(max(center + k, 0), T - 1) - ctx0
                guard r >= 0, r < R.band.count else { continue }
                for b in 0..<bands { Eh[j][b] = max(Eh[j][b], R.band[r][b]) }
            }
        }
        // per-band coupling from the block's frames where the delayed reference is loud
        let eps: Float = 1e-10
        var g = [Float](repeating: 0, count: bands)
        let onIdx = coupleFrames.compactMap { t -> Int? in lagAt(t) >= 0 ? t - gainFrames.lowerBound : nil }
            .filter { $0 >= 0 && $0 < gainFrames.count }
        if !onIdx.isEmpty {
            for b in 0..<bands {
                let thr = quantileSorted(onIdx.map { Eh[$0][b] }.sorted(), 1 - loudRefShare)
                let ratios = onIdx.filter { Eh[$0][b] >= thr }
                    .map { X.band[gainFrames.lowerBound + $0 - ctx0][b] / (Eh[$0][b] + eps) }
                if ratios.count > 20 { g[b] = quantileSorted(ratios.sorted(), couplingQuantile) }
            }
        }
        var G = [[Float]](repeating: [Float](repeating: 1, count: bands), count: gainFrames.count)
        for (j, t) in gainFrames.enumerated() where lagAt(t) >= 0 {
            let xb = X.band[t - ctx0]
            for b in 0..<bands { G[j][b] = min(1, max(gainFloor, 1 - beta * g[b] * Eh[j][b] / (xb[b] + eps))) }
        }
        return G
    }

    static func synthesize(mic: UnsafeBufferPointer<Float>, sys: UnsafeBufferPointer<Float>,
                           micPlans: [Plan], sysPlans: [Plan], to out: URL) throws {
        let fft = FFT()
        let (bandW, spread, covered) = melBands()
        let spreadFlat = spread.flatMap { $0 }   // bands × bins, row-major
        let total = max(mic.count, sys.count)
        let T = (total + hop - 1) / hop
        let half = nfft / 2
        let ctx = maxLag + tol + 1
        // OLA normalization (scipy istft): sum of squared windows, periodic in hop
        var den = [Float](repeating: 0, count: hop)
        for p in 0..<nfft { den[((p - (nfft - hop)) % hop + hop) % hop] += fft.window[p] * fft.window[p] }

        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: out, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        // accumulators cover samples [accBase, accBase + acc.count)
        var accBase = -(nfft - hop)
        var accM: [Float] = [], accS: [Float] = []
        func flush(upTo end: Int) throws {
            let from = max(accBase, 0), to = min(end, total)
            guard to > from else { return }
            let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(to - from))!
            let d = pcm.floatChannelData![0]
            for n in from..<to {
                let i = n - accBase, w = den[n % hop]
                d[n - from] = max(-1, min(1, 0.8 * accM[i] / w + 0.8 * accS[i] / w))
            }
            pcm.frameLength = AVAudioFrameCount(to - from)
            try file.write(from: pcm)
            let drop = to - accBase
            accM.removeFirst(min(drop, accM.count)); accS.removeFirst(min(drop, accS.count)); accBase = to
        }

        var ev = [Float](repeating: 0, count: half), od = ev
        var b0 = 0
        while b0 < T {
            let b1 = min(T, b0 + block)
            let c0 = max(0, b0 - ctx), c1 = min(T, b1 + ctx)
            let M = spectra(mic, frames: c0..<c1, fft: fft, bandW: bandW)
            let S = spectra(sys, frames: c0..<c1, fft: fft, bandW: bandW)
            let gf = max(0, b0 - 1)..<min(T, b1 + 1)   // one frame of margin for the temporal smoothing
            func binGains(_ X: Spectra, _ R: Spectra, _ plans: [Plan]) -> [[Float]]? {
                var out: [[Float]]? = nil
                for plan in plans {
                    guard var G = bandGains(target: X, ref: R, ctx0: c0, totalFrames: T,
                                            gainFrames: gf, coupleFrames: b0..<b1, plan: plan) else { continue }
                    let raw = G
                    for j in 0..<G.count {   // 3-frame moving average against musical noise
                        let a = max(0, j - 1), c = min(G.count - 1, j + 1)
                        for b in 0..<bands { G[j][b] = (raw[a][b] + raw[j][b] + raw[c][b]) / 3 }
                    }
                    // band → bin: (frames × bands) · (bands × bins), then amplitude gain = sqrt(power gain)
                    let rows = b1 - b0
                    let gFlat = G[(b0 - gf.lowerBound)..<(b1 - gf.lowerBound)].flatMap { $0 }
                    var prod = [Float](repeating: 0, count: rows * bins)
                    vDSP_mmul(gFlat, 1, spreadFlat, 1, &prod, 1, vDSP_Length(rows), vDSP_Length(bins), vDSP_Length(bands))
                    var res = [[Float]](repeating: [Float](repeating: 1, count: bins), count: rows)
                    for i in 0..<rows {
                        for k in 0..<bins where covered[k] { res[i][k] = sqrt(min(1, max(gainFloor, prod[i * bins + k]))) }
                    }
                    if let prev = out { for i in 0..<res.count { for k in 0..<bins { res[i][k] *= prev[i][k] } } }
                    out = res
                }
                return out
            }
            let gm = binGains(M, S, micPlans), gs = binGains(S, M, sysPlans)

            // grow accumulators to cover this block's frames
            let needEnd = b1 * hop + hop
            let grow = needEnd - (accBase + accM.count)
            if grow > 0 { accM += [Float](repeating: 0, count: grow); accS += [Float](repeating: 0, count: grow) }
            for t in b0..<b1 {
                let fi = t - c0
                for (spec, gains, isMic) in [(M, gm, true), (S, gs, false)] {
                    var re = spec.re[fi], im = spec.im[fi]
                    if let g = gains?[t - b0] {
                        re[0] *= g[0]; im[0] *= g[half]
                        for k in 1..<half { re[k] *= g[k]; im[k] *= g[k] }
                    }
                    vDSP_DFT_Execute(fft.inv, re, im, &ev, &od)
                    let start = t * hop - (nfft - hop) - accBase
                    for i in 0..<half {
                        let y0 = ev[i] / 1024 * fft.window[2 * i], y1 = od[i] / 1024 * fft.window[2 * i + 1]
                        if isMic { accM[start + 2 * i] += y0; accM[start + 2 * i + 1] += y1 }
                        else { accS[start + 2 * i] += y0; accS[start + 2 * i + 1] += y1 }
                    }
                }
            }
            // samples before the next frame's window start are final
            try flush(upTo: b1 * hop - (nfft - hop))
            b0 = b1
        }
        try flush(upTo: total)
    }

    // MARK: small numeric helpers

    /// Population standard deviation (numpy default).
    static func std(_ x: [Float]) -> Float {
        var m: Float = 0; vDSP_meanv(x, 1, &m, vDSP_Length(x.count))
        var neg = -m, centered = [Float](repeating: 0, count: x.count), ss: Float = 0
        vDSP_vsadd(x, 1, &neg, &centered, 1, vDSP_Length(x.count))
        vDSP_svesq(centered, 1, &ss, vDSP_Length(x.count))
        return sqrt(ss / Float(x.count))
    }
    static func standardize(_ x: inout [Float]) {
        var m: Float = 0; vDSP_meanv(x, 1, &m, vDSP_Length(x.count))
        let sd = std(x) + 1e-9
        x = x.map { ($0 - m) / sd }
    }
    static func corr(_ a: [Float], _ b: [Float]) -> Float {
        var x = a, y = b; standardize(&x); standardize(&y)
        var d: Float = 0; vDSP_dotpr(x, 1, y, 1, &d, vDSP_Length(x.count))
        return d / Float(x.count)
    }
    static func argmax(_ x: [Float]) -> Int {
        var v: Float = 0; var i: vDSP_Length = 0
        vDSP_maxvi(x, 1, &v, &i, vDSP_Length(x.count)); return Int(i)
    }
    /// numpy-style linear-interpolated quantile of an ascending array.
    static func quantileSorted(_ s: [Float], _ q: Float) -> Float {
        guard !s.isEmpty else { return 0 }
        let pos = q * Float(s.count - 1), i = Int(pos), f = pos - Float(i)
        return i + 1 < s.count ? s[i] * (1 - f) + s[i + 1] * f : s[i]
    }
    static func median(_ x: [Int]) -> Int? { x.isEmpty ? nil : x.sorted()[x.count / 2] }
}
