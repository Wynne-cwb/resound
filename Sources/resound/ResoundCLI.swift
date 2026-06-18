import ArgumentParser
import Foundation
import ResoundCore

@main
struct Resound: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resound",
        abstract: "Resound — 录音 → 转录 → 按数据契约写入 vault",
        subcommands: [Transcribe.self, Record.self]
    )
}

/// resound transcribe <audio> --vault <path> [...]
struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "把已有音频文件转录并写入 vault"
    )

    @Argument(help: "音频文件路径（任意 AVFoundation 可读格式）")
    var audio: String

    @Option(name: .long, help: "vault 根目录")
    var vault: String

    @Option(name: .long, help: "标题（默认取文件名）")
    var title: String?

    @Option(name: .long, help: "来源类型：meeting/memo/call/lecture…")
    var source: String = "memo"

    @Option(name: .long, parsing: .upToNextOption, help: "标签，空格分隔")
    var tags: [String] = []

    @Option(name: .long, help: "WhisperKit 模型")
    var model: String = "large-v3"

    @Flag(name: .long, help: "完成后 git commit + push 回 vault")
    var push = false

    func run() async throws {
        let out = try await IngestPipeline(vaultRoot: URL(fileURLWithPath: vault))
            .ingest(
                audioPath: URL(fileURLWithPath: audio),
                title: title,
                source: source,
                tags: tags,
                model: model,
                push: push
            )
        print("✅ 完成：\(out.id)")
    }
}

/// resound record --vault <path> [...]
struct Record: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "从麦克风录音，然后转录并写入 vault"
    )

    @Option(name: .long, help: "vault 根目录")
    var vault: String

    @Option(name: .long, help: "标题")
    var title: String?

    @Option(name: .long, help: "来源类型")
    var source: String = "memo"

    @Option(name: .long, parsing: .upToNextOption, help: "标签")
    var tags: [String] = []

    @Option(name: .long, help: "WhisperKit 模型")
    var model: String = "large-v3"

    @Option(name: .long, help: "最长录音秒数（默认无限，按 Enter 停止）")
    var maxSeconds: Double?

    @Flag(name: .long, help: "完成后 git commit + push 回 vault")
    var push = false

    func run() async throws {
        let audioURL = try await Recorder().record(maxSeconds: maxSeconds)
        let out = try await IngestPipeline(vaultRoot: URL(fileURLWithPath: vault))
            .ingest(
                audioPath: audioURL,
                title: title,
                source: source,
                tags: tags,
                model: model,
                push: push
            )
        print("✅ 完成：\(out.id)")
    }
}
