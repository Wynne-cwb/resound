import SwiftUI
import ResoundCore

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var rec: RecordingController
    @State private var mounted: Set<AppModel.Page> = [.ask]   // 访问过即常驻，切页不销毁

    var body: some View {
        let _ = Perf.body("RootView")
        let pal = app.palette
        ZStack {
            pal.bg.ignoresSafeArea()
            if app.showOnboarding {
                OnboardingView()
            } else {
                VStack(spacing: 0) {
                    TopBar()
                    StatusBar()
                    HStack(spacing: 0) {
                        Sidebar()
                        Rectangle().fill(pal.border).frame(width: 1)
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(pal.bg)
                    }
                    .overlay(alignment: .bottomLeading) { sidebarToggle(pal) }
                }
            }
            OverlayHost()
        }
        .environment(\.palette, pal)
        .background(WindowConfigurator(isDark: app.isDark))
        .ignoresSafeArea()
    }

    // 埋点结论：卡顿主因是 MarkdownUI「构建+布局一篇文档」单次极慢（几百 ms~1s）。用 switch 切页会销毁旧页、
    // 重建新页 → 切到 Ask 要重建整段对话所有 Markdown = 切换卡的根因。改用「懒挂载 + 常驻」ZStack：
    // 访问过的页面不销毁，切页只切 opacity（不重建 Markdown）。配合瞬时折叠 + 摘要限宽（内容区变宽 Markdown
    // 宽度不变 → 不重排），消除之前 keep-alive 在动画折叠下「多页 Markdown 逐帧重排」的副作用。
    private var content: some View {
        ZStack {
            if mounted.contains(.ask) { ChatView().pageVisible(app.page == .ask) }
            if mounted.contains(.library) { LibraryView().pageVisible(app.page == .library) }
            if mounted.contains(.documents) { DocumentsView().pageVisible(app.page == .documents) }
            if mounted.contains(.templates) { TemplatesView().pageVisible(app.page == .templates) }
            if mounted.contains(.settings) { SettingsView().pageVisible(app.page == .settings) }
        }
        // 当前页必须挂载。关键：关主窗口→菜单栏重开会**重建 RootView**，`mounted` @State 复位成 [.ask]，
        // 但 app.page(App 级 @StateObject 不重建)可能仍是 .library——此时 page 没「变化」故 onChange 不触发，
        // 若不在 onAppear 补挂载，当前页就不渲染→内容区全白。
        .onAppear { mounted.insert(app.page) }
        .onChange(of: app.page) { _, p in mounted.insert(p) }
    }

    /// 折叠按钮：圆形，圆心正好落在侧栏右边框上（跨边框浮动）。
    private func sidebarToggle(_ pal: Palette) -> some View {
        let sidebarWidth: CGFloat = app.sidebarCollapsed ? 64 : 218
        let d: CGFloat = 26
        return Button { app.toggleSidebar() } label: {
            Image(systemName: app.sidebarCollapsed ? "chevron.right" : "chevron.left")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(pal.text2)
                .frame(width: d, height: d)
                .background(pal.elev, in: Circle())
                .overlay(Circle().strokeBorder(pal.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plainHit).hoverCursor()
        .help(app.sidebarCollapsed ? "展开侧栏" : "折叠侧栏")
        .offset(x: sidebarWidth - d / 2, y: -88)   // 圆心 x=侧栏右边框；放在边框下方（footer 卡片之上）
    }
}

extension View {
    /// 常驻页面的显隐：隐藏时透明 + 不接收点击/键盘（含快捷键，避免隐藏页抢 ⌘F）+ 压底层。
    @ViewBuilder func pageVisible(_ visible: Bool) -> some View {
        self.opacity(visible ? 1 : 0).allowsHitTesting(visible).disabled(!visible).zIndex(visible ? 1 : 0)
    }
}

// MARK: - 顶部标题栏（透明标题栏下自绘；左侧留出红黄绿交通灯空间）

struct TopBar: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var rec: RecordingController
    @Environment(\.palette) var pal

    private var title: String {
        switch app.page {
        case .ask: return "Ask Resound"; case .library: return "Library"
        case .documents: return "Documents"
        case .templates: return "Templates"; case .settings: return "Settings"
        }
    }

    var body: some View {
        ZStack {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(pal.text2)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if rec.isIdle {
                    Button(action: rec.startRecording) {
                        HStack(spacing: 7) {
                            Circle().fill(.white).frame(width: 9, height: 9)
                            Text("录音").font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.leading, 11).padding(.trailing, 13)
                        .frame(height: 30)
                        .background(pal.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plainHit).hoverCursor()
                }
                Button(action: app.toggleTheme) {
                    Image(systemName: app.isDark ? "sun.max" : "moon")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(pal.text2)
                        .frame(width: 30, height: 30)
                        .stroke(pal.border, corner: 8)
                }
                .buttonStyle(.plainHit).hoverCursor()
            }
            .padding(.trailing, 16)
        }
        .frame(height: 46)
        .padding(.leading, 78)   // 交通灯
        .background(pal.titlebar)
        .background(TitlebarDragArea())   // 仅此条标题栏可拖窗（内容区已禁用整窗拖动）
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { zoomMainWindow() }   // 双击标题栏撑满/还原
        .overlay(alignment: .bottom) { Rectangle().fill(pal.border).frame(height: 1) }
    }
}

// MARK: - 全局状态栏（录音 / 处理中）

struct StatusBar: View {
    @EnvironmentObject var rec: RecordingController
    @Environment(\.palette) var pal

