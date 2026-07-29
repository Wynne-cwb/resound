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
        /// 停录后的收尾：停设备 + 对齐混音落盘（秒级）。**转写不在这里**——它排进
        /// LibraryModel 的转写队列在后台跑，所以收尾一完成就回 idle，可以马上录下一场。
        case finishing

        var isMeetingDetected: Bool { if case .meetingDetected = self { return true }; return false }
    }

    @Published var phase: Phase = .idle
    @Published var watching = false
    @Published var recSeconds = 0
    @Published var meetingTitle: String? // 检测到的会议名（取自 Chrome 标签标题），用作录音标题
    @Published var promptStop = false     // 会议结束、未开自动停录时：弹「停止录音？」一键弹窗（录音仍在继续）

    /// toast 走 AppModel（全局），录音引擎只负责发消息。
    weak var app: AppModel?
    /// 录完后把「转写+入库」以及随后的「说话人识别+摘要」都交给 Library 的后台队列（与导入同一路径）。
    weak var library: LibraryModel?

    static let finishingLabel = "正在收尾录音（对齐混音）…"

    private var watchTask: Task<Void, Never>?
    private var recorder: MeetingRecorder?
    private var recordingFromMeeting = false   // 当前录音是否由会议触发（决定会议结束时是否自动停）
    private var recTimer: Timer?
    private var recStart = Date()

    var isRecording: Bool { phase == .recording }
    var isFinishing: Bool { phase == .finishing }
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
                        // 只在录音中/收尾中（秒级）忽略新会议；转写已挪到后台队列，不再挡下一场。
                        if self.phase == .recording || self.phase == .finishing { return }
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
        // 重入保护：录音中/收尾中再开一场会覆盖 `recorder`，把正在录的那场连引擎带音频一起丢掉。
        // （UI 三个入口都各有门禁，但这里是唯一的必经之路，护栏放这最稳。）
        guard phase == .idle || phase.isMeetingDetected else {
            app?.toast("已在录音中"); return
        }
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

    /// 停录：只做「停设备 + 对齐混音落盘」（秒级），随后把转写+入库**排进后台队列**并立刻回 idle。
    /// 这样一场会刚录完就能马上录下一场——转写（20min 会 ≈ 8min）在后台排着跑，不再堵住录音。
    func stopAndIngest() {
        promptStop = false   // 停止弹窗若在显示则收起
        guard let rec = recorder else { phase = .idle; return }
        stopRecTimer()
        phase = .finishing
        let title = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            // 录音收尾（对齐混音+分轨落盘）。这一步失败=没有音频可救，只能报错。
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
            await MainActor.run {
                // 转写+入库+说话人识别+摘要全交后台队列（与导入同一路径，队列内部管并发上限）。
                // 音频由 enqueueRecording 搬出 tmp，失败也留在录音库顶部可重试/取回，绝不丢。
                guard let lib = self.library else {
                    AppLog.log("⚠️ library 未挂载，录音临时文件：\(cap.mixed.path)")
                    self.app?.toast("无法加入录音库，音频保留在：\(cap.mixed.path)")
                    self.phase = .idle; self.recorder = nil; self.meetingTitle = nil
                    return
                }
                lib.enqueueRecording(mixed: cap.mixed, mic: cap.mic, sys: cap.sys, title: title)
                self.app?.toast("录音已结束，正在后台转写（可以开始下一场了）")
                self.phase = .idle; self.recorder = nil; self.meetingTitle = nil
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
