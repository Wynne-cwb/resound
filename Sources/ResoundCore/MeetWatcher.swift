import Foundation
import AppKit
import CoreAudio
import ScriptingBridge

/// 系统默认浏览器（会议检测的目标）。团队成员不都用 Chrome，检测跟着默认浏览器走。
/// Chromium 系（Chrome/Edge/Brave/Vivaldi/Arc）与 Safari 的 AppleScript 方言略有差异；
/// Firefox 等不开放 AppleScript 读标签 → `.unsupported`（会议检测不可用，手动录音不受影响）。
public struct DefaultBrowser: Sendable {
    public enum Kind: Sendable { case chromium, safari, unsupported }
    public let bundleID: String
    public let name: String      // 展示名（权限卡/设置页用）
    public let kind: Kind

    /// 以「https 链接默认由谁打开」为准；探测不到时回退 Chrome（老行为）。
    public static func detect() -> DefaultBrowser {
        let fallback = DefaultBrowser(bundleID: "com.google.Chrome", name: "Google Chrome", kind: .chromium)
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://meet.google.com")!),
              let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier else { return fallback }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let lower = id.lowercased()
        let chromiumPrefixes = ["com.google.chrome", "com.microsoft.edgemac", "com.brave.browser",
                                "com.vivaldi.vivaldi", "org.chromium.chromium",
                                "company.thebrowser.browser",   // Arc
                                "company.thebrowser.dia"]       // Dia（2026-11-01 实测支持 Chrome AppleScript 方言）
        if chromiumPrefixes.contains(where: { lower.hasPrefix($0) }) {
            return DefaultBrowser(bundleID: id, name: name, kind: .chromium)
        }
        if lower == "com.apple.safari" {
            return DefaultBrowser(bundleID: id, name: name, kind: .safari)
        }
        return DefaultBrowser(bundleID: id, name: name, kind: .unsupported)
    }
}

/// Google Meet 检测：轮询默认浏览器标签 URL(找会议室链接) + 麦克风占用确认在通话。
/// 不需浏览器扩展，只需自动化权限(首次弹 TCC：Resound 想控制 <浏览器>)。
/// Tabs are read via ScriptingBridge, per browser instance by pid (see `browserTabs()`).
public final class MeetWatcher: @unchecked Sendable {

    public enum Event {
        case started(url: String, title: String?, micActive: Bool)
        case ended
    }

    public let browser: DefaultBrowser

    public init(browser: DefaultBrowser = .detect()) { self.browser = browser }

    // MARK: 浏览器标签轮询（ScriptingBridge / Apple Events）

    /// 返回当前打开的某个 Meet 会议室的 (URL, 会议名)。会议名取自浏览器标签标题
    /// (日历预订的会议标题通常会出现在标签页标题里)；无会议/浏览器不支持返回 nil。
    public func browserMeeting() -> (url: String, title: String?)? {
        guard browser.kind != .unsupported else { return nil }
        return Self.firstMeeting(in: browserTabs())
    }

    /// Picks the first meeting-room tab from a list of (URL, title) pairs.
    static func firstMeeting(in tabs: [(url: String, title: String)]) -> (url: String, title: String?)? {
        guard let hit = tabs.first(where: { isMeetingRoom($0.url) }) else { return nil }
        return (hit.url, cleanMeetingTitle(hit.title))
    }

    /// All tabs (URL, title) across **every running instance** of the default browser.
    ///
    /// Do not use AppleScript `tell application id "<bundle id>"`: several instances can share one
    /// bundle id (e.g. a scraper/automation Chrome started with `--user-data-dir`), and `application id`
    /// resolves to only one of them (observed: the most recently launched, with zero windows). The
    /// Chrome actually hosting the meeting is never asked, so the whole meeting goes undetected
    /// silently. ScriptingBridge addresses each instance by pid instead, and only targets processes
    /// that are already running, so it never launches the browser.
    func browserTabs() -> [(url: String, title: String)] {
        // Safari calls the tab title property `name`; Chromium browsers call it `title`.
        let titleKey = browser.kind == .safari ? "name" : "title"
        var out: [(url: String, title: String)] = []
        for instance in NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID)
        where !instance.isTerminated {
            guard let app = SBApplication(processIdentifier: instance.processIdentifier) else { continue }
            app.timeout = 300   // ticks (1/60s) = 5s; a hung instance must not stall the poll loop
            // Guard every KVC hop with responds(to:): a key missing from the browser's scripting
            // dictionary raises an ObjC exception that Swift cannot catch (would crash the app).
            guard app.responds(to: NSSelectorFromString("windows")),
                  let windows = app.value(forKey: "windows") as? SBElementArray else { continue }
            for case let window as SBObject in windows {
                guard window.responds(to: NSSelectorFromString("tabs")),
                      let tabs = window.value(forKey: "tabs") as? SBElementArray,
                      let first = tabs.firstObject as? SBObject,
                      first.responds(to: NSSelectorFromString("URL")),
                      first.responds(to: NSSelectorFromString(titleKey)) else { continue }
                // Bulk getters: one Apple event per property per window instead of one per tab.
                // URL/title can be missing value (about:blank etc.) → NSNull → empty string.
                let urls = (tabs.value(forKey: "URL") as? [Any]) ?? []
                let titles = (tabs.value(forKey: titleKey) as? [Any]) ?? []
                for (i, u) in urls.enumerated() {
                    let title = i < titles.count ? (titles[i] as? String ?? "") : ""
                    out.append((u as? String ?? "", title))
                }
            }
        }
        return out
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

    /// 会议室 URL 模式：meet.google.com/[可选路径段/]三-四-三 小写字母（排除落地页 meet.google.com/、/landing 等）。
    /// Google 会给会议码前加路径段，如 meet.google.com/meet/qzq-ityb-ztv，必须容忍，否则整场会静默检测不到。
    static func isMeetingRoom(_ url: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "meet\\.google\\.com/(?:[A-Za-z0-9_-]+/)*[a-z]{3}-[a-z]{4}-[a-z]{3}(?![a-z])") else { return false }
        return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    /// 从会议室 URL 取会议码（`abc-defg-hij`）；非会议室 URL 返回 nil。
    public static func meetingCode(from url: String) -> String? {
        isMeetingRoom(url) ? CalendarText.meetCode(in: url) : nil
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
    /// - endConfirmations: 连续多少次「非会议」才判定为结束（防抖）。浏览器标签轮询偶发读不到 /
    ///   麦克风瞬时释放会误判结束——自动停录依赖 `.ended`，误触发会把录音中途掐掉，故需连续确认。
    public func watch(intervalSec: Double = 4, requireMic: Bool = true, endConfirmations: Int = 1,
                      onEvent: @escaping (Event) -> Void) async {
        var inMeeting = false
        var inactiveStreak = 0
        while !Task.isCancelled {
            let meeting = browserMeeting()
            let active = (meeting != nil) && (!requireMic || micInUse())
            if active {
                inactiveStreak = 0
                if !inMeeting {
                    inMeeting = true
                    onEvent(.started(url: meeting!.url, title: meeting!.title, micActive: micInUse()))
                }
            } else if inMeeting {
                inactiveStreak += 1
                if inactiveStreak >= max(1, endConfirmations) {
                    inMeeting = false; inactiveStreak = 0
                    onEvent(.ended)
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(intervalSec * 1_000_000_000))
        }
    }
}
