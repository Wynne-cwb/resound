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

/// 会议录音：ScreenCaptureKit 抓系统音频（=会议对方声音）+ 麦克风（=你），停止后重采样到 16k、
/// 按两轨真实起点对齐补零 → 混音（audio.m4a 播放用）+ **保留对齐后的分轨**（分开转录用，见 dual-track spec）。
/// macOS 14：系统音频用 SCStream（13+），麦克风用 AVAudioEngine（15 才支持 SCStream 直接抓麦）。
public final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    /// 停止录音的产物：混音 + 对齐后的两条分轨（16k mono wav 临时文件，入库后由调用方清理）。
    public struct Capture {
        public let mixed: URL       // 对齐后混音（audio.m4a 的来源，播放/说话人识别时间轴锚点）
        public let mic: URL?        // 麦克风轨（本地侧），已对齐到与 mixed 同一时间轴；空轨为 nil
        public let sys: URL?        // 系统音频轨（线上侧），同上
    }

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var sysInput: AVAssetWriterInput?
    private var sessionStarted = false
    private let audioQueue = DispatchQueue(label: "resound.meeting.sysaudio")

    private let engine = AVAudioEngine()
    private var micFile: AVAudioFile?

    private var sysURL: URL!
    private var micURL: URL!
    // 两轨真实起点（mach host clock 秒）：SCStream 先启动、麦克风后启动，起点差要用补零对齐，
    // 否则混音错位 + 分轨转录的时间戳不在同一轴上。
    private var sysStartHost: Double?
    private var micStartHost: Double?

    public override init() { super.init() }

    public func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }

    /// 开始捕获（麦克风 + 系统音）。GUI 用：配 finishCapture() 由界面控制停止。
    public func startCapture(log: (String) -> Void = { print($0) }) async throws {
        guard await requestMicPermission() else { throw MeetingRecorderError.micPermission }
        let tmp = FileManager.default.temporaryDirectory
        let uid = UUID().uuidString
        sysURL = tmp.appendingPathComponent("resound-sys-\(uid).m4a")
        micURL = tmp.appendingPathComponent("resound-mic-\(uid).caf")
        try await startSystemAudio(log: log)
        try startMic(log: log)
    }

    /// 停止捕获并对齐混音，返回混音 + 分轨（16k 单声道 wav）。
    public func finishCapture(log: (String) -> Void = { print($0) }) async throws -> Capture {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        micFile = nil
        if let stream { try? await stream.stopCapture() }
        sysInput?.markAsFinished()
        if let writer { await writer.finishWriting() }
        log("⏹  录音结束，混音中…")
        return try alignAndMix(log: log)
    }

    /// 录到按 Enter 或 maxSeconds，返回混音 + 分轨（CLI 用）。
    public func record(maxSeconds: Double?, log: (String) -> Void = { print($0) }) async throws -> Capture {
        try await startCapture(log: log)
        log("🔴 会议录音中（麦克风 + 对方音）…  按 Enter 停止" +
            (maxSeconds.map { String(format: "（或 %.0fs 自动停止）", $0) } ?? ""))
        await waitForStop(maxSeconds: maxSeconds)
        return try await finishCapture(log: log)
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
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            sysStartHost = CMTimeGetSeconds(pts)   // SCStream PTS 在 host clock 上，与 AVAudioTime.hostTime 同轴
            sessionStarted = true
        }
        if sysInput.isReadyForMoreMediaData { sysInput.append(sampleBuffer) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // 捕获意外停止：留给 stop 流程收尾
    }

    // MARK: 麦克风（AVAudioEngine → AVAudioFile）

    private func startMic(log: (String) -> Void) throws {
        // ⚠️ 不要在这里开 `setVoiceProcessingEnabled(true)`（AEC/VPIO）——2026-07-02 实测它会把输入格式
        // 变成怪异大格式（2.5h→11GB）且**麦克风输出纯静音**（两条录音佐证），静默毁掉整场会议录音。
        // 回声（线上声被麦克风二次收）改由「分轨分别转录」在文本层去重解决（见 TranscriptMerge），不动采集。
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        do {
            self.micFile = try AVAudioFile(forWriting: micURL, settings: fmt.settings)
        } catch { throw MeetingRecorderError.startFailed("麦克风文件创建失败：\(error.localizedDescription)") }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buf, when in
            guard let self else { return }
            if self.micStartHost == nil, when.isHostTimeValid {
                self.micStartHost = AVAudioTime.seconds(forHostTime: when.hostTime)
            }
            try? self.micFile?.write(from: buf)   // 原生格式写盘（与验证过能用的老行为一致）；降采样在结束时流式做
        }
        do { try engine.start() }
        catch { throw MeetingRecorderError.startFailed("AVAudioEngine 启动失败：\(error.localizedDescription)") }
        log("  🎙  麦克风捕获已启动")
    }

    // MARK: 对齐 + 混音（流式：边读边重采样到 16k、按起点对齐、混音写出，绝不整读进内存）

    private func alignAndMix(log: (String) -> Void) throws -> Capture {
        // 流式混音（见 StreamingMix）——修复旧版把整条 mic（曾达 11GB）读进 [Float] 撑爆内存卡死整机的雷。
        let uid = UUID().uuidString
        let r = try StreamingMix.mixTo16k(mic: micURL, sys: sysURL,
                                          micStartHost: micStartHost, sysStartHost: sysStartHost,
                                          uid: uid, log: log)
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: sysURL)
        return Capture(mixed: r.mixed, mic: r.mic, sys: r.sys)
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
