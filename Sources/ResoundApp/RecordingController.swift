import Foundation
import SwiftUI
import ResoundCore

/// App 的录音/会议检测中枢：后台监听 Google Meet → 弹窗 → 录音 → 停止后转录入库。
@MainActor
final class RecordingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case meetingDetected(url: String)
        case recording
        case processing
    }

    @Published var phase: Phase = .idle
    @Published var watching = false
    @Published var recSeconds = 0
    @Published var procStep = 0          // 0 转写 · 1 建立索引（说话人识别录完后由 Library 后台 worker 补）
    @Published var meetingTitle: String? // 检测到的会议名（取自 Chrome 标签标题），用作录音标题

    /// toast 走 AppModel（全局），录音引擎只负责发消息。
    weak var app: AppModel?
    /// 录完后把"说话人识别+摘要"交给 Library 的后台串行 worker（与导入同一路径），不阻塞收尾。
    weak var library: LibraryModel?

    static let procLabels = ["正在转写音频…", "正在加入录音库…"]

    private var watchTask: Task<Void, Never>?
    private var recorder: MeetingRecorder?
    private var recTimer: Timer?
    private var recStart = Date()

    var isRecording: Bool { phase == .recording }
    var isProcessing: Bool { phase == .processing }
    var isIdle: Bool { phase == .idle }

    // MARK: 监听 Meet

    func startWatching() {
        guard watchTask == nil else { return }
        watching = true
        let watcher = MeetWatcher()
        watchTask = Task {
            await watcher.watch(intervalSec: 5, requireMic: true) { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    switch event {
                    case .started(let url, let title, _):
                        if self.phase == .recording || self.phase == .processing { return }
                        self.meetingTitle = title
                        self.phase = .meetingDetected(url: url)
                    case .ended:
                        if case .meetingDetected = self.phase { self.phase = .idle; self.meetingTitle = nil }
                    }
                }
            }
        }
    }

    func stopWatching() { watchTask?.cancel(); watchTask = nil; watching = false }

    func ignorePrompt() { if case .meetingDetected = phase { phase = .idle; meetingTitle = nil } }

    /// 菜单栏「模拟检测到会议」。
    func simulateMeeting() {
        guard phase == .idle else { return }
        meetingTitle = "团队周会（模拟）"
        phase = .meetingDetected(url: "https://meet.google.com/demo-resound")
    }

    // MARK: 录音

    func startRecording() {
        let rec = MeetingRecorder()
        recorder = rec
        phase = .recording
        recSeconds = 0
        recStart = Date()
        startRecTimer()
        Task {
            do {
                try await rec.startCapture { _ in }
            } catch {
                await MainActor.run {
                    self.phase = .idle
                    self.stopRecTimer()
                    self.app?.toast("录音启动失败：\(error)")
                    self.recorder = nil
                }
            }
        }
    }

    func stopAndIngest() {
        guard let rec = recorder else { phase = .idle; return }
        stopRecTimer()
        phase = .processing
        procStep = 0
        Task {
            do {
                let url = try await rec.finishCapture { _ in }
                let cfg = try Config.load()
                guard let vault = cfg.vaultPath, !vault.isEmpty else {
                    await MainActor.run {
                        self.app?.toast("未设置 VAULT_PATH（在设置里配 vault 路径后才能入库）")
                        self.phase = .idle; self.recorder = nil
                    }
                    return
                }
                // 转写 + 入库
                let title = self.meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let out = try await IngestPipeline(vaultRoot: URL(fileURLWithPath: vault))
                    .ingest(audioPath: url, title: (title?.isEmpty == false) ? title : nil, source: "meeting", tags: [],
                            model: "large-v3", language: "zh", hints: [], push: false)
                let pipeline = IndexPipeline(config: cfg)
                await MainActor.run { self.procStep = 1 }
                // labelSpeakers:false——说话人交给后台 worker 的 diarization（会覆盖 chunk 说话人），此处不重复标注
                try await pipeline.indexRecording(recDir: out.recordingDir, indexPath: defaultIndexPath(), labelSpeakers: false)
                if cfg.vaultAutoPush {   // 开了自动推送：把文本派生物同步到 vault 远端（音频已 gitignore）
                    _ = try? Git(repo: URL(fileURLWithPath: vault)).syncTextOnly(message: "rec: 会议录音 \(out.id)")
                }
                // 转写+入库完成即收尾；说话人识别(慢)+摘要交后台串行 worker，录音库里该条显示「识别说话人中…」
                let sum = loadRecordingSummary(dir: out.recordingDir)
                await MainActor.run {
                    self.app?.toast("录音已转写并加入录音库")
                    self.app?.reloadLibrary()
                    if let sum { self.library?.enqueueSpeakerID(sum) }
                    self.phase = .idle; self.recorder = nil; self.meetingTitle = nil
                }
            } catch {
                await MainActor.run {
                    self.app?.toast("处理失败：\(error)"); self.phase = .idle; self.recorder = nil; self.meetingTitle = nil
                }
            }
        }
    }

    // MARK: 录音计时

    private func startRecTimer() {
        stopRecTimer()
        recTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                self.recSeconds = Int(Date().timeIntervalSince(self.recStart))
            }
        }
    }
    private func stopRecTimer() { recTimer?.invalidate(); recTimer = nil }
}
