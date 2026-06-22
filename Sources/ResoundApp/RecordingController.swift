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
    @Published var toast: String = ""

    private var watchTask: Task<Void, Never>?
    private var recorder: MeetingRecorder?

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
                    case .started(let url, _):
                        // 录音/处理中就不打扰
                        if case .recording = self.phase { return }
                        if case .processing = self.phase { return }
                        self.phase = .meetingDetected(url: url)
                    case .ended:
                        if case .meetingDetected = self.phase { self.phase = .idle }
                    }
                }
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel(); watchTask = nil; watching = false
    }

    func ignorePrompt() {
        if case .meetingDetected = phase { phase = .idle }
    }

    // MARK: 录音

    func startRecording() {
        let rec = MeetingRecorder()
        recorder = rec
        phase = .recording
        toast = ""
        Task {
            do {
                try await rec.startCapture { _ in }
            } catch {
                await MainActor.run {
                    self.phase = .idle
                    self.toast = "录音启动失败：\(error)"
                    self.recorder = nil
                }
            }
        }
    }

    func stopAndIngest() {
        guard let rec = recorder else { phase = .idle; return }
        phase = .processing
        Task {
            do {
                let url = try await rec.finishCapture { _ in }
                let cfg = try Config.load()
                guard let vault = cfg.vaultPath, !vault.isEmpty else {
                    await MainActor.run {
                        self.toast = "未设置 VAULT_PATH（在 .env 配 vault 路径后才能入库）；录音临时文件：\(url.path)"
                        self.phase = .idle; self.recorder = nil
                    }
                    return
                }
                let out = try await IngestPipeline(vaultRoot: URL(fileURLWithPath: vault))
                    .ingest(audioPath: url, title: nil, source: "meeting", tags: [],
                            model: "large-v3", language: "zh", hints: [], push: false)
                await MainActor.run {
                    self.toast = "✅ 已转录入库：\(out.id)（记得 resound index 重建索引）"
                    self.phase = .idle; self.recorder = nil
                }
            } catch {
                await MainActor.run {
                    self.toast = "处理失败：\(error)"; self.phase = .idle; self.recorder = nil
                }
            }
        }
    }
}
