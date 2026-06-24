import Foundation

/// 在 vault 目录里跑 git，把新录音同步回用户的 repo。
public struct Git {
    public let repo: URL
    public init(repo: URL) { self.repo = repo }

    @discardableResult
    public func run(_ args: [String]) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git"] + args
        proc.currentDirectoryURL = repo

        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()

        let outStr = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errStr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        if proc.terminationStatus != 0 {
            throw VaultError.ioFailure("git \(args.joined(separator: " ")) 失败：\(errStr)\(outStr)")
        }
        return outStr
    }

    /// add 指定路径 → commit → push。
    public func commitAndPush(paths: [String], message: String) throws {
        try run(["add"] + paths)
        try run(["commit", "-m", message])
        try run(["push"])
    }

    /// 是否是 git 工作区。
    public var isRepo: Bool {
        ((try? run(["rev-parse", "--is-inside-work-tree"]))?.contains("true")) ?? false
    }

    /// 确保 .gitignore 忽略音频（大文件不入 git；用户只想同步文本派生物）。
    public func ensureAudioIgnored() throws {
        let gi = repo.appendingPathComponent(".gitignore")
        var lines = (try? String(contentsOf: gi, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init) ?? []
        let needed = ["*.m4a", "*.wav", "*.mp3", "*.aiff", "*.caf"]
        let missing = needed.filter { n in !lines.contains(n) }
        guard !missing.isEmpty else { return }
        if !lines.contains("# Resound: 音频不入 git（大文件）") {
            if !lines.isEmpty && lines.last != "" { lines.append("") }
            lines.append("# Resound: 音频不入 git（大文件）")
        }
        lines.append(contentsOf: missing)
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: gi)
    }

    /// 文本派生物自动同步：忽略音频 → add -A → 有改动则 commit → push。
    /// 非 git 区 / 无改动 安静返回 false（不抛错搅扰主流程）。
    @discardableResult
    public func syncTextOnly(message: String) throws -> Bool {
        guard isRepo else { return false }
        try ensureAudioIgnored()
        try run(["add", "-A"])
        let status = (try? run(["status", "--porcelain"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !status.isEmpty else { return false }
        try run(["commit", "-m", message])
        try run(["push"])
        return true
    }
}