    var body: some View {
        if rec.isRecording || rec.isProcessing {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    icon
                    VStack(alignment: .leading, spacing: 1) {
                        Text(rec.isRecording ? "正在录音" : "正在处理录音")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(pal.text)
                        Text(sub).font(.system(size: 11.5)).foregroundStyle(pal.text2).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if rec.isRecording {
                    WaveBars(color: pal.rec)
                    Text(mmss(Double(rec.recSeconds)))
                        .font(.system(size: 18, weight: .semibold)).monospacedDigit().foregroundStyle(pal.text)
                    Button(action: rec.stopAndIngest) {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
                            Text("停止").font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(.white).padding(.horizontal, 14).frame(height: 30)
                        .background(pal.rec, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plainHit).hoverCursor()
                } else {
                    HStack(spacing: 8) {
                        Spinner(size: 14, color: pal.accent)
                        Text(RecordingController.procLabels[min(rec.procStep, 2)])
                            .font(.system(size: 12)).foregroundStyle(pal.text2)
                    }
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            .background(rec.isRecording ? pal.recSoft : pal.accentSoft)
            .overlay(alignment: .bottom) { Rectangle().fill(pal.border).frame(height: 1) }
        }
    }

    private var sub: String {
        rec.isRecording ? "正在采集你的麦克风 + Google Meet 声音 · 全程本地"
                        : RecordingController.procLabels[min(rec.procStep, 2)]
    }

    @ViewBuilder private var icon: some View {
        ZStack {
            Circle().fill(rec.isRecording ? pal.rec : pal.accentSoft).frame(width: 34, height: 34)
            if rec.isRecording {
                PulseDot(color: .white, size: 11)
            } else {
                Spinner(size: 16, color: pal.accent)
            }
        }
    }
}

/// 录音状态栏的跳动波形条。
struct WaveBars: View {
    var color: Color
    @State private var on = false
    private let delays: [Double] = [0, 0.15, 0.3, 0.45, 0.2]
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: 3.5, height: 18)
                    .scaleEffect(y: on ? 1 : 0.28, anchor: .bottom)
                    .animation(.easeInOut(duration: 0.45).repeatForever().delay(delays[i]), value: on)
            }
        }
        .frame(height: 20, alignment: .bottom)
        .onAppear { on = true }
    }
}

/// 呼吸圆点（录音指示）。
struct PulseDot: View {
    var color: Color
    var size: CGFloat = 9
    @State private var on = false
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .opacity(on ? 0.3 : 1).scaleEffect(on ? 0.8 : 1)
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - 侧边栏

struct Sidebar: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var library: LibraryModel
    @EnvironmentObject var documents: DocumentsModel
    @EnvironmentObject var settings: SettingsModel
    @Environment(\.palette) var pal

    var body: some View {
        let _ = Perf.body("Sidebar")
        let collapsed = app.sidebarCollapsed
        return VStack(alignment: collapsed ? .center : .leading, spacing: 0) {
            if collapsed {
                BrandIcon(pal: pal, size: 30, bordered: true)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4).padding(.bottom, 16)
            } else {
                HStack(spacing: 9) {
                    BrandIcon(pal: pal, size: 30, bordered: true)
                    Text("Resound").font(.system(size: 14.5, weight: .bold)).foregroundStyle(pal.text)
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 14)
            }

            VStack(spacing: collapsed ? 6 : 2) {
                navRow(.ask, "Ask Resound", "bubble.left")
                navRow(.library, "Library", "waveform", trailingCount: library.recordingCount)
                navRow(.documents, "Documents", "doc.text", trailingCount: documents.documentCount)
                navRow(.templates, "Templates", "square.grid.2x2", trailingCount: settings.templates.count)
                navRow(.settings, "Settings", "slider.horizontal.3", attn: settings.needsAttention)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, collapsed ? 10 : 12).padding(.vertical, 14)
        .frame(width: collapsed ? 64 : 218)
        .background(pal.sidebar)
    }

    @ViewBuilder private func navRow(_ page: AppModel.Page, _ label: String, _ icon: String,
                                     trailingCount: Int? = nil, attn: Bool = false) -> some View {
        let on = app.page == page
        Button { withAnimation(.easeOut(duration: 0.12)) { app.page = page } } label: {
            if app.sidebarCollapsed {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                    .foregroundStyle(on ? .white : pal.text2)
                    .frame(width: 40, height: 40)
                    .background(on ? pal.accent : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .topTrailing) { if attn { Circle().fill(pal.warn).frame(width: 7, height: 7).offset(x: -5, y: 5) } }
                    .contentShape(Rectangle())
            } else {
                HStack(spacing: 11) {
                    Image(systemName: icon).font(.system(size: 14, weight: .medium)).frame(width: 17)
                    Text(label).font(.system(size: 13.5, weight: .semibold))
                    Spacer(minLength: 0)
                    if let c = trailingCount {
                        Text("\(c)").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(on ? .white.opacity(0.85) : pal.text3)
                    }
                    if attn { Circle().fill(pal.warn).frame(width: 7, height: 7) }
                }
                .foregroundStyle(on ? .white : pal.text2)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(on ? pal.accent : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plainHit).hoverCursor().help(app.sidebarCollapsed ? label : "")
    }
}

struct SidebarLogo: View {
    var pal: Palette
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(pal.accentSoft)
            WaveMark(pal: pal, height: size * 0.47, bars: [5, 11, 7, 13])
        }
        .frame(width: size, height: size)
    }
}
