import Foundation

/// 从录音标题里尽量解析出「会议日期」。按优先级支持（日期可在标题任意位置）：
///   1) 带年：`yyyy-MM-dd` / `yyyy/MM/dd` / `yyyy.MM.dd`
///   2) 中文带年：`yyyy年M月d日(号)`
///   3) 中文无年：`M月d日(号)`
///   4) 数字无年：`MM-dd` / `M/d`（只认 - 和 / 分隔，避开 v3.2 之类小数）
/// 无年份的按「不晚于今天」推断年份（会议发生在过去）。解析失败返回 nil。
public func parseTitleDate(_ title: String, now: Date = Date()) -> Date? {
    let cal = Calendar.current
    let curYear = cal.component(.year, from: now)
    let today = cal.startOfDay(for: now)

    func make(year: Int, month: Int, day: Int) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day) else { return nil }
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day; c.hour = 12   // 正午，避开时区跨日
        guard let d = cal.date(from: c) else { return nil }
        let back = cal.dateComponents([.year, .month, .day], from: d)   // 回读校验，拒 2月30 之类
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return d
    }
    func inferYear(month: Int, day: Int) -> Date? {
        guard let thisYear = make(year: curYear, month: month, day: day) else { return nil }
        if cal.startOfDay(for: thisYear) <= today { return thisYear }   // 今天及以前 → 今年
        return make(year: curYear - 1, month: month, day: day)          // 否则属于去年
    }
    func firstMatch(_ pattern: String, _ handler: ([String]) -> Date?) -> Date? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = title as NSString
        for m in re.matches(in: title, range: NSRange(location: 0, length: ns.length)) {
            let g = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            if let d = handler(g) { return d }
        }
        return nil
    }

    if let d = firstMatch(#"(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})"#, {
        make(year: Int($0[1]) ?? 0, month: Int($0[2]) ?? 0, day: Int($0[3]) ?? 0)
    }) { return d }
    if let d = firstMatch(#"(\d{4})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]?"#, {
        make(year: Int($0[1]) ?? 0, month: Int($0[2]) ?? 0, day: Int($0[3]) ?? 0)
    }) { return d }
    if let d = firstMatch(#"(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]"#, {
        inferYear(month: Int($0[1]) ?? 0, day: Int($0[2]) ?? 0)
    }) { return d }
    // 裸 MM-dd：两侧必须是「非字母数字/下划线/连字符/点」，否则会从 UUID（如 …9e1-8c1e… → 1-8）、
    // 版本号（v3-2）等噪声里误抠出日期。这是最松的模式，边界守严一点。
    if let d = firstMatch(#"(?<![\w.-])(\d{1,2})[-/](\d{1,2})(?![\w.-])"#, {
        inferYear(month: Int($0[1]) ?? 0, day: Int($0[2]) ?? 0)
    }) { return d }
    return nil
}
