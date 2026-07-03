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
    @Published var promptStop = false     // 会议结束、未开自动停录时：弹「停止录音？」一键弹窗（录音仍在继续）

    /// toast 走 AppModel（全局），录音引擎只负责发消息。
    weak var app: AppModel?
    /// 录完后把"说话人识别+摘要"交给 Library 的后台串行 worker（与导入同一路径），不阻塞收尾。
    weak var library: LibraryModel?

    static let procLabels = ["正在转写音频…", "正在加入录音库…"]

    private var watchTask: Task<Void, Never>?
    private var recorder: MeetingRecorder?
    private var recordingFromMeeting = false   // 当前录音是否由会议触发（决定会议结束时是否自动停）
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
            // endConfirmations:2 → 连续两轮(~10s)都检测不到会议才判定结束，避免标签轮询/麦克风瞬时抖动误停录音。
            await watcher.watch(intervalSec: 5, requireMic: true, endConfirmations: 2) { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    switch event {
                    case .started(let url, let title, _):
                        if self.phase == .recording || self.phase == .processing { return }
                        let d = UserDefaults.standard
                        // 关了「自动检测会议」→ 既不提示也不录。
                        guard d.object(forKey: Self.autoDetectKey) as? Bool ?? true else { return }
                        self.meetingTitle = title
                        // 开了「自动开始录音」→ 直接开录(无需确认)；否则弹检测提示由用户决定。
                        if d.bool(forKey: Self.autoStartKey) {
                            self.startRecording(fromMeeting: true)
                        } else {
                            self.phase = .meetingDetected(url: url)
                        }
                    case .ended:
                        if case .meetingDetected = self.phase {
                            self.phase = .idle; self.meetingTitle = nil
                        } else if self.phase == .recording, self.recordingFromMeeting {
                            // 仅对「会议触发的录音」处理结束（手动录音不受影响）。
                            if UserDefaults.standard.bool(forKey: Self.autoStopKey) {
                                self.app?.toast("会议已结束，正在停止录音…")
                                self.stopAndIngest()   // 自动停录 + 转写入库
                            } else {
                                self.promptStop = true   // 弹「停止录音？」一键弹窗，由用户决定
                            }
                        }
                    }
                }
            }
        }
    }

    /// 会议检测相关开关键（SettingsModel 写、这里读，始终取最新值）。
    static let autoStartKey = "resound.toggle.autostart"
    static let autoDetectKey = "resound.toggle.autodetect"
    static let autoStopKey = "resound.toggle.autostop"

    /// 停止录音弹窗：确认停止（停录+转写）/ 继续录音（关掉弹窗，录音继续）。
    func confirmStopFromPrompt() { promptStop = false; stopAndIngest() }
    func dismissStopPrompt() { promptStop = false }

    func stopWatching() { watchTask?.cancel(); watchTask = nil; watching = false }

    func ignorePrompt() { if case .meetingDetected = phase { phase = .idle; meetingTitle = nil } }

    /// 菜单栏「模拟检测到会议」。
    func simulateMeeting() {
        guard phase == .idle else { return }
        meetingTitle = "团队周会（模拟）"
        phase = .meetingDetected(url: "https://meet.google.com/demo-resound")
    }

    // MARK: 录音

    /// 工具栏「录音」按钮：手动录音（与会议无关，会议结束不会自动停）。
    func startRecording() { startRecording(fromMeeting: false) }

    /// fromMeeting=true：由会议触发（弹窗确认或自动开始）→ 会议结束时自动停录。
    func startRecording(fromMeeting: Bool) {
        let rec = MeetingRecorder()
        recorder = rec
        recordingFromMeeting = fromMeeting
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
        promptStop = false   // 停止弹窗若在显示则收起
        guard let rec = recorder else { phase = .idle; return }
        stopRecTimer()
        phase = .processing
        procStep = 0
        let title = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            // ① 先把录音收尾（对齐混音+分轨落盘）。这一步失败=没有音频可救，只能报错。
            let cap: MeetingRecorder.Capture
            do {
                cap = try await rec.finishCapture { _ in }
            } catch {
                await MainActor.run {
                    AppLog.error("录音收尾(混音)失败", error)
                    self.app?.toast("录音收尾失败：\(error)")
                    self.phase = .idle; self.recorder = nil; self.meetingTitle = nil
                }
                return
            }
            // ② 转写 + 入库。任何一步失败都**不丢音频**：登记成可重试的失败项（录音库顶部），并落盘日志。
            do {
                let cfg = try Config.load()
                guard let vault = cfg.vaultPath, !vault.isEmpty else {
                    await MainActor.run {
                        AppLog.log("⚠️ 录音转写中止：未设置 VAULT_PATH（音频已保留待重试）")
                        self.library?.recordFailedRecording(url: cap.mixed, title: title,
                            error: "未设置录音库路径（去 设置 配置 vault 后，可在录音库顶部重试）")
                        self.app?.toast("未设置录音库路径，录音已保留：配置后可在录音库顶部重试")
                        self.phase = .idle; self.recorder = nil; self.meetingTitle = nil
                    }
                    return
                }
                // 分轨齐全 → 分开转录合并（dual-track spec）；缺轨 → 回退混音单转录
                let tracks: (mic: URL, sys: URL)? = { if let m = cap.mic, let s = cap.sys { return (m, s) }; return nil }()
                let out = try await IngestPipeline(vaultRoot: URL(fileURLWithPath: vault))
                    .ingest(audioPath: cap.mixed, tracks: tracks, title: (title?.isEmpty == false) ? title : nil,
                            source: "meeting", tags: [], model: "large-v3", language: "zh", hints: [], push: false)
                let pipeline = IndexPipeline(config: cfg)
                await MainActor.run { self.procStep = 1 }
                // labelSpeakers:false——说话人交给后台 worker 的 diarization（会覆盖 chunk 说话人），此处不重复标注
                try await pipeline.indexRecording(recDir: out.recordingDir, indexPath: defaultIndexPath(), labelSpeakers: false)
                if cfg.vaultAutoPush {   // 开了自动推送：把文本派生物同步到 vault 远端（音频已 gitignore）
                    _ = try? Git(repo: URL(fileURLWithPath: vault)).syncTextOnly(message: "rec: 会议录音 \(out.id)")
                }
                for u in [cap.mixed, cap.mic, cap.sys].compactMap({ $0 }) {
                    try? FileManager.default.removeItem(at: u)   // 入库成功，清掉临时混音+分轨
                }
                // 转写+入库完成即收尾；说话人识别(慢)+摘要交后台串行 worker，录音库里该条显示「识别说话人中…」
                let sum = loadRecordingSummary(dir: out.recordingDir)
                await MainActor.run {
                    self.app?.toast("录音已转写并加入录音库")
                    // 直接插入列表(内含 enqueueSpeakerID)，不只靠 reloadLibrary 的 token——见 LibraryModel.addRecorded。
                    if let sum { self.library?.addRecorded(sum) }
                    self.app?.reloadLibrary()   // 仍 bump：已挂载的 LibraryView 顺带全量刷新；幂等。
                    self.phase = .idle; self.recorder = nil; self.meetingTitle = nil
                }
            } catch {
                await MainActor.run {
                    AppLog.error("录音转写入库失败（音频已保留待重试）", error)
                    if let lib = self.library {
                        // v1：失败重试只保混音（分轨临时文件顺手清掉，避免堆积）——见 dual-track spec「失败重试路径」
                        for u in [cap.mic, cap.sys].compactMap({ $0 }) { try? FileManager.default.removeItem(at: u) }
                        lib.recordFailedRecording(url: cap.mixed, title: title, error: String(describing: error))
                        self.app?.toast("转写失败，录音已保留：可在录音库顶部重试或在 Finder 取回")
                    } else {
                        AppLog.log("⚠️ library 未挂载，录音临时文件：\(cap.mixed.path)")
                        self.app?.toast("转写失败：\(error)")
                    }
                    self.phase = .idle; self.recorder = nil; self.meetingTitle = nil
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
                // 相等守卫：整数秒没变就不发 objectWillChange。否则 0.25s 一次 @Published 写入 →
                // 观察 RecordingController 的 RootView 每秒被失效 4 次（4×/s → 1×/s）。
                let v = Int(Date().timeIntervalSince(self.recStart))
                if v != self.recSeconds { self.recSeconds = v }
            }
        }
    }
    private func stopRecTimer() { recTimer?.invalidate(); recTimer = nil }
}
