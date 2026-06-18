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
}
