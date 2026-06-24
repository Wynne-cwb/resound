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
        language: String? = nil,
        hints: [String] = [],
        maxFallback: Int = 5,
        push: Bool,
        log: (String) -> Void = { print($0) }
    ) async throws -> Output {
        try vault.validate()

        let now = Date()
        let displayTitle = title ?? defaultTitle(from: audioPath)
        let id = makeRecordingID(title: displayTitle, source: source, date: now)
        let dir = vault.recordingDir(id: id, date: now)
        // 会议日期：标题里的日期 > 音频文件修改时间 > 入库时间。导入旧录音时 now 是「导入时刻」并非会议日，
        // 标题（如「2026-06-10 月度 1on1」）或原文件时间才是真实会议日；录制的会议标题无日期、文件即时写入 ≈ now。
        // 仅用于 recordedAt（排序/详情/Ask 口径）；id/目录仍用 now 保证唯一、不撞目录。
        let meetingDate = parseTitleDate(displayTitle, now: now) ?? fileModifiedDate(audioPath) ?? now

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        log("📁 录音目录：\(dir.path)")

        func el(_ t: Date) -> String { String(format: "%.1fs", Date().timeIntervalSince(t)) }

        // 1. 音频 → m4a（写进 vault）
        let audioOut = dir.appendingPathComponent("audio.m4a")
        log("🎧 导出音频 → audio.m4a …")
        let tExport = Date()
        let duration = try await M4AExporter().exportM4A(from: audioPath, to: audioOut)
        log(String(format: "   时长 %.1fs · ⏱ 导出 %@", duration, el(tExport)))

        // 2. 转录（词级时间戳）
        let glossary = Glossary.load(vaultRoot: vault.root, extraHints: hints)
        if !glossary.terms.isEmpty {
            log("🔤 词表：\(glossary.terms.count) 词偏置，\(glossary.corrections.count) 条别名纠正")
        }

        let result: TranscribeResult
        let tTranscribe = Date()
        if let cfg = try? Config.load(), cfg.transcribeOnline {
            log("☁️ 在线转录中（\(cfg.transcribeModel) @ \(cfg.transcribeBaseURL)）…")
            // 转录前对上传音频做响度归一（仅转录输入；存储/播放的 audio.m4a 不变），改善大会议室小声场景；
            // 已经够响则自动跳过、用原文件，不增加上传体积。
            var upload = audioOut
            if let norm = try? await AudioNormalizer.normalizedM4A(of: audioOut) {
                upload = norm; log("   🔊 已响度归一（仅上传转录用）")
            }
            defer { if upload != audioOut { try? FileManager.default.removeItem(at: upload) } }
            result = try await OnlineTranscriber(config: cfg, language: language, prompt: glossary.promptString)
                .transcribe(audio: upload)
        } else {
            log("📝 WhisperKit 本地转录中（模型 \(model)，首次会下载模型）…")
            result = try await Transcriber(model: model, language: language,
                                           prompt: glossary.promptString, maxFallback: maxFallback)
                .transcribe(audio: audioOut)
        }
        log("   段数 \(result.transcript.segments.count)，语言 \(result.transcript.language) · ⏱ 转录 \(el(tTranscribe))")

        // 3. 繁→简归一 + 别名纠正 +（可选）AI 校对后写 transcript.json（原始音频仍是 ground truth）
        let normalized = ZhConverter.shared.normalize(result.transcript)
        let (corrected, replacements) = glossary.apply(to: normalized)
        if replacements > 0 { log("   ✏️ 别名纠正 \(replacements) 处") }
        var finalTranscript = corrected
        if let cfg = try? Config.load(), cfg.transcribeCorrect {
            do {
                log("🧠 AI 校对转录（\(cfg.correctModel)，保持原意纠错别字/术语）…")
                let tCorrect = Date()
                let corrector = TranscriptCorrector(
                    chat: ChatClient(config: cfg, modelOverride: cfg.correctModel), glossaryTerms: glossary.terms,
                    mishearExamples: CorrectionLearner.mishearExamples())
                let (fixed, n) = try await corrector.correct(finalTranscript, log: log)
                finalTranscript = fixed
                log("   ✓ AI 校对改动 \(n) 段 · ⏱ 校对 \(el(tCorrect))")
            } catch { log("   ⚠️ AI 校对失败，保留原转录：\(error)") }
        }
        let transcriptOut = dir.appendingPathComponent("transcript.json")
        try finalTranscript.jsonData().write(to: transcriptOut)
        log("   ✓ transcript.json")

        // 4. 写 recording.yaml
        let manifest = RecordingManifest(
            id: id,
            title: displayTitle,
            recordedAt: iso8601(meetingDate),
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

    /// 对 vault 内已有 transcript.json 重新做 繁→简归一 + 别名纠正并改写（免重新转录）。
    public func normalizeExisting(log: (String) -> Void = { print($0) }) throws -> Int {
        let glossary = Glossary.load(vaultRoot: vault.root)
        var count = 0
        for dir in findRecordings(vault.root) {
            let tURL = dir.appendingPathComponent("transcript.json")
            guard let data = try? Data(contentsOf: tURL),
                  let t = try? JSONDecoder().decode(Transcript.self, from: data) else { continue }
            let normalized = ZhConverter.shared.normalize(t)
            let (corrected, _) = glossary.apply(to: normalized)
            try corrected.jsonData().write(to: tURL)
            count += 1
            log("  ✓ \(dir.lastPathComponent)")
        }
        return count
    }

    /// 对 vault 内已有 transcript.json 跑一轮 AI 校对（保持原意纠错别字/术语）并改写（免重新转录）。
    /// `id` 指定则只处理该条。返回(处理条数, 累计改动段数)。改完记得 `resound index` 重建检索。
    public func correctExisting(id: String? = nil, log: (String) -> Void = { print($0) }) async throws -> (recordings: Int, segments: Int) {
        let cfg = try Config.load()
        let glossary = Glossary.load(vaultRoot: vault.root)
        let corrector = TranscriptCorrector(
            chat: ChatClient(config: cfg, modelOverride: cfg.correctModel), glossaryTerms: glossary.terms,
            mishearExamples: CorrectionLearner.mishearExamples())
        var recs = 0, segs = 0
        for dir in findRecordings(vault.root) {
            let tURL = dir.appendingPathComponent("transcript.json")
            guard let data = try? Data(contentsOf: tURL),
                  let t = try? JSONDecoder().decode(Transcript.self, from: data) else { continue }
            if let id, (try? parseManifest(dir.appendingPathComponent("recording.yaml")))?.id != id { continue }
            log("▶︎ \(dir.lastPathComponent)")
            let (fixed, n) = try await corrector.correct(t, log: log)
            if n > 0 { try fixed.jsonData().write(to: tURL) }
            recs += 1; segs += n
            log("  ✓ 改动 \(n) 段")
        }
        return (recs, segs)
    }
}

// MARK: - helpers

func defaultTitle(from audio: URL) -> String {
    audio.deletingPathExtension().lastPathComponent
}

/// 音频文件的修改时间（导入旧录音时常≈原始录制时间，作为标题无日期时的会议日期回退）。
func fileModifiedDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
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
