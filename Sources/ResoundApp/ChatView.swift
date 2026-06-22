import SwiftUI
import ResoundCore

/// 问答页：检索 → 重排 → LLM 综合，答案带可点来源(录音/时间/说话人)。= CLI 的 ask。
@MainActor
final class ChatViewModel: ObservableObject {
    struct Source: Identifiable {
        let id = UUID()
        let recording: String
        let start: Int
        let end: Int
        let person: String?
    }
    struct Message: Identifiable {
        let id = UUID()
        let isUser: Bool
        let text: String
        var sources: [Source] = []
    }

    @Published var messages: [Message] = []
    @Published var input = ""
    @Published var busy = false

    func send() async {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        input = ""
        messages.append(Message(isUser: true, text: q))
        busy = true
        defer { busy = false }
        do {
            let cfg = try Config.load()
            let pipeline = IndexPipeline(config: cfg)
            let hits = try await pipeline.search(query: q, indexPath: defaultIndexPath(), topK: 8, rerank: true)
            guard !hits.isEmpty else {
                messages.append(Message(isUser: false, text: "没有检索到相关内容。先用 CLI 建索引（resound index）。"))
                return
            }
            let chat = ChatClient(config: cfg, modelOverride: cfg.answerModel)
            let answer = try await Synthesizer(chat: chat).answer(query: q, hits: hits)
            let sources = hits.map {
                Source(recording: $0.recordingId, start: Int($0.start), end: Int($0.end), person: $0.personId)
            }
            messages.append(Message(isUser: false, text: answer, sources: sources))
        } catch {
            messages.append(Message(isUser: false, text: "出错：\(error)"))
        }
    }
}

struct ChatView: View {
    @StateObject private var vm = ChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if vm.messages.isEmpty { emptyState }
                        ForEach(vm.messages) { m in
                            MessageRow(message: m).id(m.id)
                        }
                        if vm.busy {
                            HStack(spacing: 9) {
                                WaveMark(size: 30)
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("检索 + 思考中…").font(.callout).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 11).padding(.horizontal, 14)
                                .softCard()
                                Spacer(minLength: 40)
                            }
                        }
                    }
                    .padding(20)
                }
                .onChange(of: vm.messages.count) { _, _ in
                    if let last = vm.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            inputBar
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            WaveMark(size: 56)
            Text("问问你的录音")
                .font(.title3).fontWeight(.medium)
            Text("比如「上次和 GGbond 聊 OS 迁移定了什么？」")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("问问你的录音…", text: $vm.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...4)
                .onSubmit { Task { await vm.send() } }
            Button {
                Task { await vm.send() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canSend ? Color.white : Color.secondary)
                    .frame(width: 30, height: 30)
                    .background {
                        if canSend {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accentGradient)
                        } else {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05))
                        }
                    }
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend)
        }
        .padding(.vertical, 8).padding(.leading, 16).padding(.trailing, 8)
        .background(Color(nsColor: .textBackgroundColor),
                   in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 10, y: 3)
        .padding(.horizontal, 16).padding(.bottom, 14)
    }

    private var canSend: Bool {
        !vm.busy && !vm.input.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

private struct MessageRow: View {
    let message: ChatViewModel.Message

    var body: some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 50)
                Text(message.text)
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .background(Theme.accentGradient,
                               in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Theme.accent.opacity(0.28), radius: 6, y: 2)
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                WaveMark(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(message.text)
                        .textSelection(.enabled)
                        .lineSpacing(3)
                    if !message.sources.isEmpty { sourcesView }
                }
                .padding(.vertical, 12).padding(.horizontal, 15)
                .softCard()
                Spacer(minLength: 40)
            }
        }
    }

    private var sourcesView: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("来源")
                .font(.caption2).foregroundStyle(.tertiary)
                .padding(.top, 11)
            ForEach(message.sources) { s in
                HStack(spacing: 7) {
                    Label(s.recording, systemImage: "microphone")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("@\(s.start)–\(s.end)s").font(.caption).foregroundStyle(.tertiary)
                    if let p = s.person {
                        Text("👤\(p)")
                            .font(.caption2)
                            .padding(.vertical, 2).padding(.horizontal, 6)
                            .background(Color.primary.opacity(0.06),
                                       in: Capsule())
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            Divider().padding(.top, 4)
        }
    }
}
