import SwiftUI
import AVFoundation
import ResoundCore

@MainActor
final class LibraryViewModel: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        let start: Double
        let end: Double
        let text: String
        var speaker: String?
    }

    @Published var recordings: [RecordingSummary] = []
    @Published var selected: RecordingSummary?
    @Published var lines: [Line] = []
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var loadError: String?
    @Published var analyzing = false

    var hasSpeakers: Bool { lines.contains { $0.speaker != nil } }

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var scrubbing = false

    func load() {
        guard let vault = (try? Config.load())?.vaultPath, !vault.isEmpty else {
            loadError = "未设置 VAULT_PATH，无法读取录音库（设置页查看）"; return
        }
        recordings = listRecordings(vaultRoot: URL(fileURLWithPath: vault))
        loadError = recordings.isEmpty ? "vault 里还没有录音" : nil
        if selected == nil || !recordings.contains(where: { $0.id == selected?.id }) {
            select(recordings.first)
        }
    }

    func select(_ rec: RecordingSummary?) {
        stop()
        selected = rec
        lines = []; currentTime = 0; duration = 0
        guard let rec, let t = loadTranscript(rec.transcriptURL) else { return }

        // 说话人来源：优先 diarization.json（缓存），否则 index 的 chunk person
        let diar = loadDiarization(rec.dir)
        let spans: [(start: Double, end: Double, person: String?)] = diar?.map { ($0.start, $0.end, $0.speaker) }
            ?? (try? Index(path: defaultIndexPath(),
                           dim: (try? Config.load())?.embeddingDim ?? 4096))?.chunkPersons(recordingId: rec.id)
            ?? []
        func speakerAt(_ time: Double) -> String? {
            spans.first(where: { $0.start <= time && time <= $0.end })?.person
                ?? spans.min(by: { abs(($0.start + $0.end)/2 - time) < abs(($1.start + $1.end)/2 - time) })?.person
        }
        lines = t.segments.map {
            Line(start: $0.start, end: $0.end, text: $0.text, speaker: speakerAt(($0.start + $0.end)/2))
        }
        if let p = try? AVAudioPlayer(contentsOf: rec.audioURL) {
            p.prepareToPlay(); player = p; duration = p.duration
        }
    }

    func analyze() {
        guard let rec = selected, let model = (try? Config.load())?.speakerModel else {
            loadError = "未设置 SPEAKER_MODEL，无法识别说话人"; return
        }
        analyzing = true
        Task {
            defer { analyzing = false }
            do {
                let segs = try await analyzeSpeakers(rec, model: model)
                let byMid: (Double) -> String? = { mid in
                    segs.first(where: { $0.start <= mid && mid <= $0.end })?.speaker
                }
                lines = lines.map { var l = $0; l.speaker = byMid(($0.start + $0.end)/2); return l }
            } catch {
                loadError = "识别失败：\(error)"
            }
        }
    }

    func rename(_ rec: RecordingSummary, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        try? renameRecording(rec, to: t)
        let keepId = selected?.id
        load()
        selected = recordings.first { $0.id == keepId }
    }

    func delete(_ rec: RecordingSummary) {
        stop()
        try? deleteRecording(rec)
        if let idx = try? Index(path: defaultIndexPath(), dim: (try? Config.load())?.embeddingDim ?? 4096) {
            try? idx.deleteRecording(id: rec.id)
        }
        if selected?.id == rec.id { selected = nil }
        load()
    }

    func togglePlay() {
        guard let p = player else { return }
        if p.isPlaying { p.pause(); isPlaying = false; stopTimer() }
        else { p.play(); isPlaying = true; startTimer() }
    }

    func seek(to time: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(time, p.duration)); currentTime = p.currentTime
        if !p.isPlaying { p.play(); isPlaying = true; startTimer() }
    }

    func scrubBegan() { scrubbing = true }
    func scrubEnded(to time: Double) {
        scrubbing = false
        player?.currentTime = max(0, min(time, duration)); currentTime = player?.currentTime ?? time
    }

    func stop() { player?.stop(); player = nil; isPlaying = false; stopTimer() }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, !self.scrubbing else { return }
                self.currentTime = p.currentTime
                if !p.isPlaying { self.isPlaying = false; self.stopTimer() }
            }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
}

