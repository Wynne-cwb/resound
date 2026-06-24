import SwiftUI
import Combine

/// App 级状态：导航 / 主题 / 全局 toast / 录音库刷新令牌。录音引擎在 [RecordingController]。
@MainActor
final class AppModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable { case ask, library, templates, settings; var id: String { rawValue } }

    @Published var page: Page = .ask
    @Published var isDark: Bool { didSet { UserDefaults.standard.set(isDark, forKey: Self.themeKey); palette = .make(dark: isDark) } }
    @Published var sidebarCollapsed: Bool { didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: Self.sidebarKey) } }
    /// 缓存调色板：仅主题切换时重建。避免每次 RootView.body（侧栏动画/toast/切页时高频重算）现造新实例。
    @Published private(set) var palette: Palette = .make(dark: false)
    @Published var toastText: String?
    /// 录音/导入完成后自增，触发录音库重新加载。
    @Published var libraryReloadToken = 0
    /// 首启引导门禁：未配齐 chat+embedding 时全屏引导，配好验证通过才进主界面。
    @Published var showOnboarding = false

    private static let themeKey = "resound.theme.dark"
    private static let sidebarKey = "resound.sidebar.collapsed"
    private var toastTask: Task<Void, Never>?

    init() {
        let dark = UserDefaults.standard.bool(forKey: Self.themeKey)
        isDark = dark
        sidebarCollapsed = UserDefaults.standard.bool(forKey: Self.sidebarKey)
        palette = .make(dark: dark)   // didSet 在 init 期不触发，显式初始化
    }

    func toggleTheme() { withAnimation(.easeInOut(duration: 0.18)) { isDark.toggle() } }
    // 不用 withAnimation：动画会让内容区宽度逐帧变化 → MarkdownUI 每帧在主线程重排长文档（实测单次排版
    // 可达数百 ms~1s）→ 折叠期持续卡顿。瞬时切换 = 宽度一步到位 = 只排版一次。
    func toggleSidebar() { sidebarCollapsed.toggle() }

    func toast(_ msg: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { toastText = msg }
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            await MainActor.run { withAnimation { self?.toastText = nil } }
        }
    }

    func reloadLibrary() { libraryReloadToken &+= 1 }
}
