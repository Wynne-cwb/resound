import SwiftUI
import ResoundCore

enum AppTab: String, CaseIterable, Identifiable {
    case chat = "Ask Resound", library = "Library", settings = "Settings"
    var id: String { rawValue }
}

struct RootView: View {
    @EnvironmentObject var recorder: RecordingController
    @State private var tab: AppTab = .chat

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                RecordingBanner()
                TopBar(selection: $tab)
                Group {
                    switch tab {
                    case .chat: ChatView()
                    case .library: LibraryView()
                    case .settings: SettingsView()
                    }
                }
            }
        }
        .alert("检测到 Google Meet", isPresented: meetDetected) {
            Button("开始录音") { recorder.startRecording() }
            Button("忽略", role: .cancel) { recorder.ignorePrompt() }
        } message: {
            Text("要录制这场会议吗？（麦克风 + 对方声音）")
        }
        .overlay(alignment: .bottom) {
            if !recorder.toast.isEmpty {
                HStack(spacing: 10) {
                    Text(recorder.toast).font(.callout)
                    Spacer()
                    Button { recorder.toast = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.vertical, 11).padding(.horizontal, 14)
                .softCard(corner: 12)
                .padding(14)
            }
        }
    }

    private var meetDetected: Binding<Bool> {
        Binding(
            get: { if case .meetingDetected = recorder.phase { return true } else { return false } },
            set: { if !$0 { recorder.ignorePrompt() } }
        )
    }
}

/// 顶部分段切换器（磨砂胶囊 + 选中白色药丸滑动）。
struct TopBar: View {
    @Binding var selection: AppTab
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { t in
                let isSel = t == selection
                Text(t.rawValue)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSel ? Color.primary : Color.secondary)
                    .padding(.vertical, 6).padding(.horizontal, 18)
                    .background {
                        if isSel {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "sel", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) { selection = t }
                    }
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        .padding(.top, 8).padding(.bottom, 4)
    }
}

/// 录音/处理状态横幅。
struct RecordingBanner: View {
    @EnvironmentObject var recorder: RecordingController
    var body: some View {
        switch recorder.phase {
        case .recording:
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text("会议录音中…（麦克风 + 对方声音）").foregroundStyle(.white)
                Spacer()
                Button("停止并转录") { recorder.stopAndIngest() }
                    .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.red)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.red)
        case .processing:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("转录入库中…（large-v3，首次较慢）").foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.quaternary)
        default:
            EmptyView()
        }
    }
}

/// 设置（占位：显示配置来源是否就绪）
struct SettingsView: View {
    @State private var status = "检查中…"
    var body: some View {
        Form {
            Section("配置状态") {
                Text(status).textSelection(.enabled)
            }
            Section("说明") {
                Text("密钥从 .env 读取（RESOUND_ENV 环境变量 / ~/Library/Application Support/Resound/.env / 仓库根）。后续这里做可视化设置：vault repo、说话人命名、模型与密钥。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { status = configStatus() }
    }

    private func configStatus() -> String {
        do {
            let c = try Config.load()
            return """
            ✅ 配置已加载
            embedding: \(c.embeddingModel) (dim \(c.embeddingDim))
            chat: \(c.chatModel)
            speakerModel: \(c.speakerModel ?? "未设置（无法做说话人识别）")
            vault: \(c.vaultPath ?? "未设置 VAULT_PATH（会议录音无法入库）")
            索引: \(defaultIndexPath().path)
            """
        } catch {
            return "❌ 配置加载失败：\(error)\n请把仓库 .env 放到 ~/Library/Application Support/Resound/.env，或设 RESOUND_ENV。"
        }
    }
}
