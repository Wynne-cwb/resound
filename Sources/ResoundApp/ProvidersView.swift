import SwiftUI
import AppKit
import ResoundCore

// MARK: - 能力卡片（chat / embedding / 转写）
//
// 设置页里是「手风琴卡」：收起只显示一行摘要 + 验证状态药丸，展开才露出表单；
// 首启引导里 collapsible=false，常驻展开。本地 @State 草稿，仅在提交点写回 ProvidersModel 并落盘。
struct CapabilityCard: View {
    let cap: ProvidersModel.Capability
    var collapsible: Bool = true
    var isOpen: Bool = true
    var onToggle: () -> Void = {}
    @EnvironmentObject var providers: ProvidersModel
    @Environment(\.palette) var pal

    @State private var presetId: String?
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var model = ""
    @State private var useLocal = false
    @State private var keyVisible = false
    @State private var seeded = false
    @State private var openMenu: String? = nil   // 自定义下拉：nil / "provider" / "model" / "correct"
    // 转录后 AI 校对（仅对话卡显示；跑在对话服务商上）
    @State private var correctOn = true
    @State private var correctModel = ""

    private var open: Bool { collapsible ? isOpen : true }
    private var preset: ProviderPreset? { presetId.flatMap { pid in ProviderPreset.all.first { $0.id == pid } } }
    private var needsKey: Bool { preset?.needsKey ?? true }
    private var state: ProvidersModel.ProbeState { providers.probe[cap] ?? .idle }
    private func sugs(_ p: ProviderPreset) -> [String] {
        switch cap { case .chat: return p.chatModels; case .embedding: return p.embeddingModels; case .transcribe: return p.transcribeModels }
    }
    private var suggestions: [String] { preset.map(sugs) ?? [] }
    private var presetsForCap: [ProviderPreset] { ProviderPreset.all.filter { !sugs($0).isEmpty } }

