import XCTest
@testable import ResoundCore

/// P2：日程参会人作说话人命名的参考。不在邀请名单的人要过更高的门（不是直接排除），
/// margin 仍在全库算；声纹库的英文名与参会人格式对不上的，从历史会议学别名。
final class AttendeeGateTests: XCTestCase {

    private func unit(_ v: [Float]) -> [Float] { var x = v; l2normalize(&x); return x }

    private func matcher() -> SpeakerMatcher {
        let m = SpeakerMatchPolicy.matcher()
        m.setRefs([SpeakerRef(name: "Jerry", centroid: unit([1, 0, 0]), count: 5),
                   SpeakerRef(name: "Samuel", centroid: unit([0, 1, 0]), count: 5)])
        return m
    }

    func testOutsiderNeedsHigherScore() {
        let m = matcher()
        m.attendees = ["Jerry"]
        m.outsiderTauAbs = SpeakerMatchPolicy.outsiderTauAbs
        // cos ≈ 0.75 to Samuel: passes the normal 0.70/0.10 gate, but Samuel was not invited.
        let probe = unit([0.1, 0.75, 0.65])
        let r = m.match(probe)
        XCTAssertNil(r.name)
        XCTAssertTrue(r.rejectedAsOutsider)
        // Same probe without calendar data: named as before (behaviour unchanged when not linked).
        XCTAssertEqual(matcher().match(probe).name, "Samuel")
        // Strong evidence still names an uninvited person.
        XCTAssertEqual(m.match(unit([0.05, 0.95, 0.3])).name, "Samuel")
    }

    func testAttendeeKeepsNormalGate() {
        let m = matcher()
        m.attendees = ["Jerry"]
        m.outsiderTauAbs = SpeakerMatchPolicy.outsiderTauAbs
        let r = m.match(unit([0.75, 0.1, 0.65]))
        XCTAssertEqual(r.name, "Jerry")
    }

    func testUninvitedRunnerUpDoesNotBlockInvitedTop() {
        // Real case (Team Sprite 07-31): owner at cos 0.78, an uninvited lookalike 0.75 → margin 0.03 kept it anonymous.
        let m = SpeakerMatchPolicy.matcher()
        m.setRefs([SpeakerRef(name: "Wynne", centroid: unit([1, 0, 0]), count: 5),
                   SpeakerRef(name: "Leeyo", centroid: unit([0.8, 0.6, 0]), count: 5)])
        let probe = unit([0.78, 0.193, 0.595])   // cos 0.78 to Wynne, 0.74 to Leeyo
        XCTAssertNil(m.match(probe).name)                       // no calendar: ambiguous as before
        m.attendees = ["Wynne"]
        m.outsiderTauAbs = SpeakerMatchPolicy.outsiderTauAbs
        m.tieBreakMinScore = SpeakerMatchPolicy.attendanceTieBreakMin
        let r = m.match(probe)
        XCTAssertEqual(r.name, "Wynne")
        XCTAssertTrue(r.resolvedByAttendance)
        // Below the tie-break floor the invite list is not enough on its own.
        m.tieBreakMinScore = 0.80
        XCTAssertNil(m.match(probe).name)
        m.tieBreakMinScore = SpeakerMatchPolicy.attendanceTieBreakMin
        // Both invited: the normal margin still applies.
        m.attendees = ["Wynne", "Leeyo"]
        XCTAssertNil(m.match(probe).name)
    }

    private func event(_ people: [CalendarEvent.Person]) -> CalendarEvent {
        CalendarEvent(id: "e", seriesId: nil, title: "t", start: Date(), end: Date(), calendar: "c", meetCode: nil,
                      organizer: nil, attendees: people, description: "", links: [])
    }

