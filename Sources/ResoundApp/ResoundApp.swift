import SwiftUI
import AppKit

@main
struct ResoundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppModel()
    @StateObject private var recorder = RecordingController()
    @StateObject private var library = LibraryModel()
    @StateObject private var settings = SettingsModel()
    @StateObject private var chat = ChatVM()
    @StateObject private var providers = ProvidersModel()

    var body: some Scene {
        WindowGroup("Resound", id: "main") {
            RootView()
                .environmentObject(app)
                .environmentObject(recorder)
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(chat)
                .environmentObject(providers)
                .frame(minWidth: 940, minHeight: 620)
                .preferredColorScheme(app.isDark ? .dark : .light)
                .onAppear {
                    recorder.app = app
                    recorder.library = library   // 录完后把说话人识别交给 Library 的后台串行 worker
                    library.app = app
                    settings.app = app
                    providers.app = app
                    providers.load()             // 迁移旧 .env → providers.json；决定是否首启引导
                    app.showOnboarding = providers.needsOnboarding
                    settings.load()          // 预载模板等，侧栏 Templates 计数即时正确
                    chat.app = app
                    chat.loadHistory()
                    MeetingPanelController.shared.configure(recorder: recorder, app: app)
                    recorder.startWatching()
                    Perf.start()   // 性能埋点：卡顿看门狗 + body 重算计数 → resound.log
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(app)
                .environmentObject(recorder)
        } label: {
            Image(systemName: recorder.isRecording ? "waveform.circle.fill" : "waveform")
        }
    }
}

/// 菜单栏驻留：状态 + 录音开关 + 模拟会议 + 外观 + 退出（还原设计稿的菜单栏 popover）。
struct MenuBarContent: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var rec: RecordingController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine).font(.caption)

        Divider()

        Button(rec.isRecording ? "停止录音" : "立即开始录音") {
            activate()
            rec.isRecording ? rec.stopAndIngest() : (rec.isIdle ? rec.startRecording() : ())
        }
        .disabled(rec.isProcessing)

        Button("打开 Resound 窗口") { activate() }

        Divider()

        Button(app.isDark ? "切换到浅色" : "切换到深色") { app.toggleTheme() }
        Button("退出 Resound") { NSApp.terminate(nil) }
    }

    private var statusLine: String {
        if rec.isRecording { return "录音中 · \(mmss(Double(rec.recSeconds)))" }
        if rec.isProcessing { return "处理中…" }
        return "空闲 · 监听中"
    }

    private func activate() {
        NSApp.setActivationPolicy(.regular)   // 从菜单栏态恢复 Dock
        NSApp.activate(ignoringOtherApps: true)
        // 已有可见主窗 → 前置；否则(被关闭)重新打开
        if let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

/// 菜单栏型 App：关掉主窗口不退出、并从 Dock 隐藏(只剩菜单栏图标)；重开窗口时恢复 Dock。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowWillClose(_ note: Notification) {
        // 关的是主内容窗(非浮动 panel/菜单)；关后若无可见主窗 → 退出 Dock(accessory)
        DispatchQueue.main.async {
            let hasMainWindow = NSApp.windows.contains { $0.canBecomeMain && $0.isVisible }
            if !hasMainWindow { NSApp.setActivationPolicy(.accessory) }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(recenter(_:)), name: NSWindow.didResizeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(recenter(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
    }
    @objc private func recenter(_ note: Notification) {
        if let w = note.object as? NSWindow { centerTrafficLights(w) }
    }
}

/// 把红黄绿交通灯垂直居中到自绘的 46px 标题栏中（标准位置偏上）。
func centerTrafficLights(_ window: NSWindow, barHeight: CGFloat = 46) {
    for t: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
        guard let b = window.standardWindowButton(t), let sv = b.superview else { continue }
        var f = b.frame
        f.origin.y = sv.bounds.height - barHeight / 2 - f.height / 2   // 距窗顶 barHeight/2 居中
        b.setFrameOrigin(f.origin)
    }
}

/// 缩放（撑满/还原）当前主窗口 —— 标题栏双击行为。
func zoomMainWindow() { (NSApp.keyWindow ?? NSApp.mainWindow)?.zoom(nil) }

/// 配置承载窗口：透明标题栏、背景色随主题、可拖拽；窗口出现即恢复 Dock(regular)。
struct WindowConfigurator: NSViewRepresentable {
    var isDark: Bool
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }
    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // 只让自绘标题栏(TitlebarDragArea)能拖窗——内容区不再跟着整窗跑。
        window.isMovableByWindowBackground = false
        window.backgroundColor = NSColor(Palette.make(dark: isDark).bg)
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        centerTrafficLights(window)
    }
}

func mmss(_ s: Double) -> String {
    let t = max(0, Int(s.rounded())); return String(format: "%d:%02d", t / 60, t % 60)
}
