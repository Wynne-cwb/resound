import Foundation
import Logging
import MCP

/// Wave 4：本地 stdio 自定义来源的传输层。
/// swift-sdk 自带的 `StdioTransport` 读写**本进程**的 stdin/stdout（用于「我作为 server」）；
/// 这里反过来——**作为 client** 去连一个本地子进程（如 `npx -y @notionhq/notion-mcp-server`）：
/// 起子进程 → 写它的 stdin、读它的 stdout，换行分隔 JSON-RPC（同 stdio 规范）。
public actor StdioProcessTransport: Transport {
    public nonisolated let logger: Logger

    private let command: String
    private let arguments: [String]
    private let environment: [String: String]

    private var process: Process?
    private var stdinPipe: Pipe?
    private var isConnected = false

    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var pendingData = Data()

    public init(command: String, arguments: [String] = [], environment: [String: String] = [:],
                logger: Logger? = nil) {
        self.command = command
        self.arguments = arguments
        self.environment = environment
        self.logger = logger ?? Logger(label: "mcp.transport.stdio-process",
                                        factory: { _ in SwiftLogNoOpLogHandler() })
        var cont: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        self.messageStream = AsyncThrowingStream { cont = $0 }
        self.messageContinuation = cont
    }

    public func connect() async throws {
        guard !isConnected else { return }

        let p = Process()
        // 经登录 shell 解析命令，拿到用户 PATH（nvm/homebrew 装的 npx 等）。
        let full = ([command] + arguments).map { shellQuote($0) }.joined(separator: " ")
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", full]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe

        // stdout：按换行切出完整 JSON-RPC 消息喂给 stream。
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            if chunk.isEmpty {                       // EOF
                handle.readabilityHandler = nil
                Task { await self.finishStream() }
                return
            }
            Task { await self.ingest(chunk) }
        }
        // stderr：丢给 logger，避免子进程报错时管道塞满阻塞。
        errPipe.fileHandleForReading.readabilityHandler = { [logger] handle in
            let d = handle.availableData
            if !d.isEmpty, let s = String(data: d, encoding: .utf8) {
                logger.debug("stderr", metadata: ["msg": "\(s.trimmingCharacters(in: .whitespacesAndNewlines))"])
            }
        }

        do { try p.run() } catch {
            throw MCPError.transportError(error)
        }
        self.process = p
        self.stdinPipe = inPipe
        self.isConnected = true
        logger.debug("subprocess MCP transport connected: \(full)")
    }

    private func ingest(_ chunk: Data) {
        pendingData.append(chunk)
        while let nl = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
            let msg = pendingData[..<nl]
            pendingData = pendingData[(nl + 1)...]
            if !msg.isEmpty { messageContinuation.yield(Data(msg)) }
        }
    }

    private func finishStream() { messageContinuation.finish() }

    public func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        process?.terminate()
        process = nil
        stdinPipe = nil
        messageContinuation.finish()
        logger.debug("subprocess MCP transport disconnected")
    }

    public func send(_ data: Data) async throws {
        guard isConnected, let handle = stdinPipe?.fileHandleForWriting else {
            throw MCPError.internalError("stdio subprocess not connected")
        }
        var d = data
        d.append(UInt8(ascii: "\n"))
        do { try handle.write(contentsOf: d) }
        catch { throw MCPError.transportError(error) }
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> { messageStream }
}
