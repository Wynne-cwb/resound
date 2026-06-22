import SwiftUI
import AppKit
import Combine

/// 屏幕级会议检测弹窗：独立浮动 NSPanel,贴屏幕右上角,跨 Space/全屏可见,
/// 即使主窗口最小化/关闭(App 仍在菜单栏后台运行)也能弹出。
@MainActor
final class MeetingPanelController {
    static let shared = MeetingPanelController()

    private var panel: NSPanel?
    private var recorder: RecordingController?
    private var app: AppModel?
    private var cancellables = Set<AnyCancellable>()
    private var configured = false

    /// 在 App 启动后调用一次（idempotent）；订阅活在单例里,不随窗口销毁。
    func configure(recorder: RecordingController, app: AppModel) {
        guard !configured else { return }
        configured = true
        self.recorder = recorder
        self.app = app
        recorder.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                if case .meetingDetected = phase { self?.show() } else { self?.hide() }
            }
            .store(in: &cancellables)
        // 主题切换时若正显示则重建样式
        app.$isDark
            .dropFirst()
            .sink { [weak self] _ in if self?.panel?.isVisible == true { self?.rebuildContent() } }
            .store(in: &cancellables)
    }

    private func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        rebuildContent()
        reposition()
        panel.orderFrontRegardless()
    }

    private func hide() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        return p
    }

    private func rebuildContent() {
        guard let panel, let recorder, let app else { return }
        let card = MeetingPopupCard(
            pal: .make(dark: app.isDark),
            subtitle: recorder.meetingTitle ?? "现在开始录音吗？",
            onStart: { [weak recorder] in recorder?.startRecording() },
            onDismiss: { [weak recorder] in recorder?.ignorePrompt() })
            .fixedSize()
            .padding(.init(top: 14, leading: 14, bottom: 14, trailing: 14))   // 扁平无阴影,仅留屏幕边距
        let host = NSHostingView(rootView: card)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.contentView = host
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        // panel 含 24pt 透明留白；贴右上角(留白即视觉边距 ~24)
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width, y: vf.maxY - size.height))
    }
}

/// 弹窗卡片（屏幕级浮窗与窗口内复用同一外观）。
struct MeetingPopupCard: View {
    let pal: Palette
    var subtitle: String = "现在开始录音吗？"
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 13) {
                SidebarLogo(pal: pal, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("会议已开始").font(.system(size: 16, weight: .bold)).foregroundStyle(pal.text)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(pal.text2).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "bell").font(.system(size: 15, weight: .regular)).foregroundStyle(pal.text3)
            }
            HStack(spacing: 10) {
                Button(action: onDismiss) {
                    Text("取消").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(pal.text)
                        .frame(width: 100, height: 40)
                        .background(pal.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).stroke(pal.borderStrong, corner: 10)
                }.buttonStyle(.plainHit).hoverCursor()
                Button(action: onStart) {
                    Text("开始录音").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(pal.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }.buttonStyle(.plainHit).hoverCursor()
            }
        }
        .padding(18).frame(width: 320)
        .background(pal.elev, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .stroke(pal.borderStrong, corner: 16)
    }
}
