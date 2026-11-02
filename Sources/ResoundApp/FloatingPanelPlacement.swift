import AppKit

/// Screen placement shared by the floating panels (recording badge, meeting popup).
/// Borderless panels are not pulled back on-screen by AppKit when a display is unplugged
/// or rearranged, so every show / screen change must re-validate the frame explicitly.
@MainActor
enum FloatingPanelPlacement {
    /// The screen the user is most likely looking at: the one under the mouse cursor,
    /// falling back to NSScreen.main (which for a background app can be a display the user isn't using).
    static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// True when at least half of the frame lies inside some screen's visible area.
    static func isOnScreen(_ frame: NSRect) -> Bool {
        let area = frame.width * frame.height
        guard area > 0 else { return false }
        return NSScreen.screens.contains { screen in
            let r = screen.visibleFrame.intersection(frame)
            return !r.isNull && r.width * r.height >= area * 0.5
        }
    }

    /// Pins the panel to the top-right corner of the target screen's visible area.
    static func placeTopRight(_ panel: NSPanel) {
        guard let screen = targetScreen() else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width, y: vf.maxY - size.height))
    }
}