    private var capIcon: String {
        switch cap { case .chat: return "bubble.left.and.text.bubble.right"; case .embedding: return "point.3.connected.trianglepath.dotted"; case .transcribe: return "waveform" }
    }
    private var summary: String {
        if cap == .transcribe && useLocal { return "本地 Whisper · 离线内置" }
        if let p = providers.provider(cap) {
            let name = p.presetId.flatMap { pid in ProviderPreset.all.first { $0.id == pid }?.name } ?? "自定义"
            let m = providers.model(cap)
            return m.isEmpty ? name : "\(name) · \(m)"
        }
        return cap.required ? "未配置" : "未配置 · 默认用本地 Whisper"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if open {
                Rectangle().fill(pal.border).frame(height: 1)
                bodyContent.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
            }
        }
        .card(pal)
        .onAppear { if !seeded { seed(); seeded = true } }
        .onChange(of: providers.importToken) { _, _ in seed() }
    }

    // MARK: 头部

    @ViewBuilder private var headerRow: some View {
        let inner = HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(pal.accentSoft)
                Image(systemName: capIcon).font(.system(size: 15, weight: .medium)).foregroundStyle(pal.accent)
            }.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(cap.title).font(.system(size: 14, weight: .bold)).foregroundStyle(pal.text)
                    Text(cap.required ? "必填" : "可选")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(cap.required ? pal.accent : pal.text3)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(cap.required ? pal.accentSoft : pal.inset, in: Capsule())
                }
                Text(summary).font(.system(size: 12)).foregroundStyle(pal.text2).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            statusPill
            if collapsible {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(pal.text3)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .contentShape(Rectangle())

        if collapsible {
            Button(action: onToggle) { inner }.buttonStyle(.plainHit).hoverCursor()
        } else {
            inner
        }
    }

    @ViewBuilder private var statusPill: some View {
        switch state {
        case .running: pill(pal.text2, pal.inset) { Spinner(size: 10, color: pal.text2); Text("测试中") }
        case .ok:      pill(pal.ok, pal.ok.opacity(0.13)) { Image(systemName: "checkmark").font(.system(size: 9, weight: .black)); Text("已验证") }
        case .fail:    pill(pal.rec, pal.recSoft) { Image(systemName: "xmark").font(.system(size: 9, weight: .black)); Text("验证失败") }
        case .idle:    if !model.isEmpty && !(cap == .transcribe && useLocal) { pill(pal.text3, pal.inset) { Text("未验证") } }
        }
    }
    @ViewBuilder private func pill<C: View>(_ fg: Color, _ bg: Color, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 4) { content() }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 3).background(bg, in: Capsule())
    }

    // MARK: 展开体

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(cap.subtitle).font(.system(size: 12)).foregroundStyle(pal.text3).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if cap == .transcribe { transcribeModeSwitch }

            if cap == .transcribe && useLocal {
                localWhisperCard
            } else {
                form
            }

            if cap == .chat { correctionBlock }
        }
    }

    // 转录后 AI 校对：开关 + 校对模型（跑在对话服务商上，默认跟随对话模型）
    private var correctionBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(pal.border).frame(height: 1).padding(.top, 2)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("转录后 AI 校对").font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.text)
                    Text("转完用 AI 纠正别字/术语/标点。用上面这个对话服务商运行。")
                        .font(.system(size: 11.5)).foregroundStyle(pal.text2).lineSpacing(1.5).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SwitchToggle(on: Binding(get: { correctOn }, set: { correctOn = $0; flushCorrection() }), pal: pal)
            }
            if correctOn {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("校对模型")
                    fieldBox {
                        TextField("默认跟随对话模型，可填更便宜的（如 flash）", text: $correctModel).onSubmit { flushCorrection() }
                        if !suggestions.isEmpty { presetPill(open: openMenu == "correct") { toggleMenu("correct") } }
                    }
                    if openMenu == "correct" {
                        dropdown(items: suggestions, active: correctModel, mono: true) { correctModel = $0; flushCorrection(); openMenu = nil }
                    }
                }
            }
        }
    }
    private func flushCorrection() { providers.setCorrection(enabled: correctOn, model: correctModel) }

    private var transcribeModeSwitch: some View {
        HStack(spacing: 4) {
            segButton("在线服务", active: !useLocal) { useLocal = false; flush() }
            segButton("本地 Whisper", active: useLocal) { useLocal = true; providers.useLocalTranscribe() }
        }
        .padding(3).background(pal.inset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    private func segButton(_ label: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(active ? pal.text : pal.text2)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(active ? pal.elev : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .stroke(active ? pal.border : .clear, corner: 7)
        }.buttonStyle(.plainHit).hoverCursor()
    }

    private var localWhisperCard: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(pal.ok.opacity(0.12))
                Image(systemName: "cpu").font(.system(size: 17)).foregroundStyle(pal.ok)
            }.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("whisper-large-v3").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(pal.text)
                Text("在本机离线转写，无需联网或填写任何在线配置。首次运行会下载模型，较慢。")
                    .font(.system(size: 11.5)).foregroundStyle(pal.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14).background(pal.inset, in: RoundedRectangle(cornerRadius: 11, style: .continuous)).stroke(pal.border, corner: 11)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 13) {
            // 服务商
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("服务商")
                Button { toggleMenu("provider") } label: {
                    HStack(spacing: 8) {
                        Text(preset?.name ?? "自定义").font(.system(size: 13.5)).foregroundStyle(pal.text)
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold)).foregroundStyle(pal.text3)
                            .rotationEffect(.degrees(openMenu == "provider" ? 180 : 0))
                    }
                    .padding(.horizontal, 12).frame(height: 38)
                    .background(pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(pal.borderStrong, corner: 9)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).hoverCursor()
                if openMenu == "provider" {
                    dropdown(items: presetsForCap.map { $0.name } + ["自定义"], active: preset?.name ?? "自定义", mono: false) { name in
                        if name == "自定义" { selectPreset(nil) } else { selectPreset(presetsForCap.first { $0.name == name }?.id) }
                        openMenu = nil
                    }
                }
            }

            // Base URL
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("Base URL")
                fieldBox { TextField("https://api.example.com/v1", text: $baseURL).onSubmit { flush() } }
            }

            // API Key
            if needsKey {
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel("API Key")
                    fieldBox {
                        Group { if keyVisible { TextField("sk-…", text: $apiKey) } else { SecureField("sk-…", text: $apiKey) } }
                            .onSubmit { flush() }
                        Button { keyVisible.toggle() } label: {
                            Image(systemName: keyVisible ? "eye.slash" : "eye").font(.system(size: 13)).foregroundStyle(pal.text3)
                        }.buttonStyle(.plainHit).hoverCursor()
                    }
                    if let url = preset?.keysURL, apiKey.isEmpty {
                        Link(destination: URL(string: url)!) {
                            HStack(spacing: 4) { Image(systemName: "arrow.up.right.square"); Text("获取 \(preset?.name ?? "") API Key") }
                                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(pal.accent)
                        }.buttonStyle(.plain).hoverCursor()
                    }
                }
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle").font(.system(size: 12)); Text("本地服务无需 API Key。")
                }.font(.system(size: 12)).foregroundStyle(pal.text3)
            }

            // 模型名
            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("模型名")
                fieldBox {
                    TextField("手动填写，或从预设里选择", text: $model).onSubmit { flush() }
                    if !suggestions.isEmpty { presetPill(open: openMenu == "model") { toggleMenu("model") } }
                }
                if openMenu == "model" {
                    dropdown(items: suggestions, active: model, mono: true) { model = $0; flush(); openMenu = nil }
                }
            }

            // 测试
            HStack(spacing: 13) {
                Button { testNow() } label: {
                    HStack(spacing: 6) {
                        if case .running = state { Spinner(size: 13, color: .white) }
                        else { Image(systemName: "bolt.fill").font(.system(size: 11)) }
                        Text("测试连接").font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(.white).padding(.horizontal, 15).frame(height: 34)
                    .background(pal.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plainHit).hoverCursor()
                .disabled({ if case .running = state { return true } else { return false } }())
                detailText
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private var detailText: some View {
        switch state {
        case .ok(let m): Text(m).font(.system(size: 11.5)).foregroundStyle(pal.ok).fixedSize(horizontal: false, vertical: true)
        case .fail(let m): Text(m).font(.system(size: 11.5)).foregroundStyle(pal.rec).fixedSize(horizontal: false, vertical: true)
        default: EmptyView()
        }
    }

    private func fieldLabel(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(pal.text3)
    }
    private func fieldBox<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .font(.system(size: 13, design: .monospaced)).foregroundStyle(pal.text)
            .textFieldStyle(.plain)
            .padding(.horizontal, 12).frame(height: 38)
            .background(pal.bg, in: RoundedRectangle(cornerRadius: 9, style: .continuous)).stroke(pal.borderStrong, corner: 9)
    }

    private func toggleMenu(_ k: String) { withAnimation(.easeOut(duration: 0.12)) { openMenu = openMenu == k ? nil : k } }

    // 「预设」小药丸（字段内右侧），点开/收起模型下拉
    private func presetPill(open: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("预设")
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(pal.text2)
            .padding(.horizontal, 9).frame(height: 28)
            .background(pal.inset, in: RoundedRectangle(cornerRadius: 7, style: .continuous)).stroke(pal.border, corner: 7)
        }.buttonStyle(.plain).hoverCursor()
    }

    // 自定义下拉面板：字段正下方整宽，选项等宽（模型）/常规（服务商），选中项打勾高亮。
    private func dropdown(items: [String], active: String, mono: Bool, onPick: @escaping (String) -> Void) -> some View {
        VStack(spacing: 2) {
            ForEach(items, id: \.self) { it in
                Button { onPick(it) } label: {
                    HStack(spacing: 8) {
                        Text(it).font(.system(size: 13, design: mono ? .monospaced : .default)).foregroundStyle(pal.text)
                        Spacer(minLength: 0)
                        if it == active { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(pal.accent) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(it == active ? pal.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).hoverCursor()
            }
        }
        .padding(5)
        .background(pal.elev, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(pal.borderStrong))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    // MARK: 行为

    private func selectPreset(_ id: String?) {
        presetId = id
        if let p = id.flatMap({ pid in ProviderPreset.all.first { $0.id == pid } }) {
            baseURL = p.baseURL
            if !p.needsKey { apiKey = "" }
            if model.isEmpty || !sugs(p).contains(model) { model = sugs(p).first ?? model }
        }
        flush()
    }
    private func seed() {
        if cap == .chat {
            correctOn = providers.correctionEnabled
            correctModel = providers.correctionModel
        }
        if let p = providers.provider(cap) {
            presetId = p.presetId; baseURL = p.baseURL; apiKey = p.apiKey; model = providers.model(cap); useLocal = false
        } else if cap == .transcribe {
            useLocal = true
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

// MARK: - 设置页「AI 服务」单区内容（标题 + 导入导出 + 三张手风琴卡）

struct ProvidersSection: View {
    @EnvironmentObject var providers: ProvidersModel
    @Environment(\.palette) var pal
    @State private var expanded: ProvidersModel.Capability? = .chat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("AI 服务").font(.system(size: 17, weight: .bold)).foregroundStyle(pal.text)
                    Text("接入任意 OpenAI 兼容的服务。三种能力可分别配置，互不影响。")
                        .font(.system(size: 12.5)).foregroundStyle(pal.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                HStack(spacing: 7) {
                    miniButton("square.and.arrow.down", "导入") { providers.importConfig() }
                    miniButton("square.and.arrow.up", "导出") { providers.exportConfig() }
                }
            }

            VStack(spacing: 13) {
                ForEach(ProvidersModel.Capability.allCases) { cap in
                    CapabilityCard(cap: cap, collapsible: true, isOpen: expanded == cap,
                                   onToggle: { withAnimation(.easeOut(duration: 0.18)) { expanded = expanded == cap ? nil : cap } })
                }
            }
            .padding(.top, 18)
        }
    }

    private func miniButton(_ icon: String, _ text: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: icon).font(.system(size: 11, weight: .semibold)); Text(text).font(.system(size: 12, weight: .semibold)) }
                .foregroundStyle(pal.text).padding(.horizontal, 11).frame(height: 30)
                .background(pal.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous)).stroke(pal.borderStrong, corner: 8)
        }.buttonStyle(.plainHit).hoverCursor()
    }
}
