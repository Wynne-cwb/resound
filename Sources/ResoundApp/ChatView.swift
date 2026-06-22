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
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if vm.messages.isEmpty {
                            Text("问问你的录音，比如「上次和 GGbond 聊 OS 迁移定了什么？」")
                                .foregroundStyle(.secondary)
                                .padding(.top, 40)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(vm.messages) { m in
                            MessageRow(message: m)
                                .id(m.id)
                        }
                        if vm.busy {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("检索 + 思考中…").foregroundStyle(.secondary) }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: vm.messages.count) { _, _ in
                    if let last = vm.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("问点什么…", text: $vm.input, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { Task { await vm.send() } }
                Button {
                    Task { await vm.send() }
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(vm.busy || vm.input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }
}

private struct MessageRow: View {
    let message: ChatViewModel.Message
    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(message.isUser ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                if !message.sources.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("来源").font(.caption).foregroundStyle(.secondary)
                        ForEach(message.sources) { s in
                            Text("· \(s.recording) @\(s.start)-\(s.end)s" + (s.person.map { " 👤\($0)" } ?? ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            if !message.isUser { Spacer(minLength: 40) }
        }
    }
}
