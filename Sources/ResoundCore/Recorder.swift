import Foundation
import AVFoundation

public enum RecorderError: Error, CustomStringConvertible {
    case permissionDenied
    case startFailed(String)
    public var description: String {
        switch self {
        case .permissionDenied:
            return "麦克风权限被拒绝。从终端首次运行时，系统会请求把麦克风权限授予你的终端 App，请允许后重试。"
        case .startFailed(let m):
            return "录音启动失败：\(m)"
        }
    }
}

/// 麦克风录音 → m4a 文件。最小实现：录到按 Enter 或到达 maxSeconds。
public final class Recorder: NSObject, @unchecked Sendable {
    private var recorder: AVAudioRecorder?

    public override init() { super.init() }

    public func requestPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// 录音到临时 m4a 文件，返回该文件 URL。
    public func record(maxSeconds: Double?, log: (String) -> Void = { print($0) }) async throws -> URL {
        guard await requestPermission() else { throw RecorderError.permissionDenied }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("resound-rec-\(UUID().uuidString).m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let rec = try AVAudioRecorder(url: tmp, settings: settings)
            rec.prepareToRecord()
            guard rec.record() else { throw RecorderError.startFailed("record() 返回 false") }
            self.recorder = rec
        } catch {
            throw RecorderError.startFailed(error.localizedDescription)
        }

        log("🔴 录音中…  按 Enter 停止" + (maxSeconds.map { String(format: "（或 %.0fs 后自动停止）", $0) } ?? ""))

        await waitForStop(maxSeconds: maxSeconds)

        recorder?.stop()
        recorder = nil
        log("⏹  录音结束")
        return tmp
    }

    private func waitForStop(maxSeconds: Double?) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let done = DispatchSemaphore(value: 0)
            var resumed = false
            let resumeOnce = {
                if !resumed { resumed = true; cont.resume() }
            }

            // Enter 停止
            DispatchQueue.global().async {
                _ = readLine()
                done.signal()
            }
            // 超时停止
            DispatchQueue.global().async {
                if let max = maxSeconds {
                    _ = done.wait(timeout: .now() + max)
                } else {
                    done.wait()
                }
                resumeOnce()
            }
        }
    }
}