struct LibraryView: View {
    @StateObject private var vm = LibraryViewModel()
    @State private var renameTarget: RecordingSummary?
    @State private var renameText = ""
    @State private var deleteTarget: RecordingSummary?

    var body: some View {
        HStack(spacing: 0) {
            recordingList
            Divider()
            detail
        }
        .onAppear { vm.load() }
        .alert("重命名录音", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("标题", text: $renameText)
            Button("保存") { if let r = renameTarget { vm.rename(r, to: renameText) }; renameTarget = nil }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .alert("删除这条录音？", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("删除", role: .destructive) { if let r = deleteTarget { vm.delete(r) }; deleteTarget = nil }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: {
            Text("将删除音频、转录与索引，不可恢复。")
        }
    }

    private var recordingList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(vm.recordings) { rec in
                    let isSel = vm.selected?.id == rec.id
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rec.title).font(.system(size: 13, weight: .medium))
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .foregroundStyle(.primary)
                        Text("\(shortDate(rec.recordedAt)) · \(mmss(Double(rec.durationSec)))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 9).padding(.horizontal, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSel ? Theme.accent.opacity(0.14) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onTapGesture { vm.select(rec) }
                    .hoverCursor()
                    .contextMenu {
                        Button("重命名") { renameText = rec.title; renameTarget = rec }
                        Button("删除", role: .destructive) { deleteTarget = rec }
                    }
                }
            }
            .padding(10)
        }
        .frame(width: 250)
    }

    @ViewBuilder private var detail: some View {
        if let rec = vm.selected {
            VStack(spacing: 0) {
                playerBar(rec)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(vm.lines) { transcriptRow($0) }
                    }
                    .padding(18)
                }
            }
        } else {
            VStack(spacing: 14) {
                WaveMark(size: 56)
                Text(vm.loadError ?? "选择左侧一条录音").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func playerBar(_ rec: RecordingSummary) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button { vm.togglePlay() } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.accentGradient))
                }
                .buttonStyle(.plain).hoverCursor()
                Text(rec.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                Spacer()
                if vm.analyzing {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("识别中…").font(.caption).foregroundStyle(.secondary) }
                } else if !vm.hasSpeakers {
                    Button { vm.analyze() } label: { Label("识别说话人", systemImage: "person.wave.2") }
                        .buttonStyle(.bordered).controlSize(.small).hoverCursor()
                }
            }
            HStack(spacing: 10) {
                Text(mmss(vm.currentTime)).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 40)
                Slider(value: $vm.currentTime, in: 0...max(vm.duration, 0.1)) { editing in
                    if editing { vm.scrubBegan() } else { vm.scrubEnded(to: vm.currentTime) }
                }
                .tint(Theme.accent)
                Text(mmss(vm.duration)).font(.caption).foregroundStyle(.secondary).monospacedDigit().frame(width: 40)
            }
        }
        .padding(14)
    }

    private func transcriptRow(_ line: LibraryViewModel.Line) -> some View {
        let active = vm.currentTime >= line.start && vm.currentTime < line.end
        return HStack(alignment: .top, spacing: 10) {
            Text(mmss(line.start)).font(.caption).monospacedDigit()
                .foregroundStyle(active ? Theme.accent : .secondary)
                .frame(width: 44, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if let p = line.speaker {
                    Text("👤\(p)").font(.caption2)
                        .padding(.vertical, 2).padding(.horizontal, 7)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                }
                Text(line.text).lineSpacing(2)
                    .foregroundStyle(active ? Color.primary : Color.primary.opacity(0.85))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? Theme.accent.opacity(0.07) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { vm.seek(to: line.start) }
        .hoverCursor()
    }
}

private func mmss(_ s: Double) -> String {
    let t = Int(s.rounded()); return String(format: "%d:%02d", t / 60, t % 60)
}

private func shortDate(_ iso: String) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    guard let d = f.date(from: iso) else { return String(iso.prefix(10)) }
    let out = DateFormatter(); out.dateFormat = "M月d日 HH:mm"; out.locale = Locale(identifier: "zh_CN")
    return out.string(from: d)
}
