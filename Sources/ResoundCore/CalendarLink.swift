import Foundation
import EventKit

/// 录音 ↔ 日历日程关联（2026-11-03，见 docs/superpowers/specs/2026-11-03-calendar-link-design.md）。
/// 日程从 macOS 系统日历（EventKit）读：公司 Google 账号同步到系统日历即可，不走 Google API。
/// 匹配逻辑（CalendarMatcher）与 EventKit 解耦，纯函数可单测；落盘为录音目录内的 calendar.json。

// MARK: - 模型

/// 一个日程的快照（与 EventKit 解耦）。参会人已滤掉会议室/资源。
public struct CalendarEvent: Codable, Equatable {
    public struct Person: Codable, Equatable {
        public let name: String
        public let email: String
        public let status: String?
        public init(name: String, email: String, status: String? = nil) {
            self.name = name; self.email = email; self.status = status
        }
    }
    /// 本次发生的唯一 id：`<externalId>@<开始时间>`（重复会议各次 externalId 相同）。
    public let id: String
    /// 重复会议的系列 id（= externalId）；单次会议为 nil。
    public let seriesId: String?
    public let title: String
    public let start: Date
    public let end: Date
    public let calendar: String
    public let meetCode: String?
    public let organizer: Person?
    public let attendees: [Person]
    /// 去掉 Google 自动生成的入会说明后的描述。
    public let description: String
    /// 描述里除 Meet/电话入会之外的链接（去重，保序）。
    public let links: [String]

    public init(id: String, seriesId: String?, title: String, start: Date, end: Date, calendar: String,
                meetCode: String?, organizer: Person?, attendees: [Person], description: String, links: [String]) {
        self.id = id; self.seriesId = seriesId; self.title = title; self.start = start; self.end = end
        self.calendar = calendar; self.meetCode = meetCode; self.organizer = organizer
        self.attendees = attendees; self.description = description; self.links = links
    }

    enum CodingKeys: String, CodingKey {
        case id, seriesId = "series_id", title, start, end, calendar, meetCode = "meet_code"
        case organizer, attendees, description, links
    }
}

/// calendar.json（schema resound.calendar/1）。
public struct CalendarRecord: Codable, Equatable {
    public var schema = "resound.calendar/1"
    /// exact（会议码）/ time（时间+标题兜底）/ manual（CLI --pick）。
    public let match: String
    public let linkedAt: String
    public let event: CalendarEvent

    public init(match: String, linkedAt: String, event: CalendarEvent) {
        self.match = match; self.linkedAt = linkedAt; self.event = event
    }

    enum CodingKeys: String, CodingKey { case schema, match, linkedAt = "linked_at", event }
}

// MARK: - 匹配（纯逻辑）

public enum CalendarMatch: Equatable {
    case linked(CalendarEvent, method: String)
    /// 有候选但分不清：不自动关联，交给用户（CLI --pick）。
    case ambiguous([CalendarEvent])
    case none
}

