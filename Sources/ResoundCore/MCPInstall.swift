import Foundation

/// 把 Resound MCP 服务器一键装到编码助手。v1 只支持 Claude Code / Codex
/// （两者有官方 `... mcp add` CLI；Cursor 无 CLI、靠写 ~/.cursor/mcp.json，本期不做）。
public enum MCPClientKind: String, CaseIterable, Sendable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
    /// 该助手的命令行可执行名（检测 + 增删 MCP 用）。
    public var cli: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }
}

public enum MCPInstall {
    /// 注册到助手时用的 server 名。
    public static let serverName = "resound"

    /// 当前 `resound` 可执行文件的绝对路径（安装命令要把它写进助手配置）。
    /// CLI 下即自身路径；App（Wave 3）应传入随包分发的 CLI 路径覆盖。
    public static func resoundExecutablePath() -> String {
        // CommandLine.arguments[0] 在 CLI 启动时是调用路径；解析成绝对路径。
        let arg0 = CommandLine.arguments.first ?? "resound"
        if arg0.hasPrefix("/") { return arg0 }
        let cwd = FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: cwd).appendingPathComponent(arg0).standardizedFileURL.path
    }

    /// App 场景下解析 `resound` CLI 的路径：①随包分发（`Resound.app/Contents/MacOS/resound`）；
    /// ②PATH 上的 `resound`（`which`）。都找不到返回 nil → UI 退化到只展示手动命令。
    public static func appResoundPath(bundleMacOSDir: URL?) -> String? {
        if let dir = bundleMacOSDir {
            // 随包分发的 CLI 叫 resound-cli（不能叫 resound——大小写不敏感会撞 App 主可执行 Resound）。
            let bundled = dir.appendingPathComponent("resound-cli")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        }
        let (code, out) = runShell("command -v resound")
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return code == 0 && !path.isEmpty ? path : nil
    }

    /// 安装命令（也用于「手动命令」兜底展示）。
    public static func installCommand(_ kind: MCPClientKind, resoundPath: String) -> String {
        "\(kind.cli) mcp add \(serverName) -- \(shellQuote(resoundPath)) mcp serve"
    }

    public static func removeCommand(_ kind: MCPClientKind) -> String {
        "\(kind.cli) mcp remove \(serverName)"
    }

    /// 检测助手 CLI 是否在 PATH 上（`which <cli>`）。
    public static func isClientDetected(_ kind: MCPClientKind) -> Bool {
        let (code, _) = runShell("command -v \(kind.cli)")
        return code == 0
    }

    /// 该助手是否已注册 resound MCP（`<cli> mcp get resound` 退出码 0）。
    public static func isServerInstalled(_ kind: MCPClientKind) -> Bool {
        let (code, _) = runShell("\(kind.cli) mcp get \(serverName)")
        return code == 0
    }

    /// 执行安装；失败抛出（含 CLI 输出）。
    public static func install(_ kind: MCPClientKind, resoundPath: String? = nil) throws {
        let path = resoundPath ?? resoundExecutablePath()
        let (code, out) = runShell(installCommand(kind, resoundPath: path))
        if code != 0 { throw MCPInstallError.commandFailed(out) }
    }

    public static func uninstall(_ kind: MCPClientKind) throws {
        let (code, out) = runShell(removeCommand(kind))
        if code != 0 { throw MCPInstallError.commandFailed(out) }
    }
}

public enum MCPInstallError: Error, CustomStringConvertible {
    case commandFailed(String)
    public var description: String {
        switch self { case .commandFailed(let s): return "安装命令失败：\(s)" }
    }
}

public func shellQuote(_ s: String) -> String {
    s.contains(" ") || s.contains("\"") ? "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\"" : s
}

/// 经登录 shell 跑一条命令，回 (退出码, 合并输出)。用登录 shell 以拿到用户 PATH（nvm/homebrew 等）。
@discardableResult
func runShell(_ command: String) -> (code: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", command]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (127, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}
