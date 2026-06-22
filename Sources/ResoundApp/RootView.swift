import SwiftUI
import ResoundCore

struct RootView: View {
    @EnvironmentObject var recorder: RecordingController

    var body: some View {
        VStack(spacing: 0) {
            RecordingBanner()
            TabView {
                ChatView()
                    .tabItem { Label("问答", systemImage: "bubble.left.and.bubble.right") }
                LibraryView()
                    .tabItem { Label("录音库", systemImage: "waveform") }
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape") }
            }
            .padding(.top, 2)
        }
        .alert("检测到 Google Meet", isPresented: meetDetected) {
            Button("开始录音") { recorder.startRecording() }
            Button("忽略", role: .cancel) { recorder.ignorePrompt() }
        } message: {
            Text("要录制这场会议吗？（麦克风 + 对方声音）")
        }
        .overlay(alignment: .bottom) {
            if !recorder.toast.isEmpty {
                HStack {
                    Text(recorder.toast).font(.callout)
                    Spacer()
                    Button { recorder.toast = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                }
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
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

/// 录音库（占位：阶段3后续接入录音列表 + 带说话人转录 + 播放跳转）
struct LibraryView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("录音库").font(.title2)
            Text("待接入：录音列表 / 带说话人标注的转录 / 播放跳转").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