public enum CalendarMatcher {
    /// 录音区间 [start, end]（会议录音的 recorded_at 是停录时刻，调用方负责倒推 start）。
    /// speakers：录音里已命名的说话人（无则空）。只在时间兜底里用作证据：背靠背的临时 1 on 1
    /// 常常大半落在隔壁日程里，单看时间会挂错（2026-11-03 真实数据 2 例）。
    public static func match(events: [CalendarEvent], meetCode: String?, start: Date, end: Date,
                             title: String, altTitles: [String] = [], speakers: [String] = []) -> CalendarMatch {
        func overlap(_ e: CalendarEvent) -> TimeInterval {
            max(0, min(end, e.end).timeIntervalSince(max(start, e.start)))
        }
        // 1. Exact: same Meet code. Recurring series share the code, so pick the occurrence closest in time.
        if let code = meetCode?.lowercased(), !code.isEmpty {
            let same = events.filter { $0.meetCode?.lowercased() == code }
            if let best = same.min(by: { a, b in
                let (oa, ob) = (overlap(a), overlap(b))
                if oa != ob { return oa > ob }
                return abs(a.start.timeIntervalSince(start)) < abs(b.start.timeIntervalSince(start))
            }) {
                return .linked(best, method: "exact")
            }
        }
        // 2. Time fallback.
        let recDur = max(1, end.timeIntervalSince(start))
        let cands = events.filter { overlap($0) > 0 }
            .sorted { overlap($0) > overlap($1) }
        guard !cands.isEmpty else { return .none }
        // Speaker evidence counts only with ≥2 named speakers (the owner alone attends everything).
        let named = speakers.count >= 2
        func allAttend(_ e: CalendarEvent) -> Bool {
            let keys = attendeeKeys(e)
            return speakers.allSatisfy { keys.contains(nameKey($0)) || keys.contains(nameKey(firstToken($0))) }
        }
        /// Among events every named speaker attends, the smallest invite list wins (a 1:1 over a big sync).
        func smallestFitting(_ es: [CalendarEvent]) -> CalendarEvent? {
            let fit = es.filter(allAttend).sorted { $0.attendees.count < $1.attendees.count }
            guard let first = fit.first else { return nil }
            return fit.count == 1 || fit[1].attendees.count > first.attendees.count ? first : nil
        }

        let titles = [title] + altTitles
        let titled = cands.filter { e in titles.contains { titleSimilarity(e.title, $0) >= 0.8 } }
        if titled.count == 1 { return .linked(titled[0], method: "time") }
        if titled.count > 1 {
            if named, let e = smallestFitting(titled) { return .linked(e, method: "time") }
            return .ambiguous(titled)
        }
        let covering = cands.filter { overlap($0) / recDur >= 0.5 }
        if named, let e = smallestFitting(covering) { return .linked(e, method: "time") }
        let others = cands.filter { overlap($0) / recDur >= 0.25 }
        if covering.count == 1, others.count == 1 {
            let e = covering[0]
            let eventCoverage = overlap(e) / max(1, e.end.timeIntervalSince(e.start))
            // Without names, also require the recording to fill half the slot; with names that don't fit, refuse.
            if !named, eventCoverage >= 0.5 { return .linked(e, method: "time") }
            return .ambiguous([e])
        }
        return .ambiguous(Array(cands.prefix(5)))
    }

    /// 参会人名字的可比键：逗号各段（「Jie Cong Yang, Jerry」「Mason, Mai」）、各段首词（「Bryce Zhang」）、邮箱前缀首段。
    static func attendeeKeys(_ e: CalendarEvent) -> Set<String> {
        (e.attendees + [e.organizer].compactMap { $0 }).reduce(into: Set<String>()) { $0.formUnion(personKeys($1)) }
    }

    static func personKeys(_ p: CalendarEvent.Person) -> Set<String> {
        var k = Set<String>()
        for part in p.name.split(separator: ",") {
            k.insert(nameKey(String(part)))
            k.insert(nameKey(firstToken(String(part))))
        }
        if let local = p.email.split(separator: "@").first?.split(whereSeparator: { $0 == "." || $0 == "_" }).first {
            k.insert(nameKey(String(local)))
        }
        k.remove("")
        return k
    }

    /// 说话人名是否能对上这位参会人（名字键匹配；别名另算，见 CalendarAttendance）。
    static func nameFits(_ speaker: String, _ p: CalendarEvent.Person) -> Bool {
        let k = personKeys(p)
        return k.contains(nameKey(speaker)) || k.contains(nameKey(firstToken(speaker)))
    }

    static func nameKey(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    static func firstToken(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "")
    }

    /// 标题相似度：归一化（小写、只留字母数字与中日韩字符）后的字符 bigram Dice 系数，0…1。
    public static func titleSimilarity(_ a: String, _ b: String) -> Double {
        func norm(_ s: String) -> [Character] {
            Array(s.lowercased().filter { $0.isLetter || $0.isNumber })
        }
        let (x, y) = (norm(a), norm(b))
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if x == y { return 1 }
        guard x.count >= 2, y.count >= 2 else { return 0 }
        var bx: [String: Int] = [:]
        for i in 0..<(x.count - 1) { bx[String(x[i...i + 1]), default: 0] += 1 }
        var inter = 0
        for i in 0..<(y.count - 1) {
            let k = String(y[i...i + 1])
            if let n = bx[k], n > 0 { bx[k] = n - 1; inter += 1 }
        }
        return 2 * Double(inter) / Double(x.count - 1 + y.count - 1)
    }
}

