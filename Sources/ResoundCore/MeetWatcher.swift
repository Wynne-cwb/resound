import Foundation
import CoreAudio

/// Google Meet 检测：轮询 Chrome 标签 URL(找会议室链接) + 麦克风占用确认在通话。
/// 不需 Chrome 扩展，只需自动化权限(首次弹 TCC：Resound 想控制 Google Chrome)。
public final class MeetWatcher: @unchecked Sendable {

    public enum Event {
        case started(url: String, title: String?, micActive: Bool)
        case ended
    }

    public init() {}

    // MARK: Chrome 标签轮询（AppleScript / Apple Events）

    /// 返回当前打开的某个 Meet 会议室的 (URL, 会议名)。会议名取自 Chrome 标签标题
    /// (日历预订的会议标题通常会出现在标签页标题里)；无会议返回 nil。
    public func chromeMeeting() -> (url: String, title: String?)? {
        // 每个标签输出 "URL\t标题"，用换行分隔。
        let script = """
        if application "Google Chrome" is running then
            set out to ""
            tell application "Google Chrome"
                repeat with w in windows
                    repeat with t in tabs of w
                        set out to out & (URL of t) & "\t" & (title of t) & "\n"
                    end repeat
                end repeat
            end tell
            return out
        else
            return ""
        end if
        """
        guard let raw = runAppleScript(script) else { return nil }
        for line in raw.split(whereSeparator: \.isNewline) {
            let parts = line.components(separatedBy: "\t")
            let u = parts.first ?? ""
            if Self.isMeetingRoom(u) {
                let title = parts.count > 1 ? Self.cleanMeetingTitle(parts[1]) : nil
                return (u, title)
            }
        }
        return nil
    }

    /// 标签标题清洗成会议名：去掉「Google Meet」装饰、未读数前缀；只剩 "Meet"/空 → nil。
    static func cleanMeetingTitle(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespaces)
        // 去掉未读数前缀，如 "(3) "
        if let r = t.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        for suffix in [" - Google Meet", " – Google Meet", " | Google Meet", " - Meet", " – Meet"] {
            if t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        }
        for prefix in ["Meet - ", "Meet – ", "Google Meet - ", "Google Meet – "] {
            if t.hasPrefix(prefix) { t = String(t.dropFirst(prefix.count)) }
        }
        t = t.trimmingCharacters(in: .whitespaces)
        return (t.isEmpty || t == "Meet" || t == "Google Meet") ? nil : t
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
            let meeting = chromeMeeting()
            let active = (meeting != nil) && (!requireMic || micInUse())
            if active, !inMeeting {
                inMeeting = true
                onEvent(.started(url: meeting!.url, title: meeting!.title, micActive: micInUse()))
            } else if !active, inMeeting {
                inMeeting = false
                onEvent(.ended)
            }
            try? await Task.sleep(nanoseconds: UInt64(intervalSec * 1_000_000_000))
        }
    }
}
