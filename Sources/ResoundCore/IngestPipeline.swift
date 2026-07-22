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
        tracks: (mic: URL, sys: URL)? = nil,   // 会议分轨（已与 audioPath 混音同轴）：给了就分开转录再合并
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

        // 分轨先存档（与转写后端无关：事实源，可重转录）
        if let tracks {
            _ = try await M4AExporter().exportM4A(from: tracks.mic, to: dir.appendingPathComponent("track-mic.m4a"))
            _ = try await M4AExporter().exportM4A(from: tracks.sys, to: dir.appendingPathComponent("track-system.m4a"))
            log("   ✓ 分轨已保留：track-mic.m4a / track-system.m4a")
        }

        var result: TranscribeResult
        var mossLabels: [String]? = nil   // MOSS 路径：与 result 段一一对应的说话人标签（S01…）
        let tTranscribe = Date()
        // MOSS 优先：端到端「转录+说话人」一次产出（分轨也走混音——MOSS 联合建模本就为混叠多说话人
        // 设计，分开转两遍会得到两个互不相认的标签空间）。失败回退 whisper 路径，行为同现状。
        if let cfg = try? Config.load(), cfg.mossEnabled {
            do {
                let (r, labels) = try await transcribeMoss(audioOut, cfg: cfg, glossary: glossary, log: log)
                result = r; mossLabels = labels
                if tracks != nil { log("   ℹ️ MOSS 模式：按混音整体转写（联合模型自带说话人分离）") }
            } catch {
                log("   ⚠️ MOSS 转写失败，回退 Whisper：\(error)")
                AppLog.error("MOSS 转写失败，回退 Whisper", error)
                result = try await whisperTranscribe(dir: dir, audioOut: audioOut, tracks: tracks,
                                                     glossary: glossary, model: model, language: language,
                                                     maxFallback: maxFallback, log: log)
            }
        } else {
            result = try await whisperTranscribe(dir: dir, audioOut: audioOut, tracks: tracks,
                                                 glossary: glossary, model: model, language: language,
                                                 maxFallback: maxFallback, log: log)
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

        // 3.5 MOSS：说话人标签暂存 moss-diar.json（S01/S02 匿名段）。后台命名 worker 用它做
        // CAM++ 声纹→注册库匹配→写正式 diarization.json（见 MossSpeakers.swift）；保留此文件供重新识别。
        if let labels = mossLabels {
            let segs = finalTranscript.segments.count == labels.count
                ? finalTranscript.segments : result.transcript.segments   // 校对异常改了段数则退回校对前配对
            let diar = zip(segs, labels).map { SpeakerSeg(start: $0.start, end: $0.end, speaker: $1) }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(diar).write(to: dir.appendingPathComponent("moss-diar.json"))
            log("   ✓ moss-diar.json（\(Set(labels).count) 位说话人，待声纹命名）")
        }

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

    /// 原地重转录（保 id/目录/recording.yaml）：老录音换转写后端（如迁 MOSS）或修转录质量用。
    /// 重写 transcript.json（MOSS 时另写 moss-diar.json）；删旧 diarization.json——它按旧转录
    /// 的时间轴贴的标签，换了转录就作废。重索引/说话人命名/摘要由调用方接着串（CLI retranscribe）。
    public func retranscribe(recDir: URL, model: String = "large-v3",
                             log: (String) -> Void = { print($0) }) async throws {
        let manifest = try parseManifest(recDir.appendingPathComponent("recording.yaml"))
        let audioOut = recDir.appendingPathComponent(manifest.audioFile)
        guard FileManager.default.fileExists(atPath: audioOut.path) else {
            throw ConfigError.missing("音频不存在：\(audioOut.path)")
        }
        let micT = recDir.appendingPathComponent("track-mic.m4a")
        let sysT = recDir.appendingPathComponent("track-system.m4a")
        let tracks: (mic: URL, sys: URL)? =
            (FileManager.default.fileExists(atPath: micT.path) && FileManager.default.fileExists(atPath: sysT.path))
            ? (micT, sysT) : nil
        let language = manifest.language.isEmpty ? "zh" : manifest.language
        let glossary = Glossary.load(vaultRoot: vault.root)

        var result: TranscribeResult
        var mossLabels: [String]? = nil
        if let cfg = try? Config.load(), cfg.mossEnabled {
            do {
                let (r, labels) = try await transcribeMoss(audioOut, cfg: cfg, glossary: glossary, log: log)
                result = r; mossLabels = labels
            } catch {
                log("   ⚠️ MOSS 转写失败，回退 Whisper：\(error)")
                result = try await whisperTranscribe(dir: recDir, audioOut: audioOut, tracks: tracks,
                                                     glossary: glossary, model: model, language: language,
                                                     maxFallback: 5, log: log)
            }
        } else {
            result = try await whisperTranscribe(dir: recDir, audioOut: audioOut, tracks: tracks,
                                                 glossary: glossary, model: model, language: language,
                                                 maxFallback: 5, log: log)
        }
        log("   段数 \(result.transcript.segments.count)，语言 \(result.transcript.language)")

        // 与 ingest 步骤 3 同款后处理
        let normalized = ZhConverter.shared.normalize(result.transcript)
        let (corrected, replacements) = glossary.apply(to: normalized)
        if replacements > 0 { log("   ✏️ 别名纠正 \(replacements) 处") }
        var finalTranscript = corrected
        if let cfg = try? Config.load(), cfg.transcribeCorrect {
            do {
                log("🧠 AI 校对转录（\(cfg.correctModel)）…")
                let corrector = TranscriptCorrector(
                    chat: ChatClient(config: cfg, modelOverride: cfg.correctModel), glossaryTerms: glossary.terms,
                    mishearExamples: CorrectionLearner.mishearExamples())
                let (fixed, n) = try await corrector.correct(finalTranscript, log: log)
                finalTranscript = fixed
                log("   ✓ AI 校对改动 \(n) 段")
            } catch { log("   ⚠️ AI 校对失败，保留原转录：\(error)") }
        }
        try finalTranscript.jsonData().write(to: recDir.appendingPathComponent("transcript.json"))
        log("   ✓ transcript.json 已重写")

        try? FileManager.default.removeItem(at: recDir.appendingPathComponent("diarization.json"))
        try? FileManager.default.removeItem(at: recDir.appendingPathComponent("moss-diar.json"))
        if let labels = mossLabels {
            let segs = finalTranscript.segments.count == labels.count
                ? finalTranscript.segments : result.transcript.segments
            let diar = zip(segs, labels).map { SpeakerSeg(start: $0.start, end: $0.end, speaker: $1) }
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            try enc.encode(diar).write(to: recDir.appendingPathComponent("moss-diar.json"))
            log("   ✓ moss-diar.json（\(Set(labels).count) 位说话人，待声纹命名）")
        }
        // provenance 里的 asr_model 同步（行级替换，manifest 其余不动）
        let yamlURL = recDir.appendingPathComponent("recording.yaml")
        if let text = try? String(contentsOf: yamlURL, encoding: .utf8) {
            let lines = text.components(separatedBy: "\n").map { line -> String in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("asr_model:")
                    ? "  asr_model: \(yamlQuote(result.modelName))" : line
            }
            try? lines.joined(separator: "\n").write(to: yamlURL, atomically: true, encoding: .utf8)
        }
    }

    /// whisper 路径（在线/本地 + 分轨转录合并）——原 ingest 内联逻辑原样抽出，
    /// MOSS 未启用或失败时走它，行为与旧版一致（分轨文件的导出已提前到 ingest，本函数只转录）。
    private func whisperTranscribe(
        dir: URL, audioOut: URL, tracks: (mic: URL, sys: URL)?, glossary: Glossary,
        model: String, language: String?, maxFallback: Int, log: (String) -> Void
    ) async throws -> TranscribeResult {
        if let tracks {
            // 分轨转录（dual-track spec）：麦克风轨/系统轨各自 VAD→归一→转录（小声轨不再被大声轨掩盖、
            // 双链路重影不再互相污染），再按时间戳合并 + 去重。
            log("🎙 转录麦克风轨…")
            let micR = try? await transcribeAudio(tracks.mic, glossary: glossary, model: model,
                                                  language: language, maxFallback: maxFallback, log: log)
            log("🖥 转录系统音频轨…")
            let sysR = try? await transcribeAudio(tracks.sys, glossary: glossary, model: model,
                                                  language: language, maxFallback: maxFallback, log: log)
            switch (micR, sysR) {
            case let (m?, s?):
                let lang = s.transcript.segments.count >= m.transcript.segments.count
                    ? s.transcript.language : m.transcript.language
                return TranscribeResult(
                    transcript: TranscriptMerge.merge(mic: m.transcript, sys: s.transcript, language: lang, log: log),
                    modelName: s.modelName)
            case let (m?, nil): log("   ⚠️ 系统轨转录失败，仅用麦克风轨"); return m
            case let (nil, s?): log("   ⚠️ 麦克风轨转录失败，仅用系统轨"); return s
            case (nil, nil):
                log("   ⚠️ 两条分轨转录都失败，回退混音转录")
                return try await transcribeAudio(audioOut, glossary: glossary, model: model,
                                                 language: language, maxFallback: maxFallback, log: log)
            }
        }
        return try await transcribeAudio(audioOut, glossary: glossary, model: model,
                                         language: language, maxFallback: maxFallback, log: log)
    }

    /// MOSS 云端转写（端到端转录+说话人）：VAD 门控 → 归一 → submit/poll → 时间戳映射回原轴。
    /// 成功返回 (转录, 与段一一对应的 S01/S02 说话人标签)；抛错由调用方回退 whisper。
    private func transcribeMoss(
        _ audio: URL, cfg: Config, glossary: Glossary, log: (String) -> Void
    ) async throws -> (TranscribeResult, [String]) {
        log("🤖 MOSS 云端转写中（转录+说话人一次产出，GPU 推理约音频时长 4 成）…")
        var upload = audio
        var temps: [URL] = []
        var vadSpans: [VADGate.Span] = []
        // 与在线 whisper 同款预处理：VAD 剪静音（顺带省 GPU 秒数=省额度）+ 分窗响度归一（仅上传副本）
        if let r = try? await VADGate.voicedM4A(of: audio, log: log) {
            upload = r.url; temps.append(r.url); vadSpans = r.spans
        }
        if let norm = try? await AudioNormalizer.normalizedM4A(of: upload) {
            upload = norm; temps.append(norm); log("   🔊 已响度归一（仅上传转录用）")
        }
        defer { for u in temps { try? FileManager.default.removeItem(at: u) } }
        let out = try await MossTranscriber(config: cfg, hotwords: glossary.terms)
            .transcribe(audio: upload, log: log)
        var transcript = out.result.transcript
        if !vadSpans.isEmpty {
            transcript = VADGate.remap(transcript, spans: vadSpans)   // 段与标签一一对应，remap 只改时间不增删段
        }
        return (TranscribeResult(transcript: transcript, modelName: out.result.modelName), out.speakerLabels)
    }

    /// 单个音频的完整转录链路：在线（VAD 门控 → 分窗响度归一 → whisper → 时间戳映射回原轴）或本地 WhisperKit。
    /// ingest 的混音路径与分轨路径共用。
    private func transcribeAudio(
        _ audio: URL, glossary: Glossary, model: String, language: String?,
        maxFallback: Int, log: (String) -> Void
    ) async throws -> TranscribeResult {
        if let cfg = try? Config.load(), cfg.transcribeOnline {
            log("☁️ 在线转录中（\(cfg.transcribeModel) @ \(cfg.transcribeBaseURL)）…")
            var upload = audio
            var temps: [URL] = []
            var vadSpans: [VADGate.Span] = []
            // 转录前 VAD 门控：剪掉长静音/纯噪声段再上传，从根上减少 whisper 在非语音上的幻觉
            //（「谢谢观看」之类套话/重复）+ 长静音致的时间戳漂移。没多少可剪就退回原文件，零风险。
            if let r = try? await VADGate.voicedM4A(of: audio, log: log) {
                upload = r.url; temps.append(r.url); vadSpans = r.spans
            }
            // 转录前对上传音频做分窗响度归一（在剪辑后的音频上做；仅转录输入，存储/播放的 audio.m4a 不变），
            // 治整条小声 + 前小后大两类场景；整条够响则自动跳过、用原文件，不增加上传体积。
            if let norm = try? await AudioNormalizer.normalizedM4A(of: upload) {
                upload = norm; temps.append(norm); log("   🔊 已响度归一（仅上传转录用）")
            }
            defer { for u in temps { try? FileManager.default.removeItem(at: u) } }
            var result = try await OnlineTranscriber(config: cfg, language: language, prompt: glossary.promptString)
                .transcribe(audio: upload)
            // 剪辑过 → 段落/词时间戳从压缩轴映射回原始轴（与原音频、说话人分割对齐）
            if !vadSpans.isEmpty {
                result = TranscribeResult(transcript: VADGate.remap(result.transcript, spans: vadSpans),
                                          modelName: result.modelName)
            }
            return result
        } else {
            log("📝 WhisperKit 本地转录中（模型 \(model)，首次会下载模型）…")
            return try await Transcriber(model: model, language: language,
                                         prompt: glossary.promptString, maxFallback: maxFallback)
                .transcribe(audio: audio)
        }
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