// MARK: - 描述清洗 / 会议码

public enum CalendarText {
    /// 从任意文本里取 Meet 会议码（`meet.google.com/[路径/]xxx-xxxx-xxx`）。
    public static func meetCode(in text: String) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: "meet\\.google\\.com/(?:[A-Za-z0-9_-]+/)*([a-z]{3}-[a-z]{4}-[a-z]{3})(?![a-z])"),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// 清洗日程描述：去 HTML 标签、去 Google 自动生成的入会说明块；同时提取链接。
    public static func clean(_ raw: String) -> (text: String, links: [String]) {
        var s = raw
        var links: [String] = []
        // HTML descriptions: keep href targets before stripping tags.
        if let re = try? NSRegularExpression(pattern: "href=\"([^\"]+)\"", options: .caseInsensitive) {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(m.range(at: 1), in: s) { links.append(String(s[r])) }
            }
        }
        s = s.replacingOccurrences(of: "<br\\s*/?>|</p>|</div>|</li>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (k, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        // Google's generated "Join with Google Meet …" block sits between two -::~:~::~…::~:~::- fence lines
        // (a single fence line also matches a naive regex, so fences are found line by line).
        var kept: [String] = []
        var inBlock = false
        for line in s.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("-::~"), t.hasSuffix("::-") { inBlock.toggle(); continue }
            if !inBlock { kept.append(line) }
        }
        s = kept.joined(separator: "\n")
        if let re = try? NSRegularExpression(pattern: "https?://[^\\s<>\"'）)\\]]+") {
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(m.range, in: s) { links.append(String(s[r])) }
            }
        }
        let dropHosts = ["meet.google.com", "tel.meet", "support.google.com", "g.co", "calendar.google.com"]
        var seen = Set<String>()
        let useful = links.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:")) }.filter { url in
            guard let host = URL(string: url)?.host?.lowercased() else { return false }
            if dropHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return false }
            return seen.insert(url).inserted
        }
        let text = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, useful)
    }

    /// 参会人是否是会议室/设备资源（Google 资源日历的邮箱）。
    static func isResourceEmail(_ email: String) -> Bool {
        email.lowercased().hasSuffix("resource.calendar.google.com")
    }
}

// MARK: - EventKit

/// 系统日历读取。首次调用 `requestAccess` 时 macOS 弹授权（需要 Info.plist 的
/// NSCalendarsFullAccessUsageDescription；终端里跑的 CLI 通常拿不到授权）。
public final class SystemCalendar {
    private let store = EKEventStore()

    public init() {}

    public static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    public func requestAccess() async -> Bool {
        if Self.isAuthorized { return true }
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func events(from: Date, to: Date) -> [CalendarEvent] {
        let pred = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: pred).filter { !$0.isAllDay }.map(Self.snapshot)
    }

    static func snapshot(_ e: EKEvent) -> CalendarEvent {
        func person(_ p: EKParticipant) -> CalendarEvent.Person {
            let email = p.url.scheme?.lowercased() == "mailto"
                ? p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive) : ""
            let status: String? = {
                switch p.participantStatus {
                case .accepted: return "accepted"
                case .declined: return "declined"
                case .tentative: return "tentative"
                case .pending: return "pending"
                default: return nil
                }
            }()
            return CalendarEvent.Person(name: p.name ?? "", email: email, status: status)
        }
        let attendees = (e.attendees ?? [])
            .filter { $0.participantType != .room && $0.participantType != .resource }
            .map(person)
            .filter { !CalendarText.isResourceEmail($0.email) }
        let notes = e.notes ?? ""
        let blob = [notes, e.location ?? "", e.url?.absoluteString ?? ""].joined(separator: "\n")
        let cleaned = CalendarText.clean(notes)
        let ext = e.calendarItemExternalIdentifier ?? e.calendarItemIdentifier
        return CalendarEvent(
            id: "\(ext)@\(iso8601(e.startDate))",
            seriesId: e.hasRecurrenceRules ? ext : nil,
            title: e.title ?? "",
            start: e.startDate, end: e.endDate,
            calendar: e.calendar?.title ?? "",
            meetCode: CalendarText.meetCode(in: blob),
            organizer: e.organizer.map(person),
            attendees: attendees,
            description: cleaned.text,
            links: cleaned.links)
    }
}

