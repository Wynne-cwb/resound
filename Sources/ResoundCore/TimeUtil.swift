import Foundation

/// 把 ISO8601（带时区）转成本地 `yyyy-MM-dd`，给 chunk 的 recording_date 用（按本地日历归日）。
public func localDate(fromISO iso: String) -> String? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    guard let d = f.date(from: iso) else { return nil }
    return localDate(d)
}

/// 本地 `yyyy-MM-dd`。
public func localDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = .current
    return f.string(from: date)
}

/// 本地星期几（中文），给 summary / 查询规划当时间锚点用。
public func weekdayZh(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "EEEE"
    f.timeZone = .current
    return f.string(from: date)
}

public func weekdayZh(fromISO iso: String) -> String? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    guard let d = f.date(from: iso) else { return nil }
    return weekdayZh(d)
}
