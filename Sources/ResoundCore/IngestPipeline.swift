import Foundation

/// 端到端最小闭环：音频 → 转录 → 按契约写入 vault →（可选）git push。
public struct IngestPipeline {
    public let vault: Vault
    public init(vaultRoot: URL) {
        self.vault = Vault(root: vaultRoot)
    }

    public struct Output {
        public let recordingDir: URL
        public let id: String
    }

    public func ingest(
        audioPath: URL,
        title: String?,
        source: String,
        tags: [String],
        model: String,
        push: Bool,
        log: (String) -> Void = { print($0) }
    ) async throws -> Output {
        try vault.validate()

        let now = Date()
        let displayTitle = title ?? defaultTitle(from: audioPath)
        let id = makeRecordingID(title: displayTitle, source: source, date: now)
        let dir = vault.recordingDir(id: id, date: now)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log("📁 录音目录：\(dir.path)")

        // 1. 音频 → m4a（写进 vault）
        let audioOut = dir.appendingPathComponent("audio.m4a")
        log("🎧 导出音频 → audio.m4a …")
        let duration = try await AudioConverter().exportM4A(from: audioPath, to: audioOut)
        log(String(format: "   时长 %.1fs", duration))

        // 2. 转录（词级时间戳）
        log("📝 WhisperKit 转录中（模型 \(model)，首次会下载模型）…")
        let result = try await Transcriber(model: model).transcribe(audio: audioOut)
        log("   段数 \(result.transcript.segments.count)，语言 \(result.transcript.language)")

        // 3. 写 transcript.json
        let transcriptOut = dir.appendingPathComponent("transcript.json")
        try result.transcript.jsonData().write(to: transcriptOut)
        log("   ✓ transcript.json")

        // 4. 写 recording.yaml
        let manifest = RecordingManifest(
            id: id,
            title: displayTitle,
            recordedAt: iso8601(now),
            durationSec: Int(duration.rounded()),
            source: source,
            language: result.transcript.language,
            tags: tags,
            audioFile: "audio.m4a",
            asrModel: result.modelName
        )
        let manifestOut = dir.appendingPathComponent("recording.yaml")
        try manifest.yaml().data(using: .utf8)!.write(to: manifestOut)
        log("   ✓ recording.yaml")

        // 5. git push（可选）
        if push {
            log("⬆️  git commit + push …")
            let rel = "recordings/\(relativePath(dir, from: vault.root))"
            _ = rel // 提交整个录音目录
            try Git(repo: vault.root).commitAndPush(
                paths: [dir.path],
                message: "rec: \(displayTitle) (\(id))"
            )
            log("   ✓ 已推送到 vault remote")
        }

        return Output(recordingDir: dir, id: id)
    }
}

// MARK: - helpers

func defaultTitle(from audio: URL) -> String {
    audio.deletingPathExtension().lastPathComponent
}

func iso8601(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone.current
    return f.string(from: date)
}

/// id = yyyy-MM-dd-HHmm-<slug>
func makeRecordingID(title: String, source: String, date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd-HHmm"
    let stamp = f.string(from: date)

    var slug = slugify(title)
    if slug.isEmpty { slug = slugify(source) }
    if slug.isEmpty { slug = "rec" }
    return "\(stamp)-\(slug)"
}

/// 保留字母数字与 CJK，其余转 '-'，合并多余 '-'。
func slugify(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        let c = Character(scalar)
        let isAlnum = ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c)
        let isCJK = (0x4E00...0x9FFF).contains(scalar.value)
        if isAlnum || isCJK {
            out.append(Character(scalar.properties.lowercaseMapping))
        } else {
            out.append("-")
        }
    }
    while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
    return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

func relativePath(_ url: URL, from base: URL) -> String {
    let u = url.standardizedFileURL.pathComponents
    let b = base.standardizedFileURL.pathComponents
    var i = 0
    while i < u.count && i < b.count && u[i] == b[i] { i += 1 }
    return u[i...].joined(separator: "/")
}