// MARK: - 关联（读写 vault）

public enum CalendarLinker {
    public static let fileName = "calendar.json"

    public static func load(dir: URL) -> CalendarRecord? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? decoder().decode(CalendarRecord.self, from: data)
    }

    public static func save(_ rec: CalendarRecord, dir: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .custom { d, c in var s = c.singleValueContainer(); try s.encode(iso8601(d)) }
        try enc.encode(rec).write(to: dir.appendingPathComponent(fileName), options: .atomic)
    }

    static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        dec.dateDecodingStrategy = .custom { c in
            let s = try c.singleValueContainer().decode(String.self)
            guard let d = f.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: try c.singleValueContainer(), debugDescription: "bad date \(s)")
            }
            return d
        }
        return dec
    }

    /// 写/改 recording.yaml 顶层的 `meet_code:` 行（插在 provenance 块之前；已有则替换）。
    public static func setMeetCode(_ code: String, dir: URL) throws {
        let url = dir.appendingPathComponent("recording.yaml")
        var lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let line = "meet_code: \(yamlQuote(code))"
        if let i = lines.firstIndex(where: { $0.hasPrefix("meet_code:") }) {
            lines[i] = line
        } else if let i = lines.firstIndex(where: { $0.hasPrefix("audio_file:") }) {
            lines.insert(line, at: i + 1)
        } else if let i = lines.firstIndex(where: { $0.hasPrefix("provenance:") }) {
            lines.insert(line, at: i)
        } else {
            lines.append(line)
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 标题是否还是入库时的默认名（录音混音文件名 `<时间戳>-resound-meeting-<UUID>`）：是才允许用日程标题替换。
    public static func isDefaultTitle(_ title: String) -> Bool {
        title.range(of: "resound-meeting-[0-9A-Fa-f]{8}-", options: .regularExpression) != nil
    }

    /// 录音区间：会议录音的 recorded_at 是停录时刻（混音文件修改时间），开始 = recorded_at − 时长。
    /// 例外：「按标题改日期」会把 recorded_at 改成当天正午（`T12:00:00`，真实时刻丢失）——这时改用
    /// 录音 id 前缀里的入库时刻 `YYYY-MM-DD-HHMM`（≈ 停录时刻），日期对不上就返回 nil（时间未知，不做时间匹配）。
    public static func interval(recordedAt: String, durationSec: Int, id: String) -> (start: Date, end: Date)? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard var end = f.date(from: recordedAt) else { return nil }
        if recordedAt.contains("T12:00:00") {
            guard let stamp = idStamp(id), localDate(stamp) == localDate(end) else { return nil }
            end = stamp
        }
        return (end.addingTimeInterval(-Double(max(durationSec, 1))), end)
    }

    /// 录音 id 前缀 `YYYY-MM-DD-HHMM` → 本地时间。
    static func idStamp(_ id: String) -> Date? {
        guard id.range(of: "^\\d{4}-\\d{2}-\\d{2}-\\d{4}", options: .regularExpression) != nil else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.date(from: String(id.prefix(15)))
    }

    /// 录音 id 去掉时间戳前缀后的部分：会议录音 id 取自开录时的浏览器标签标题（即日程原名），
    /// 用户后来改了显示标题也还在——匹配时当第二个标题用。默认名（resound-meeting-UUID）不算。
    static func slugTitle(_ id: String) -> String? {
        guard id.count > 16, idStamp(id) != nil else { return nil }
        let slug = String(id.dropFirst(16))
        return slug.contains("resound-meeting-") ? nil : slug
    }

    /// diarization.json 里已命名的说话人（去掉「说话人N」、MOSS 的 S01 / P1_S01 等匿名标签）。
    static func namedSpeakers(dir: URL) -> [String] {
        let names = Set((loadDiarization(dir) ?? []).map(\.speaker))
        return names.filter { $0.range(of: "^(说话人\\d+|(P\\d+_)?S\\d+|SPEAKER_\\d+)$", options: .regularExpression) == nil }
            .sorted()
    }

    public struct Resolution {
        public let recordingId: String
        public let title: String
        public let start: Date
        public let end: Date
        public let meetCode: String?
        public let match: CalendarMatch
    }

    /// 为一条录音找日程（不落盘）。只处理 source=meeting。
    public static func resolve(dir: URL, calendar: SystemCalendar, meetCode: String? = nil) -> Resolution? {
        guard let m = try? parseManifest(dir.appendingPathComponent("recording.yaml")), m.source == "meeting",
              let iv = interval(recordedAt: m.recordedAt, durationSec: m.durationSec, id: m.id) else { return nil }
        let code = meetCode ?? m.meetCode
        // ±24h for the code lookup (recorded_at may be off when it came from a title date); time fallback
        // only looks at events overlapping the recording.
        let events = calendar.events(from: iv.start.addingTimeInterval(-86_400), to: iv.end.addingTimeInterval(86_400))
        let match = CalendarMatcher.match(events: events, meetCode: code, start: iv.start, end: iv.end, title: m.title,
                                          altTitles: slugTitle(m.id).map { [$0] } ?? [],
                                          speakers: namedSpeakers(dir: dir))
        return Resolution(recordingId: m.id, title: m.title, start: iv.start, end: iv.end, meetCode: code, match: match)
    }

    /// 落盘：calendar.json + meet_code；标题仍是默认名时改成日程标题。返回是否改了标题。
    @discardableResult
    public static func apply(_ event: CalendarEvent, method: String, dir: URL, meetCode: String?) throws -> Bool {
        try save(CalendarRecord(match: method, linkedAt: iso8601(Date()), event: event), dir: dir)
        if let code = meetCode ?? event.meetCode { try setMeetCode(code, dir: dir) }
        guard let sum = loadRecordingSummary(dir: dir), isDefaultTitle(sum.title),
              !event.title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        try renameRecording(sum, to: event.title)
        return true
    }

    /// 新录音入库后调用：有授权才查（不在这里弹授权，避免入库流程被授权弹窗卡住——授权由 App 启动/设置页申请）。
    /// 歧义/无匹配只写 meet_code。任何失败都吞掉：关联是附加信息，不能影响入库。
    @discardableResult
    public static func linkNewRecording(dir: URL, meetCode: String?) -> CalendarMatch {
        if let code = meetCode { try? setMeetCode(code, dir: dir) }
        guard SystemCalendar.isAuthorized, let r = resolve(dir: dir, calendar: SystemCalendar(), meetCode: meetCode) else {
            return .none
        }
        if case .linked(let e, let method) = r.match { _ = try? apply(e, method: method, dir: dir, meetCode: meetCode) }
        return r.match
    }
}