    func testAttendingUsesNameShapesAndAliases() {
        let e = event([.init(name: "Jie Cong Yang, Jerry", email: "jerry@x.com"),
                       .init(name: "", email: "yx.xie@x.com"),
                       .init(name: "Wen Fei Qiao, Ggbond", email: "wf@x.com")])
        XCTAssertEqual(CalendarAttendance.attending(["Jerry", "GGBond", "Tao", "Ben"], event: e, aliases: [:]),
                       ["Jerry", "GGBond"])
        XCTAssertEqual(CalendarAttendance.attending(["Jerry", "Tao"], event: e, aliases: ["yx.xie@x.com": "Tao"]),
                       ["Jerry", "Tao"])
    }

    func testLearnAliasFromOneOnOne() throws {
        let vault = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: vault) }
        func rec(_ id: String, speakers: [String], people: [CalendarEvent.Person]) throws {
            let dir = vault.appendingPathComponent("recordings/2026/10/\(id)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let m = RecordingManifest(id: id, title: id, recordedAt: "2026-10-21T15:21:00+08:00", durationSec: 600,
                                      source: "meeting", language: "zh", tags: [], audioFile: "audio.m4a", asrModel: "m")
            try m.yaml().write(to: dir.appendingPathComponent("recording.yaml"), atomically: true, encoding: .utf8)
            let segs = speakers.enumerated().map { SpeakerSeg(start: Double($0.offset), end: Double($0.offset) + 1, speaker: $0.element) }
            try JSONEncoder().encode(segs).write(to: dir.appendingPathComponent("diarization.json"))
            try CalendarLinker.save(CalendarRecord(match: "time", linkedAt: "x", event: event(people)), dir: dir)
        }
        let wynne = CalendarEvent.Person(name: "Wei Bin Chen, Wynne", email: "wb.chen@x.com")
        // 1 on 1: Wynne fits by name, so the lone pair Tao ↔ yx.xie is learned.
        try rec("2026-10-21-1521-a", speakers: ["Wynne", "Tao"], people: [wynne, .init(name: "", email: "yx.xie@x.com")])
        // Big meeting with several unmatched attendees: no vote.
        try rec("2026-10-22-1000-b", speakers: ["Wynne", "Samuel"],
                people: [wynne, .init(name: "", email: "a@x.com"), .init(name: "", email: "b@x.com")])
        // Conflicting votes for one attendee are dropped.
        try rec("2026-10-23-1000-c", speakers: ["Wynne", "Mason"], people: [wynne, .init(name: "", email: "m@x.com")])
        try rec("2026-10-24-1000-d", speakers: ["Wynne", "Jane"], people: [wynne, .init(name: "", email: "m@x.com")])

        let aliases = CalendarAttendance.learnAliases(vaultRoot: vault)
        XCTAssertEqual(aliases, ["yx.xie@x.com": "Tao"])

        let dir = vault.appendingPathComponent("recordings/2026/10/2026-10-21-1521-a")
        XCTAssertEqual(CalendarAttendance.vaultRoot(of: dir)?.standardizedFileURL.path, vault.standardizedFileURL.path)
        XCTAssertEqual(CalendarAttendance.attendingRefs(dir: dir, refNames: ["Wynne", "Tao", "Jerry"]), ["Wynne", "Tao"])
    }

    func testMeetingBlockForSummary() {
        let rec = CalendarRecord(match: "exact", linkedAt: "x", event: CalendarEvent(
            id: "e", seriesId: "s", title: "Team Sprite Weekly Meeting", start: Date(), end: Date(), calendar: "c",
            meetCode: nil, organizer: .init(name: "Jerry", email: "j@x.com"),
            attendees: [.init(name: "Jie Cong Yang, Jerry", email: "j@x.com")], description: "议程：迭代复盘", links: []))
        let b = buildMeetingBlock(rec)
        XCTAssertTrue(b.contains("Team Sprite Weekly Meeting"))
        XCTAssertTrue(b.contains("重复会议"))
        XCTAssertTrue(b.contains("议程：迭代复盘"))
        XCTAssertFalse(b.contains("j@x.com"))   // no emails in the LLM prompt
    }
}
