import SwiftUI
import AppKit
import Combine

/// 录音浮窗：录音期间在屏幕上常驻的一颗可拖动小药丸——脉冲红点 + 计时 + 停止按钮。
/// 与 MeetingPanel 同构：独立浮动 NSPanel，跨 Space/全屏可见，主窗口最小化/关闭(App 仍在菜单栏后台)也照常显示。
/// 受「设置 › 通用 › 录音浮窗」开关控制；可拖到屏幕任意位置，位置自动记忆。
@MainActor
final class RecBadgePanelController {
    static let shared = RecBadgePanelController()

    /// 与 SettingsModel 共用此键：SettingsModel 写、这里读，始终取最新值。默认开。
    static let recBadgeKey = "resound.toggle.recbadge"
    /// 开关在录音中被切换时发出，触发浮窗即时显示/隐藏。
    static let toggleChanged = Notification.Name("resound.recBadge.toggleChanged")

    private var panel: NSPanel?
    private var recorder: RecordingController?
    private var app: AppModel?
    private var cancellables = Set<AnyCancellable>()
    private var configured = false
    private var positioned = false
    private static let frameKey = "resound.recBadge.frame.v2"

    /// App 启动后调用一次（idempotent）；订阅活在单例里，不随窗口销毁。
    func configure(recorder: RecordingController, app: AppModel) {
        guard !configured else { return }
        configured = true
        self.recorder = recorder
        self.app = app
        // 录音开始/结束都靠 phase 驱动显隐。
        recorder.$phase.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 录音中切换「录音浮窗」开关 → 即时显隐。
        NotificationCenter.default.publisher(for: Self.toggleChanged).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        // 主题切换时若正显示则重建内容（沿用最新调色板）。
        app.$isDark.dropFirst()
            .sink { [weak self] _ in if self?.panel?.isVisible == true { self?.rebuildContent() } }
            .store(in: &cancellables)
    }

    private var badgeEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.recBadgeKey) as? Bool ?? true
    }

    /// 录音中且开关开 → 显示；否则隐藏。
    private func refresh() {
        guard let recorder else { return }
        if recorder.isRecording && badgeEnabled { show() } else { hide() }
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        rebuildContent()                 // 先定好最终尺寸（setContentSize 会移动原点）
        if !positioned {                 // 首次：恢复上次记忆位置，否则落底部居中
            positioned = true
            if !panel.setFrameUsingName(Self.frameKey) { placeDefault(panel) }
            panel.setFrameAutosaveName(Self.frameKey)   // 之后拖动自动记忆
        }
        panel.orderFrontRegardless()
    }

    private func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = true   // 药丸主体即拖拽区；停止按钮自己吃掉点击，不触发拖窗
        p.hidesOnDeactivate = false
        return p
    }

    private func rebuildContent() {
        guard let panel, let recorder, let app else { return }
        let card = RecBadgeCard(rec: recorder, pal: .make(dark: app.isDark),
                                onStop: { [weak recorder] in recorder?.stopAndIngest() })
            .fixedSize()
            .padding(14)   // 透明留白：给药丸阴影留出空间，不被 panel 边缘裁切
        let host = NSHostingView(rootView: card)
        host.layoutSubtreeIfNeeded()
        panel.setContentSize(host.fittingSize)
        panel.contentView = host
    }

    /// 无记忆位置时（首次）贴主屏右上角（含 14pt 透明留白即视觉边距；visibleFrame 已排除菜单栏）。
    private func placeDefault(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width, y: vf.maxY - size.height))
    }
}

/// 录音浮窗药丸：脉冲红点 + 实时计时 + 停止方钮。计时靠 @ObservedObject 自动刷新，浮窗本身不重建。
struct RecBadgeCard: View {
    @ObservedObject var rec: RecordingController
    let pal: Palette
    let onStop: () -> Void
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(pal.rec).frame(width: 9, height: 9)
                .opacity(pulse ? 0.3 : 1).scaleEffect(pulse ? 0.8 : 1)
            Text(mmss(Double(rec.recSeconds)))
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(pal.text)
            Button(action: onStop) {
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(.white)
                    .frame(width: 8, height: 8)
                    .frame(width: 24, height: 24)
                    .background(pal.rec, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plainHit).hoverCursor().help("停止录音")
        }
        .padding(.init(top: 6, leading: 13, bottom: 6, trailing: 7))
        .background(pal.elev, in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(pal.borderStrong, lineWidth: 1))
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}