// MARK: - 历史回填（CLI calendar-link 与 App 设置页共用）

public struct CalendarBackfillReport {
    public var linked = 0, ambiguous = 0, unmatched = 0, skipped = 0, retitled = 0
    public init() {}
}

extension CalendarLinker {
    /// 对 vault 里的会议录音逐条找日程：明确的落盘，有歧义/无匹配的只报告。已有 calendar.json 的跳过（force 重做）。
    public static func backfill(vaultRoot: URL, calendar: SystemCalendar, onlyId: String? = nil,
                                dryRun: Bool, force: Bool = false,
                                log: (String) -> Void = { print($0) }) -> CalendarBackfillReport {
        var rep = CalendarBackfillReport()
        let tf = DateFormatter(); tf.dateFormat = "MM-dd HH:mm"
        let hf = DateFormatter(); hf.dateFormat = "HH:mm"
        for rec in listRecordings(vaultRoot: vaultRoot) where onlyId == nil || rec.id == onlyId {
            if !force, load(dir: rec.dir) != nil { rep.skipped += 1; continue }
            guard let r = resolve(dir: rec.dir, calendar: calendar) else {
                if (try? parseManifest(rec.dir.appendingPathComponent("recording.yaml")))?.source == "meeting" {
                    rep.unmatched += 1
                    log("– 「\(rec.title)」录音时刻未知（被按标题改过日期），跳过")
                }
                continue   // not a meeting recording
            }
            let head = "\(tf.string(from: r.start))–\(hf.string(from: r.end)) 「\(r.title)」"
            switch r.match {
            case .linked(let e, let method):
                rep.linked += 1
                log("✓ [\(method)] \(head) → 「\(e.title)」\(hf.string(from: e.start))–\(hf.string(from: e.end))，参会 \(e.attendees.count) 人")
                if !dryRun, (try? apply(e, method: method, dir: rec.dir, meetCode: r.meetCode)) == true { rep.retitled += 1 }
            case .ambiguous(let cands):
                rep.ambiguous += 1
                log("? \(head) 有 \(cands.count) 个候选，未关联（用 --id \(rec.id) --pick N 指定）：")
                for (i, e) in cands.enumerated() {
                    log("    \(i + 1). 「\(e.title)」\(hf.string(from: e.start))–\(hf.string(from: e.end))")
                }
            case .none:
                rep.unmatched += 1
                log("– \(head) 没有对应日程")
            }
        }
        return rep
    }
}

