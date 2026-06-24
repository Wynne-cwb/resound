import Foundation
import QuartzCore
import ResoundCore

/// 轻量性能埋点（仅主线程使用）。数据写进 `resound.log`（AppLog），便于事后排查卡顿。
///
/// 三类信号：
/// 1. **主线程卡顿看门狗**：一个本应每 ~16ms 触发的定时器，实际间隔超阈值即说明主线程被阻塞（掉帧）。
///    直接量化「卡了多久」，并打上时间戳——用户做某操作卡了，日志里就有对应的卡顿条目。
/// 2. **body 重算计数**：各视图 body 里调 `Perf.body("X")`，每秒汇总「谁重算了多少次」，揪出狂重渲染者。
/// 3. **关键块耗时**：`Perf.measure("X") { ... }` 统计次数/均值/峰值。
///
/// 全部在主线程访问（视图 body + 主 runloop 定时器），单线程无需加锁。排查完把 `enabled` 置 false 即停。
enum Perf {
    static var enabled = false   // 排查完已关闭：置 true 即重新开启卡顿看门狗 + body 计数 → resound.log

    private static var counts: [String: Int] = [:]
    private static var durMax: [String: Double] = [:]
    private static var durSum: [String: Double] = [:]
    private static var durN: [String: Int] = [:]

    private static var started = false
    private static var lastTick = CACurrentMediaTime()
    private static var hangCount = 0
    private static var hangTotal = 0.0
    private static var worstHang = 0.0
    private static var flushTimer: Timer?
    private static var watchTimer: Timer?

    static func start() {
        guard enabled, !started else { return }
        started = true
        lastTick = CACurrentMediaTime()
        // 看门狗：理想每 16ms 触发；实际间隔 = 主线程上一段被占用的时长。>100ms 记一次明显卡顿。
        let w = Timer(timeInterval: 0.016, repeats: true) { _ in
            let now = CACurrentMediaTime()
            let gap = now - lastTick
            lastTick = now
            if gap > 0.10 { hangCount += 1; hangTotal += gap; worstHang = max(worstHang, gap) }
        }
        RunLoop.main.add(w, forMode: .common)   // .common：滚动/动画期间也照常触发
        watchTimer = w
        let f = Timer(timeInterval: 1.0, repeats: true) { _ in flush() }
        RunLoop.main.add(f, forMode: .common)
        flushTimer = f
        AppLog.log("⏱️ Perf 监控已开启（每秒汇总；只在有活动时打印）")
    }

    static func body(_ label: String) {
        guard enabled else { return }
        counts[label, default: 0] += 1
    }

    @discardableResult
    static func measure<T>(_ label: String, _ block: () -> T) -> T {
        guard enabled else { return block() }
        let t = CACurrentMediaTime()
        let r = block()
        let ms = (CACurrentMediaTime() - t) * 1000
        durMax[label] = max(durMax[label] ?? 0, ms)
        durSum[label, default: 0] += ms
        durN[label, default: 0] += 1
        return r
    }

    private static func flush() {
        guard enabled else { return }
        if counts.isEmpty && hangCount == 0 && durN.isEmpty { return }   // 静默期不刷屏
        var parts: [String] = []
        if hangCount > 0 {
            parts.append(String(format: "🔴卡顿×%d 共%.0fms 最长%.0fms", hangCount, hangTotal * 1000, worstHang * 1000))
        }
        if !counts.isEmpty {
            let top = counts.sorted { $0.value > $1.value }.map { "\($0.key)=\($0.value)" }
            parts.append("body: " + top.joined(separator: " "))
        }
        if !durN.isEmpty {
            let durs = durN.keys.sorted().map { k -> String in
                let n = durN[k] ?? 1
                return String(format: "%@(n%d 均%.1f 峰%.1fms)", k, n, (durSum[k] ?? 0) / Double(n), durMax[k] ?? 0)
            }
            parts.append("耗时: " + durs.joined(separator: " "))
        }
        AppLog.log("⏱️ " + parts.joined(separator: " | "))
        counts.removeAll(); durMax.removeAll(); durSum.removeAll(); durN.removeAll()
        hangCount = 0; hangTotal = 0; worstHang = 0
    }
}
