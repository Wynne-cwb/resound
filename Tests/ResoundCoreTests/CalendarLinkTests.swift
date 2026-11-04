import XCTest
@testable import ResoundCore

/// 录音 ↔ 日程匹配规则（CalendarMatcher）与描述清洗。用例取自 2026-11-03 对真实录音的探针结果：
/// 只按开始时刻算会把多场会配错，必须用「停录时刻 − 时长」倒推区间，有会议码时以会议码为准。
final class CalendarLinkTests: XCTestCase {

    private func d(_ hhmm: String, day: String = "2026-10-30") -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: "\(day)T\(hhmm):00+08:00")!
    }

    private func ev(_ title: String, _ s: String, _ e: String, code: String? = nil, day: String = "2026-10-30",
                    attendees: [CalendarEvent.Person] = []) -> CalendarEvent {
        CalendarEvent(id: "\(title)@\(s)", seriesId: nil, title: title, start: d(s, day: day), end: d(e, day: day),
                      calendar: "work", meetCode: code, organizer: nil, attendees: attendees, description: "", links: [])
    }

    // MARK: 会议码

    func testMeetCodeExtraction() {
        XCTAssertEqual(MeetWatcher.meetingCode(from: "https://meet.google.com/ayn-krbe-sad?authuser=0"), "ayn-krbe-sad")
        XCTAssertEqual(MeetWatcher.meetingCode(from: "https://meet.google.com/meet/qzq-ityb-ztv"), "qzq-ityb-ztv")
        XCTAssertNil(MeetWatcher.meetingCode(from: "https://meet.google.com/landing"))
        XCTAssertEqual(CalendarText.meetCode(in: "Join: https://meet.google.com/bno-ujdp-mhv\nPhone…"), "bno-ujdp-mhv")
    }

    func testExactCodeWinsOverBetterTimeOverlap() {
        // Recording overlaps the standup more, but the Meet code says it was the design review.
        let events = [ev("Notification daily standup", "10:30", "11:00", code: "wat-cjtf-itd"),
                      ev("无 plan 用户访问产品页面方案讨论", "10:30", "11:00", code: "yiq-agfq-anv")]
        let m = CalendarMatcher.match(events: events, meetCode: "yiq-agfq-anv", start: d("10:33"), end: d("10:54"),
                                      title: "随便什么标题")
        XCTAssertEqual(m, .linked(events[1], method: "exact"))
    }

    func testExactPicksOccurrenceNearestTheRecording() {
        let a = ev("Weekly", "17:15", "18:15", code: "ayn-krbe-sad", day: "2026-10-23")
        let b = ev("Weekly", "17:15", "18:15", code: "ayn-krbe-sad", day: "2026-10-30")
        let m = CalendarMatcher.match(events: [a, b], meetCode: "ayn-krbe-sad", start: d("17:15"), end: d("17:58"), title: "")
        XCTAssertEqual(m, .linked(b, method: "exact"))
    }

    // MARK: 时间兜底

    func testIntervalIsAnchoredAtStopTime() {
        // recorded_at = stop time; a 61-min recording "at 19:19" actually ran 18:18–19:19.
        let iv = CalendarLinker.interval(recordedAt: "2026-10-22T19:19:00+08:00", durationSec: 3660,
                                         id: "2026-10-22-1919-platform-department-weekly-meeting")!
        XCTAssertEqual(iv.start, d("18:18", day: "2026-10-22"))
        let weekly = ev("Platform Department Weekly Meeting", "18:00", "19:00", day: "2026-10-22")
        XCTAssertEqual(CalendarMatcher.match(events: [weekly], meetCode: nil, start: iv.start, end: iv.end,
                                             title: "Platform Department Weekly Meeting"),
                       .linked(weekly, method: "time"))
    }

    func testTitleBreaksTimeTie() {
        let review = ev("Project EU Region: 产品需求评审", "14:00", "15:00")
        let catchup = ev("Monthly catch up", "15:00", "15:30")
        let m = CalendarMatcher.match(events: [review, catchup], meetCode: nil, start: d("14:40"), end: d("15:18"),
                                      title: "Project EU Region: 产品需求评审")
        XCTAssertEqual(m, .linked(review, method: "time"))
    }

    private let wynne = CalendarEvent.Person(name: "Wei Bin Chen, Wynne", email: "wb.chen@example.com")
    private func person(_ n: String) -> CalendarEvent.Person { .init(name: n, email: "") }

    func testSingleCoveringEventLinksWhenSpeakersAttend() {
        // 1 on 1 titles differ ("月度 1 on 1 with Jerry" vs "Biweekly 1:1 meeting with Wynne").
        let oneOnOne = ev("Biweekly 1:1 meeting with Wynne", "15:30", "16:30",
                          attendees: [wynne, person("Jie Cong Yang, Jerry")])
        let m = CalendarMatcher.match(events: [oneOnOne], meetCode: nil, start: d("15:41"), end: d("16:04"),
                                      title: "2026-10-30 月度 1 on 1 会议 with Jerry", speakers: ["Jerry", "Wynne"])
        XCTAssertEqual(m, .linked(oneOnOne, method: "time"))
        // Without names, 23 min of a 60-min slot is not enough to commit.
        let bare = CalendarMatcher.match(events: [oneOnOne], meetCode: nil, start: d("15:41"), end: d("16:04"), title: "x")
        XCTAssertEqual(bare, .ambiguous([oneOnOne]))
    }

    func testBackToBackOneOnOneIsNotGluedToNeighbourSlot() {
        // Real case 07-07: the Tao 1 on 1 ran 15:21–15:32, mostly inside the Hydra slot.
        let hydra = ev("1:1 meeting with Hydra", "15:00", "15:30", attendees: [wynne, person("Hai Zhao Pan, Hydra")])
        let m = CalendarMatcher.match(events: [hydra], meetCode: nil, start: d("15:21"), end: d("15:32"),
                                      title: "2026-07-07 月度 1 on 1 会议 with Tao", speakers: ["Tao", "Wynne"])
        XCTAssertEqual(m, .ambiguous([hydra]))
    }

    func testSmallestFittingInviteWins() {
        // 1:1 and a team sync in the same slot, both with Jerry and Wynne invited: the 1:1 wins.
        let sync = ev("AI-Native Delivery: Progress & Blockers", "15:30", "16:00",
                      attendees: [wynne, person("Jie Cong Yang, Jerry"), person("Ben Yuan Yan, Ben"), person("Hydra")])
        let oneOnOne = ev("Biweekly 1:1 meeting with Wynne", "15:30", "16:00", attendees: [wynne, person("Jie Cong Yang, Jerry")])
        let m = CalendarMatcher.match(events: [sync, oneOnOne], meetCode: nil, start: d("15:30"), end: d("15:48"),
                                      title: "2026-06-26 月度 1 on 1 会议 with Jerry", speakers: ["Jerry", "Wynne"])
        XCTAssertEqual(m, .linked(oneOnOne, method: "time"))
    }

    func testAttendeeKeysCoverCommonNameShapes() {
        let e = ev("x", "10:00", "11:00", attendees: [person("Mason, Mai"), person("Bryce Zhang"),
                                                     .init(name: "", email: "christine.loh@example.com")])
        let k = CalendarMatcher.attendeeKeys(e)
        XCTAssertTrue(k.isSuperset(of: ["mason", "bryce", "christine"]))
    }

    func testRecordingBeforeNextEventDoesNotLink() {
        // Ad-hoc 1 on 1 ending right when the next slot starts must not be glued onto that slot.
        let ben = ev("1:1 meeting with Ben Yuan", "14:30", "15:00")
        let m = CalendarMatcher.match(events: [ben], meetCode: nil, start: d("14:02"), end: d("14:30"),
                                      title: "2026-10-21 月度 1 on 1 会议 with GGBond")
        XCTAssertEqual(m, .none)
    }

    func testTwoOverlappingEventsWithoutTitleEvidenceIsAmbiguous() {
        let a = ev("Platform Department Weekly Meeting", "18:00", "19:00")
        let b = ev("OS 迁移事项对齐", "17:00", "17:45")
        let m = CalendarMatcher.match(events: [a, b], meetCode: nil, start: d("17:03"), end: d("18:20"), title: "内部讨论")
        guard case .ambiguous(let c) = m else { return XCTFail("expected ambiguous, got \(m)") }
        XCTAssertEqual(Set(c.map(\.title)), Set([a.title, b.title]))
    }

    func testTitleSimilarity() {
        XCTAssertEqual(CalendarMatcher.titleSimilarity("Team Sprite Weekly Meeting", "team sprite weekly meeting"), 1)
        XCTAssertGreaterThan(CalendarMatcher.titleSimilarity("[Account x Notification] OS 迁移流程讨论",
                                                             "Account x Notification OS 迁移流程讨论"), 0.8)
        XCTAssertLessThan(CalendarMatcher.titleSimilarity("Monthly catch up", "Project EU Region: 产品需求评审"), 0.3)
    }

    // MARK: 描述清洗

    func testCleanStripsGoogleBlockAndKeepsUsefulLinks() {
        let raw = """
        议程见 <a href="https://www.notion.so/automizely/Team-Sprite-Bi-weekly-Meeting-37808bd">Notion</a><br>
        PRD: https://app.notion.com/p/automizely/EU-Region-Project-Meetings-39c9d97.
        -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
        Join with Google Meet: https://meet.google.com/ayn-krbe-sad
        Join by phone https://tel.meet/ayn-krbe-sad?pin=1
        Learn more about Meet at: https://support.google.com/a/users/answer/9282720
        -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
        """
        let (text, links) = CalendarText.clean(raw)
        XCTAssertEqual(links, ["https://www.notion.so/automizely/Team-Sprite-Bi-weekly-Meeting-37808bd",
                               "https://app.notion.com/p/automizely/EU-Region-Project-Meetings-39c9d97"])
        XCTAssertTrue(text.hasPrefix("议程见 Notion"))
        XCTAssertFalse(text.contains("Google Meet"))
        XCTAssertFalse(text.contains("<"))
    }

    func testResourceEmailsAreRooms() {
        XCTAssertTrue(CalendarText.isResourceEmail("c_188a@resource.calendar.google.com"))
        XCTAssertFalse(CalendarText.isResourceEmail("wb.chen@aftership.com"))
    }

    // MARK: vault 读写

    func testDefaultTitleDetection() {
        XCTAssertTrue(CalendarLinker.isDefaultTitle("1793347455-resound-meeting-7d72fb1b-870e-4340-a308-6382c542b7d9"))
        XCTAssertFalse(CalendarLinker.isDefaultTitle("Team Sprite Weekly Meeting"))
    }

    func testApplyWritesRecordAndMeetCodeAndRetitlesDefaultOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = RecordingManifest(id: "r1", title: "1793347455-resound-meeting-7d72fb1b-870e-4340-a308-6382c542b7d9",
                                         recordedAt: "2026-10-30T17:58:51+08:00", durationSec: 2589, source: "meeting",
                                         language: "zh", tags: [], audioFile: "audio.m4a", asrModel: "moss")
        try manifest.yaml().write(to: dir.appendingPathComponent("recording.yaml"), atomically: true, encoding: .utf8)

        let e = ev("Team Sprite Weekly Meeting", "17:15", "18:15", code: "ayn-krbe-sad",
                   attendees: [.init(name: "Jie Cong Yang, Jerry", email: "jerry@example.com", status: "accepted")])
        XCTAssertTrue(try CalendarLinker.apply(e, method: "exact", dir: dir, meetCode: nil))

        let m = try parseManifest(dir.appendingPathComponent("recording.yaml"))
        XCTAssertEqual(m.title, "Team Sprite Weekly Meeting")
        XCTAssertEqual(m.meetCode, "ayn-krbe-sad")
        XCTAssertEqual(m.recordedAt, "2026-10-30T17:58:51+08:00")   // other lines untouched
        let rec = try XCTUnwrap(CalendarLinker.load(dir: dir))
        XCTAssertEqual(rec.match, "exact")
        XCTAssertEqual(rec.event, e)

        // A user-chosen title is never overwritten; meet_code line is replaced, not duplicated.
        let other = ev("Another", "17:15", "18:15", code: "bno-ujdp-mhv")
        XCTAssertFalse(try CalendarLinker.apply(other, method: "manual", dir: dir, meetCode: nil))
        let text = try String(contentsOf: dir.appendingPathComponent("recording.yaml"), encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "meet_code:").count, 2)
        XCTAssertEqual(try parseManifest(dir.appendingPathComponent("recording.yaml")).title, "Team Sprite Weekly Meeting")
    }

    // MARK: MCP 输出

    func testMCPMeetingOmitsEmailsByDefault() {
        let rec = CalendarRecord(match: "exact", linkedAt: "x", event: ev(
            "Team Sprite Weekly Meeting", "17:15", "18:15", code: "ayn-krbe-sad",
            attendees: [.init(name: "Jie Cong Yang, Jerry", email: "jerry@example.com")]))
        let plain = MCPServerRunner.meetingJSON(rec, emails: false)
        XCTAssertEqual(plain["attendees"] as? [String], ["Jie Cong Yang, Jerry"])
        let withMail = MCPServerRunner.meetingJSON(rec, emails: true)
        XCTAssertEqual((withMail["attendees"] as? [[String: String]])?.first?["email"], "jerry@example.com")
        XCTAssertFalse(MCPServerRunner.renderMeeting(rec, emails: false).contains("jerry@example.com"))
        XCTAssertTrue(MCPServerRunner.renderMeeting(rec, emails: true).contains("<jerry@example.com>"))
        XCTAssertTrue(MCPServerRunner.attended(rec, "jerry"))
        XCTAssertFalse(MCPServerRunner.attended(rec, "pino"))
        XCTAssertFalse(MCPServerRunner.attended(nil, "jerry"))
    }

    // MARK: 被改过日期的录音 / id 里的原标题

    func testRedatedNoonFallsBackToIdStamp() {
        // Title-based redate rewrote recorded_at to noon; the id still carries the real stop time.
        let iv = CalendarLinker.interval(recordedAt: "2026-07-07T12:00:00+08:00", durationSec: 1500,
                                         id: "2026-07-07-1558-resound-meeting-1ac059e1-8c1e-458f-856c-a0245ce6904e")!
        XCTAssertEqual(iv.end, d("15:58", day: "2026-07-07"))
        // Imported later (id date differs): time is unknown, so no time matching at all.
        XCTAssertNil(CalendarLinker.interval(recordedAt: "2026-07-07T12:00:00+08:00", durationSec: 1500,
                                             id: "2026-08-01-0930-imported"))
    }

    func testIdSlugActsAsOriginalTitle() {
        XCTAssertEqual(CalendarLinker.slugTitle("2026-07-07-1532-1-1-meeting-with-yi-xuan"), "1-1-meeting-with-yi-xuan")
        XCTAssertNil(CalendarLinker.slugTitle("2026-07-07-1558-resound-meeting-1ac059e1-8c1e-458f-856c-a0245ce6904e"))
        let hydra = ev("1:1 meeting with Hydra", "15:00", "15:30", day: "2026-07-07")
        let yixuan = ev("1:1 meeting with Yi Xuan", "15:30", "16:00", day: "2026-07-07")
        let m = CalendarMatcher.match(events: [hydra, yixuan], meetCode: nil, start: d("15:21", day: "2026-07-07"),
                                      end: d("15:32", day: "2026-07-07"), title: "2026-07-07 月度 1 on 1 会议 with Tao",
                                      altTitles: ["1-1-meeting-with-yi-xuan"])
        XCTAssertEqual(m, .linked(yixuan, method: "time"))
    }
}
