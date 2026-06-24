import SwiftUI
import AppKit
import ResoundCore

// MARK: - 能力卡片（chat / embedding / 转写，可复用于设置页与首启引导）
//
// 本地 @State 草稿，仅在提交点（选预设 / 提交字段 / 测试 / 切本地）写回 ProvidersModel 并落盘，
// 不每键回写 @Published（沿用 Settings 的性能约定）。
struct CapabilityCard: View {
    let cap: ProvidersModel.Capability
    var inOnboarding = false
    @EnvironmentObject var providers: ProvidersModel
    @Environment(\.palette) var pal

    @State private var presetId: String?
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var useLocal = false      // 仅转写：true = 本地 WhisperKit
    @State private var seeded = false

    private var preset: ProviderPreset? { presetId.flatMap { pid in ProviderPreset.all.first { $0.id == pid } } }
    private var needsKey: Bool { preset?.needsKey ?? true }
    private var suggestions: [String] {
        guard let p = preset else { return [] }
        switch cap { case .chat: return p.chatModels; case .embedding: return p.embeddingModels; case .transcribe: return p.transcribeModels }
    }
    private var state: ProvidersModel.ProbeState { providers.probe[cap] ?? .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if cap == .transcribe {
                localToggleRow
            }
            if !(cap == .transcribe && useLocal) {
                editor
            }
        }
        .card(pal)
        .onAppear { if !seeded { seed(); seeded = true } }
        .onChange(of: providers.importToken) { _, _ in seed() }
    }

    // MARK: 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(cap.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(pal.text)
                if cap.required {
                    Text("必填").font(.system(size: 10, weight: .semibold)).foregroundStyle(pal.accent)
                        .padding(.horizontal, 6).padding(.vertical, 1.5).background(pal.accentSoft, in: Capsule())
                } else {
                    Text("可选").font(.system(size: 10, weight: .medium)).foregroundStyle(pal.text3)
                        .padding(.horizontal, 6).padding(.vertical, 1.5).background(pal.inset, in: Capsule())
                }
                Spacer()
                statusBadge
            }
            Text(cap.subtitle).font(.system(size: 11.5)).foregroundStyle(pal.text2).lineSpacing(2)
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    @ViewBuilder private var statusBadge: some View {
        switch state {
        case .idle: EmptyView()
        case .running: HStack(spacing: 5) { Spinner(size: 11, color: pal.accent); Text("测试中…").font(.system(size: 11)).foregroundStyle(pal.text2) }
        case .ok: HStack(spacing: 4) { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)); Text("已验证").font(.system(size: 11, weight: .semibold)) }.foregroundStyle(pal.ok)
        case .fail: HStack(spacing: 4) { Image(systemName: "xmark.circle.fill").font(.system(size: 11)); Text("失败").font(.system(size: 11, weight: .semibold)) }.foregroundStyle(pal.rec)
        }
    }

    // MARK: 转写「本地兜底」开关

    private var localToggleRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("用本地 Whisper").font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.text)
                Text("不联网、隐私最好；首次运行下载模型，速度较慢。").font(.system(size: 11.5)).foregroundStyle(pal.text2)
            }
            Spacer()
            SwitchToggle(on: Binding(get: { useLocal }, set: { v in
                useLocal = v
                if v { providers.useLocalTranscribe() } else { flush() }
            }), pal: pal)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(pal.border).frame(height: 1) }
    }

    // MARK: 编辑器（预设 + 字段 + 测试）

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(pal.border).frame(height: 1)
            // 预设芯片
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    // 只显示对该能力有建议模型的预设（如向量模型不显示没 embedding 的 Claude/DeepSeek/Groq）
                    ForEach(ProviderPreset.all.filter { !suggestionsFor($0).isEmpty }) { p in presetChip(p.name, id: p.id) }
                    presetChip("自定义", id: nil)
                }
                .padding(.horizontal, 16)
            }
            VStack(alignment: .leading, spacing: 10) {
                field("Base URL", text: $baseURL, secure: false, placeholder: "https://api.example.com/v1")
                if needsKey { field("API Key", text: $apiKey, secure: true, placeholder: "sk-…") }
                modelField
                if let url = preset?.keysURL, apiKey.isEmpty && needsKey {
                    Link(destination: URL(string: url)!) {
                        HStack(spacing: 4) { Image(systemName: "arrow.up.right.square"); Text("获取 \(preset?.name ?? "") API Key") }
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(pal.accent)
                    }.buttonStyle(.plain).hoverCursor()
                }
                testRow
            }
            .padding(.horizontal, 16).padding(.bottom, 14)
        }
    }

    private func presetChip(_ name: String, id: String?) -> some View {
        let on = presetId == id
        return Button {
            presetId = id
            if let p = id.flatMap({ pid in ProviderPreset.all.first { $0.id == pid } }) {
                baseURL = p.baseURL
                if !p.needsKey { apiKey = "" }
                if model.isEmpty || !suggestionsFor(p).contains(model) { model = suggestionsFor(p).first ?? model }
            }
            flush()
        } label: {
            Text(name).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? .white : pal.text2)
                .padding(.horizontal, 11).frame(height: 28)
                .background(on ? pal.accent : pal.inset, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? .clear : pal.border))
        }.buttonStyle(.plainHit).hoverCursor()
    }

    private func suggestionsFor(_ p: ProviderPreset) -> [String] {
        switch cap { case .chat: return p.chatModels; case .embedding: return p.embeddingModels; case .transcribe: return p.transcribeModels }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("模型").font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text)
            HStack(spacing: 8) {
                TextField("模型名，如 gpt-4o", text: $model)
                    .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(pal.text)
                    .onSubmit { flush() }
                if !suggestions.isEmpty {
                    Menu {
                        ForEach(suggestions, id: \.self) { m in Button(m) { model = m; flush() } }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.text2)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18).hoverCursor()
                }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(pal.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous)).stroke(pal.border, corner: 7)
        }
    }

    private func field(_ label: String, text: Binding<String>, secure: Bool, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(pal.text)
            Group {
                if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
            }
            .textFieldStyle(.plain).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(pal.text)
            .onSubmit { flush() }
            .padding(.horizontal, 10).frame(height: 32)
            .background(pal.bg, in: RoundedRectangle(cornerRadius: 7, style: .continuous)).stroke(pal.border, corner: 7)
        }
    }

    private var testRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { testNow() } label: {
                HStack(spacing: 6) {
                    if case .running = state { Spinner(size: 12, color: .white) } else { Image(systemName: "bolt.fill").font(.system(size: 11)) }
                    Text("测试连接").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 32)
                .background(pal.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plainHit).hoverCursor()
            .disabled({ if case .running = state { return true } else { return false } }())
            if case .fail(let msg) = state {
                Text(msg).font(.system(size: 11.5)).foregroundStyle(pal.rec).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .ok(let msg) = state {
                Text(msg).font(.system(size: 11.5)).foregroundStyle(pal.ok)
            }
        }
    }

    // MARK: 行为

    private func seed() {
        if let p = providers.provider(cap) {
            presetId = p.presetId; baseURL = p.baseURL; apiKey = p.apiKey; model = providers.model(cap)
            useLocal = false
        } else if cap == .transcribe {
            useLocal = true
            // 给个合理初值（在线时用）
            presetId = "openai"; baseURL = ProviderPreset.all.first { $0.id == "openai" }!.baseURL; model = "gpt-4o-transcribe"
        } else {
            useLocal = false
        }
    }

    private func flush() {
        guard !(cap == .transcribe && useLocal) else { return }
        providers.set(cap, baseURL: baseURL, apiKey: apiKey, model: model, presetId: presetId)
    }

    private func testNow() {
        flush()
        providers.test(cap, baseURL: baseURL, apiKey: apiKey, model: model)
    }
}