// MARK: - 参会人 ↔ 声纹库里的名字（P2：说话人命名的参会人门）

/// 声纹库里的名字只取英文名（Jerry/Tao/GGBond），日程参会人却是「全名, 英文名」、「英文名 姓」或纯邮箱。
/// 名字键对不上的（Tao ↔ yx.xie@…）从已关联且已命名的历史会议里学别名：一场会里恰好只剩一个
/// 说话人和一位参会人对不上，就记一票；同一参会人只要出现过两个不同的名字就作废（宁缺毋滥）。
public enum CalendarAttendance {
    /// 参会人身份键：有邮箱用邮箱，否则用名字键。
    static func identity(_ p: CalendarEvent.Person) -> String {
        p.email.isEmpty ? "name:" + CalendarMatcher.nameKey(p.name) : p.email.lowercased()
    }

    /// 从 vault 里已关联日程、已命名说话人的会议学「参会人身份 → 说话人名」。
    public static func learnAliases(vaultRoot: URL) -> [String: String] {
        var votes: [String: Set<String>] = [:]
        for rec in listRecordings(vaultRoot: vaultRoot) {
            guard let cal = CalendarLinker.load(dir: rec.dir) else { continue }
            let speakers = CalendarLinker.namedSpeakers(dir: rec.dir)
            guard speakers.count >= 2 else { continue }
            let people = cal.event.attendees
            let loneSpeakers = speakers.filter { s in !people.contains { CalendarMatcher.nameFits(s, $0) } }
            let loneAttendees = people.filter { p in !speakers.contains { CalendarMatcher.nameFits($0, p) } }
            if loneSpeakers.count == 1, loneAttendees.count == 1 {
                votes[identity(loneAttendees[0]), default: []].insert(loneSpeakers[0])
            }
        }
        return votes.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    /// names 里哪些人在这个日程的邀请名单上（名字键或学到的别名）。
    public static func attending(_ names: [String], event: CalendarEvent, aliases: [String: String]) -> Set<String> {
        let people = event.attendees + [event.organizer].compactMap { $0 }
        let aliased = Set(people.compactMap { aliases[identity($0)] })
        return Set(names.filter { n in aliased.contains(n) || people.contains { CalendarMatcher.nameFits(n, $0) } })
    }

    /// 命名用：录音关联了日程 → 声纹库里在邀请名单上的人；没关联 → nil（不启用参会人门）。
    public static func attendingRefs(dir: URL, refNames: [String]) -> Set<String>? {
        guard let cal = CalendarLinker.load(dir: dir) else { return nil }
        let aliases = vaultRoot(of: dir).map { learnAliases(vaultRoot: $0) } ?? [:]
        return attending(refNames, event: cal.event, aliases: aliases)
    }

    /// 录音目录 `<vault>/recordings/YYYY/MM/<id>` → vault 根。
    static func vaultRoot(of dir: URL) -> URL? {
        var u = dir.standardizedFileURL
        while u.path != "/" {
            if u.lastPathComponent == "recordings" { return u.deletingLastPathComponent() }
            u = u.deletingLastPathComponent()
        }
        return nil
    }
}
