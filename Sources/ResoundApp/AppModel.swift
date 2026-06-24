import SwiftUI
import Combine

/// App 级状态：导航 / 主题 / 全局 toast / 录音库刷新令牌。录音引擎在 [RecordingController]。
@MainActor
final class AppModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable { case ask, library, templates, settings; var id: String { rawValue } }

    @Published var page: Page = .ask
    @Published var isDark: Bool { didSet { UserDefaults.standard.set(isDark, forKey: Self.themeKey) } }
    @Published var sidebarCollapsed: Bool { didSet { UserDefaults.standard.set(sidebarCollapsed, forKey: Self.sidebarKey) } }
    @Published var toastText: String?
    /// 录音/导入完成后自增，触发录音库重新加载。
    @Published var libraryReloadToken = 0

    private static let themeKey = "resound.theme.dark"
    private static let sidebarKey = "resound.sidebar.collapsed"
    private var toastTask: Task<Void, Never>?

    init() {
        isDark = UserDefaults.standard.bool(forKey: Self.themeKey)
        sidebarCollapsed = UserDefaults.standard.bool(forKey: Self.sidebarKey)
    }

    var palette: Palette { .make(dark: isDark) }

    func toggleTheme() { withAnimation(.easeInOut(duration: 0.18)) { isDark.toggle() } }
    func toggleSidebar() { withAnimation(.easeInOut(duration: 0.2)) { sidebarCollapsed.toggle() } }

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