// MARK: - 设置页：AI Provider 区

struct ProvidersSection: View {
    @EnvironmentObject var providers: ProvidersModel
    @Environment(\.palette) var pal

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AI PROVIDER").font(.system(size: 12, weight: .semibold)).tracking(0.6).foregroundStyle(pal.text3)
                Spacer()
                Button { providers.importConfig() } label: { miniLabel("square.and.arrow.down", "导入") }.buttonStyle(.plainHit).hoverCursor()
                Button { providers.exportConfig() } label: { miniLabel("square.and.arrow.up", "导出") }.buttonStyle(.plainHit).hoverCursor()
            }
            .padding(.top, 30)
            Text("接入任意 OpenAI 兼容服务（OpenAI / DeepSeek / OpenRouter / 自建 …）。选预设自动填好地址与建议模型，保存即时生效。建议每项「测试连接」确认可用。")
                .font(.system(size: 12)).foregroundStyle(pal.text2).lineSpacing(2).padding(.top, 6)

            ForEach(ProvidersModel.Capability.allCases) { cap in
                CapabilityCard(cap: cap).padding(.top, 11)
            }
        }
    }

    private func miniLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) { Image(systemName: icon).font(.system(size: 11, weight: .semibold)); Text(text).font(.system(size: 12.5, weight: .semibold)) }
            .foregroundStyle(pal.text).padding(.horizontal, 11).frame(height: 30)
            .background(pal.elev, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).stroke(pal.borderStrong, corner: 8)
    }
}
