import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import FluidAudio   // AudioConverter().resampleAudioFile → [Float]@16k

public enum MeetingRecorderError: Error, CustomStringConvertible {
    case noDisplay
    case micPermission
    case screenPermission(String)
    case startFailed(String)
    public var description: String {
        switch self {
        case .noDisplay: return "找不到可捕获的显示器（ScreenCaptureKit）"
        case .micPermission: return "麦克风权限被拒。首次从终端运行会请求授权，请允许后重试。"
        case .screenPermission(let m): return "屏幕录制权限/捕获启动失败：\(m)（系统设置 → 隐私与安全性 → 屏幕录制，勾选你的终端/App 后重试）"
        case .startFailed(let m): return "会议录音启动失败：\(m)"
        }
    }
}

/// 会议录音：ScreenCaptureKit 抓系统音频（=会议对方声音）+ 麦克风（=你），停止后重采样到 16k 混音成一个文件。
/// macOS 14：系统音频用 SCStream（13+），麦克风用 AVAudioEngine（15 才支持 SCStream 直接抓麦）。
public final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var sysInput: AVAssetWriterInput?
    private var sessionStarted = false
    private let audioQueue = DispatchQueue(label: "resound.meeting.sysaudio")

    private let engine = AVAudioEngine()
    private var micFile: AVAudioFile?

    private var sysURL: URL!
    private var micURL: URL!

    public override init() { super.init() }

    public func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }

    /// 录到按 Enter 或 maxSeconds，返回混好的 16k 单声道 wav 文件 URL。
    public func record(maxSeconds: Double?, log: (String) -> Void = { print($0) }) async throws -> URL {
        guard await requestMicPermission() else { throw MeetingRecorderError.micPermission }
        let tmp = FileManager.default.temporaryDirectory
        let uid = UUID().uuidString
        sysURL = tmp.appendingPathComponent("resound-sys-\(uid).m4a")
        micURL = tmp.appendingPathComponent("resound-mic-\(uid).caf")

        try await startSystemAudio(log: log)
        try startMic(log: log)

        log("🔴 会议录音中（麦克风 + 对方音）…  按 Enter 停止" +
            (maxSeconds.map { String(format: "（或 %.0fs 自动停止）", $0) } ?? ""))
        await waitForStop(maxSeconds: maxSeconds)

        // 停止两路
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micFile = nil
        if let stream { try? await stream.stopCapture() }
        sysInput?.markAsFinished()
        if let writer { await writer.finishWriting() }
        log("⏹  录音结束，混音中…")

        return try mixTo16k(log: log)
    }

    // MARK: 系统音频（ScreenCaptureKit → AVAssetWriter）

    private func startSystemAudio(log: (String) -> Void) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw MeetingRecorderError.screenPermission(error.localizedDescription)
        }
        guard let display = content.displays.first else { throw MeetingRecorderError.noDisplay }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.width = 2; cfg.height = 2   // 只要音频，视频设最小（不加 .screen 输出 → 不收视频帧）

        let w = try AVAssetWriter(outputURL: sysURL, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160000,
        ])
        input.expectsMediaDataInRealTime = true
        guard w.canAdd(input) else { throw MeetingRecorderError.startFailed("AVAssetWriter 不能加音频输入") }
        w.add(input); self.writer = w; self.sysInput = input

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        do {
            try await s.startCapture()
        } catch {
            throw MeetingRecorderError.screenPermission(error.localizedDescription)
        }
        self.stream = s
        log("  🖥  系统音频捕获已启动（ScreenCaptureKit）")
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer),
              let writer, let sysInput else { return }
        if !sessionStarted {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            sessionStarted = true
        }
        if sysInput.isReadyForMoreMediaData { sysInput.append(sampleBuffer) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // 捕获意外停止：留给 stop 流程收尾
    }

    // MARK: 麦克风（AVAudioEngine → AVAudioFile）

    private func startMic(log: (String) -> Void) throws {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        do {
            let f = try AVAudioFile(forWriting: micURL, settings: fmt.settings)
            self.micFile = f
        } catch { throw MeetingRecorderError.startFailed("麦克风文件创建失败：\(error.localizedDescription)") }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, _ in
            try? self?.micFile?.write(from: buf)
        }
        do { try engine.start() }
        catch { throw MeetingRecorderError.startFailed("AVAudioEngine 启动失败：\(error.localizedDescription)") }
        log("  🎙  麦克风捕获已启动")
    }

    // MARK: 混音（两路各自重采样到 16k 单声道 → 相加 → 写 wav）

    private func mixTo16k(log: (String) -> Void) throws -> URL {
        let mic = (try? AudioConverter().resampleAudioFile(micURL)) ?? []
        let sys = (try? AudioConverter().resampleAudioFile(sysURL)) ?? []
        let n = max(mic.count, sys.count)
        guard n > 0 else { throw MeetingRecorderError.startFailed("两路录音都为空（检查麦克风/屏幕录制权限）") }
        var mixed = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = i < mic.count ? mic[i] : 0
            let b = i < sys.count ? sys[i] : 0
            mixed[i] = max(-1, min(1, a * 0.8 + b * 0.8))   // 轻微抬高再硬限幅，防混音后过小
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resound-meeting-\(UUID().uuidString).wav")
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let outFile = try AVAudioFile(forWriting: outURL, settings: fmt.settings)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        mixed.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: n)
        }
        try outFile.write(from: buf)
        log(String(format: "  ✅ 混音完成：%.0fs（麦克风 %.0fs + 系统 %.0fs）",
                   Double(n)/16000, Double(mic.count)/16000, Double(sys.count)/16000))
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: sysURL)
        return outURL
    }

    private func waitForStop(maxSeconds: Double?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let done = DispatchSemaphore(value: 0)
            var resumed = false
            let resumeOnce = { if !resumed { resumed = true; cont.resume() } }
            DispatchQueue.global().async { _ = readLine(); done.signal() }
            DispatchQueue.global().async {
                if let m = maxSeconds { _ = done.wait(timeout: .now() + m) } else { done.wait() }
                resumeOnce()
            }
        }
    }
}
