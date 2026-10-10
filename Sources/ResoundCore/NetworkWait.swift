import Foundation
import Network

/// Tells "this Mac is offline" apart from "the service failed", and suspends until the network returns.
///
/// Why: when every MOSS failure fell back to whisper, a dropped network did too. On 2026-10-08 the
/// Platform weekly meeting went offline → MOSS failed → whisper dual-track fallback → 3218 tiny
/// segments → 81 proofreading batches + 141 contextual-enrichment calls. Worse quality and an LLM
/// call spike for what is a transient condition that should simply be waited out.
public enum NetworkWait {
    /// URLError codes meaning "cannot reach the network / host", as opposed to an HTTP error the
    /// server returned. `.timedOut` counts too: upload/poll timeouts are almost always link problems,
    /// while a genuinely failing server answers with a status code.
    static let connectivityCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
        .callIsActive, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut,
        .secureConnectionFailed,
    ]

    public static func isConnectivityError(_ error: Error) -> Bool {
        if let u = error as? URLError { return connectivityCodes.contains(u.code) }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && connectivityCodes.contains(URLError.Code(rawValue: ns.code))
    }

    /// One-shot check of the system network path.
    public static func isOnline() async -> Bool {
        for await status in pathStatuses() { return status == .satisfied }
        return false
    }

    /// Suspends until the system network path is satisfied; throws CancellationError if the task is cancelled.
    public static func waitUntilOnline() async throws {
        for await status in pathStatuses() where status == .satisfied { return }
        try Task.checkCancellation()
    }

    private static func pathStatuses() -> AsyncStream<NWPath.Status> {
        AsyncStream { cont in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { cont.yield($0.status) }
            cont.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "resound.network-wait"))
        }
    }
}

/// Retry policy for connectivity failures (shared by MOSS submit and poll).
///
/// - System path **offline**: wait indefinitely for the network; does not count as a retry
///   (no outage length justifies switching transcription backends).
/// - System path **online** but the host is unreachable (DNS / connect / timeout): exponential backoff
///   15s → 2min, and after `onlineRetryLimit` attempts rethrow the original error. That usually means a
///   broken link or a dead endpoint; callers treat it as a connectivity failure (no whisper fallback).
struct ConnectivityPatience {
    static let onlineRetryLimit = 12   // backoff caps at 2min → gives up after roughly 20 minutes
    let what: String
    let log: (String) -> Void
    let onNetworkWait: ((Bool) -> Void)?
    private var onlineFailures = 0

    init(what: String, log: @escaping (String) -> Void, onNetworkWait: ((Bool) -> Void)?) {
        self.what = what; self.log = log; self.onNetworkWait = onNetworkWait
    }

    /// Absorbs one connectivity error: waits for the network or backs off, then returns the seconds
    /// spent waiting (so callers can extend their deadline). Rethrows once the online retry budget is spent.
    mutating func absorb(_ error: Error) async throws -> TimeInterval {
        let t0 = Date()
        if await NetworkWait.isOnline() {
            onlineFailures += 1
            guard onlineFailures <= Self.onlineRetryLimit else { throw error }
            let delay = min(15 * pow(2, Double(onlineFailures - 1)), 120)
            let reason = (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? "\(error)"
            log(String(format: "   ⚠️ %@连不上（%@），%.0fs 后重试（%d/%d）",
                       what, reason, delay, onlineFailures, Self.onlineRetryLimit))
            try await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        } else {
            log("   📴 网络已断开，\(what)暂停，等待网络恢复…")
            AppLog.log("📴 网络断开，\(what)暂停等待网络恢复（不回退 Whisper）")
            onNetworkWait?(true)
            defer { onNetworkWait?(false) }
            try await NetworkWait.waitUntilOnline()
            onlineFailures = 0
            log("   📶 网络已恢复，继续\(what)")
            AppLog.log("📶 网络恢复，继续\(what)")
        }
        return Date().timeIntervalSince(t0)
    }
}
