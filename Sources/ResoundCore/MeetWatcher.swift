import Foundation
import CoreAudio

/// Google Meet 检测：轮询 Chrome 标签 URL(找会议室链接) + 麦克风占用确认在通话。
/// 不需 Chrome 扩展，只需自动化权限(首次弹 TCC：Resound 想控制 Google Chrome)。
public final class MeetWatcher: @unchecked Sendable {

    public enum Event {
        case started(url: String, micActive: Bool)
        case ended
    }

    public init() {}

    // MARK: Chrome 标签轮询（AppleScript / Apple Events）

    /// 返回当前打开的某个 Meet 会议室 URL(形如 meet.google.com/abc-defg-hij)；无则 nil。
    /// 不会启动 Chrome（先判 is running）。无权限/未开 Chrome 返回 nil。
    public func chromeMeetingURL() -> String? {
        let script = """
        if application "Google Chrome" is running then
            set out to ""
            tell application "Google Chrome"
                repeat with w in windows
                    repeat with t in tabs of w
                        set out to out & (URL of t) & "\n"
                    end repeat
                end repeat
            end tell
            return out
        else
            return ""
        end if
        """
        guard let urls = runAppleScript(script) else { return nil }
        for line in urls.split(whereSeparator: \.isNewline) {
            let u = String(line)
            if Self.isMeetingRoom(u) { return u }
        }
        return nil
    }

    /// 会议室 URL 模式：meet.google.com/三-四-三 小写字母（排除落地页 meet.google.com/、/landing 等）。
    static func isMeetingRoom(_ url: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "meet\\.google\\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}") else { return false }
        return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    private func runAppleScript(_ source: String) -> String? {
        var errorDict: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&errorDict)
        if errorDict != nil { return nil }   // 无权限/Chrome 未开/脚本错 → 当作没有会议
        return result.stringValue
    }

    // MARK: 麦克风占用（CoreAudio）

    /// 默认输入设备是否正被某进程使用（在通话/录音）。
    public func micInUse() -> Bool {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
            &devAddr, 0, nil, &size, &deviceID) == noErr, deviceID != 0 else { return false }

        var running = UInt32(0)
        var rsize = UInt32(MemoryLayout<UInt32>.size)
        var runAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(deviceID, &runAddr, 0, nil, &rsize, &running) == noErr else { return false }
        return running != 0
    }

    // MARK: 轮询循环（状态机：进入会议触发一次 started，离开触发 ended）

    /// 持续轮询，进入/离开会议时回调。requireMic=true 时需"会议室 URL + 麦克风占用"才算在通话。
    /// 一直跑到 Task 被取消。
    public func watch(intervalSec: Double = 4, requireMic: Bool = true,
                      onEvent: @escaping (Event) -> Void) async {
        var inMeeting = false
        while !Task.isCancelled {
            let url = chromeMeetingURL()
            let active = (url != nil) && (!requireMic || micInUse())
            if active, !inMeeting {
                inMeeting = true
                onEvent(.started(url: url!, micActive: micInUse()))
            } else if !active, inMeeting {
                inMeeting = false
                onEvent(.ended)
            }
            try? await Task.sleep(nanoseconds: UInt64(intervalSec * 1_000_000_000))
        }
    }
}
