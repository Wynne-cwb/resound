import Foundation
import Network

/// 本地 loopback OAuth 回调接收器（Google 等「Desktop」OAuth：redirect 必须是 `http://127.0.0.1:<port>`，
/// 不接受自定义 scheme）。起一个一次性 HTTP 监听，捕获浏览器带回的 `code`/`error`，校验 `state`。
///
/// 用法：`start()` 拿 redirect_uri → 打开授权页 → `waitForCode(expectedState:)` 等回调 → 自动 `stop()`。
/// 非沙盒 App，NWListener 监听本机端口无需额外 entitlement。
public final class LoopbackOAuthServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "resound.oauth.loopback")
    private var listener: NWListener?
    private var startCont: CheckedContinuation<UInt16, Error>?
    private var codeCont: CheckedContinuation<String, Error>?
    private var expectedState: String?
    private var pendingResult: Result<String, Error>?   // 回调早于 waitForCode 到达时暂存
    private var didStart = false
    private var didResolve = false

    public init() {}

    /// 启动监听，返回浏览器该回跳的 redirect_uri。
    public func start() async throws -> String {
        let port = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UInt16, Error>) in
            queue.async {
                self.startCont = c
                do {
                    let params = NWParameters.tcp
                    params.allowLocalEndpointReuse = true
                    let l = try NWListener(using: params)   // 系统分配空闲端口
                    self.listener = l
                    l.stateUpdateHandler = { state in self.queue.async { self.onListenerState(state) } }
                    l.newConnectionHandler = { conn in self.queue.async { self.onConnection(conn) } }
                    l.start(queue: self.queue)
                } catch {
                    self.startCont?.resume(throwing: error); self.startCont = nil
                }
            }
        }
        return "http://127.0.0.1:\(port)/oauth2callback"
    }

    /// 等待浏览器回调里的 authorization code（校验 state）。
    public func waitForCode(expectedState: String) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            queue.async {
                self.expectedState = expectedState
                if let pending = self.pendingResult {   // 回调已先到
                    self.pendingResult = nil
                    c.resume(with: pending); self.stopLocked()
                } else {
                    self.codeCont = c
                }
            }
        }
    }

    /// 用户取消：唤醒等待并关闭监听。
    public func cancelWaiting() {
        queue.async {
            guard !self.didResolve else { return }
            self.didResolve = true
            self.codeCont?.resume(throwing: CancellationError()); self.codeCont = nil
            self.stopLocked()
        }
    }

    public func stop() { queue.async { self.stopLocked() } }

    // MARK: - 内部（均在 queue 上）

    private func onListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let p = listener?.port?.rawValue, !didStart {
                didStart = true
                startCont?.resume(returning: p); startCont = nil
            }
        case .failed(let err):
            if !didStart { didStart = true; startCont?.resume(throwing: err); startCont = nil }
            deliver(.failure(err))
        default: break
        }
    }

    private func onConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            self.queue.async {
                guard let data, let req = String(data: data, encoding: .utf8),
                      let reqLine = req.split(separator: "\r\n", maxSplits: 1).first,
                      let pathPart = reqLine.split(separator: " ").dropFirst().first,
                      let comps = URLComponents(string: "http://127.0.0.1\(pathPart)") else {
                    self.respond(conn, ok: false); return
                }
                let items = comps.queryItems ?? []
                let code = items.first { $0.name == "code" }?.value
                let err = items.first { $0.name == "error" }?.value
                let state = items.first { $0.name == "state" }?.value
                guard code != nil || err != nil else { self.respond(conn, ok: false); return }   // favicon 等无关请求
                if let st = self.expectedState, let state, state != st {   // state 不符：忽略，继续等
                    self.respond(conn, ok: false); return
                }
                self.respond(conn, ok: err == nil)
                if let err { self.deliver(.failure(MCPOAuthError.authFailed(err))) }
                else if let code { self.deliver(.success(code)) }
            }
        }
    }

    private func respond(_ conn: NWConnection, ok: Bool) {
        let msg = ok ? "授权完成 ✓ 可以关闭此页面，返回 Resound。" : "授权未完成，请返回 Resound 重试。"
        let body = "<!doctype html><html><head><meta charset=\"utf-8\"><title>Resound</title></head>" +
                   "<body style=\"font-family:-apple-system,system-ui;text-align:center;padding:80px;color:#333\">" +
                   "<h2>\(msg)</h2></body></html>"
        let bytes = Array(body.utf8)
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n\(body)"
        conn.send(content: resp.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    private func deliver(_ result: Result<String, Error>) {
        guard !didResolve else { return }
        didResolve = true
        if let c = codeCont { codeCont = nil; c.resume(with: result); stopLocked() }
        else { pendingResult = result }   // waitForCode 尚未调用，暂存
    }

    private func stopLocked() {
        listener?.cancel(); listener = nil
    }
}
