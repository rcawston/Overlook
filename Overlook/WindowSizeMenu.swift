import AppKit
import Combine
import SwiftUI

/// One entry of Window → Window Size.
///
/// Sizes are relative to the video resolution: at 1× one video pixel maps to one backing
/// pixel of the window's display. They only change the local window size; the remote
/// resolution is never touched.
struct WindowSizePreset: Identifiable, Equatable {
    static let scales: [CGFloat] = [0.25, 0.5, 0.75, 1, 1.5, 2]

    /// Smallest video area offered, in points. Smaller presets are disabled.
    static let minimumVideoAreaSize = NSSize(width: 160, height: 90)

    let scale: CGFloat
    /// Size of the video area in backing pixels of the window's display.
    let pixelSize: NSSize
    /// Size of the video area in points. The window chrome comes on top.
    let pointSize: NSSize
    let isEnabled: Bool
    /// The window's video area currently has this size.
    let isCurrent: Bool

    var id: CGFloat { scale }

    var title: String {
        let factor = scale == 1 ? "1× (1:1 pixels)" : String(format: "%g×", Double(scale))
        return "\(factor) — \(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }
}

/// Computes and applies the Window → Window Size presets for one window.
///
/// The presets are recomputed whenever something they depend on changes: the video
/// resolution, the window size, the window's display (backing scale, visible frame) and
/// full screen. The menu is unavailable without a video size and while in full screen.
@MainActor
final class WindowSizeController: ObservableObject {
    @Published private(set) var presets: [WindowSizePreset] = []

    var isAvailable: Bool {
        !presets.isEmpty
    }

    private weak var window: NSWindow?
    private var videoSize: CGSize?
    private var observers: Set<AnyCancellable> = []

    func attach(to window: NSWindow?) {
        guard window !== self.window else { return }
        self.window = window
        observers.removeAll()

        if let window {
            let center = NotificationCenter.default
            let refreshingNotifications: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didChangeBackingPropertiesNotification,
                NSWindow.willEnterFullScreenNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.willExitFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
            ]
            for name in refreshingNotifications {
                center.publisher(for: name, object: window)
                    .sink { [weak self] _ in self?.refresh() }
                    .store(in: &observers)
            }

            // Chrome and minimum size changes alter the presets without resizing the window.
            window.publisher(for: \.styleMask)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &observers)
            window.publisher(for: \.titlebarAppearsTransparent)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &observers)
            window.publisher(for: \.minSize)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &observers)
            window.publisher(for: \.contentMinSize)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &observers)

            // Display arrangement, resolution or Dock/menu bar changes alter the visible frame.
            center.publisher(for: NSApplication.didChangeScreenParametersNotification)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &observers)
        }

        refresh()
    }

    func setVideoSize(_ size: CGSize?) {
        guard size != videoSize else { return }
        videoSize = size
        refresh()
    }

    /// Resizes the window so its video area matches the preset, keeping the top-left corner.
    func apply(scale: CGFloat) {
        refresh()
        guard let window,
              let preset = presets.first(where: { $0.scale == scale }),
              preset.isEnabled else { return }

        let frame = window.frame
        let videoArea = Self.videoAreaSize(of: window)
        let size = NSSize(
            width: preset.pointSize.width + frame.width - videoArea.width,
            height: preset.pointSize.height + frame.height - videoArea.height
        )
        var newFrame = NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height)

        // The size fits the visible frame; only move the window if it would stick out of it.
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            newFrame.origin.x = min(max(newFrame.minX, visible.minX), visible.maxX - newFrame.width)
            newFrame.origin.y = min(max(newFrame.minY, visible.minY), visible.maxY - newFrame.height)
        }

        window.setFrame(newFrame, display: true, animate: true)
    }

    private func refresh() {
        let updated = computePresets()
        if updated != presets {
            presets = updated
        }
    }

    private func computePresets() -> [WindowSizePreset] {
        guard let window,
              let videoSize,
              videoSize.width > 0,
              videoSize.height > 0,
              window.styleMask.contains(.fullScreen) == false,
              let screen = window.screen ?? NSScreen.main else { return [] }

        let backingScale = screen.backingScaleFactor
        guard backingScale > 0 else { return [] }

        let frame = window.frame
        let videoArea = Self.videoAreaSize(of: window)
        let chrome = NSSize(width: frame.width - videoArea.width, height: frame.height - videoArea.height)

        // Disable sizes the window would refuse instead of letting AppKit clamp them.
        let contentArea = window.contentRect(forFrameRect: frame).size
        let minimumVideoArea = NSSize(
            width: max(
                WindowSizePreset.minimumVideoAreaSize.width,
                window.minSize.width - chrome.width,
                window.contentMinSize.width - (contentArea.width - videoArea.width)
            ),
            height: max(
                WindowSizePreset.minimumVideoAreaSize.height,
                window.minSize.height - chrome.height,
                window.contentMinSize.height - (contentArea.height - videoArea.height)
            )
        )
        let available = screen.visibleFrame.size

        return WindowSizePreset.scales.map { scale in
            let pixelSize = NSSize(
                width: (videoSize.width * scale).rounded(),
                height: (videoSize.height * scale).rounded()
            )
            let pointSize = NSSize(width: pixelSize.width / backingScale, height: pixelSize.height / backingScale)

            let fitsScreen = pointSize.width + chrome.width <= available.width
                && pointSize.height + chrome.height <= available.height
            let isLargeEnough = pointSize.width >= minimumVideoArea.width
                && pointSize.height >= minimumVideoArea.height
            let isCurrent = abs(videoArea.width - pointSize.width) <= 1
                && abs(videoArea.height - pointSize.height) <= 1

            return WindowSizePreset(
                scale: scale,
                pixelSize: pixelSize,
                pointSize: pointSize,
                isEnabled: fitsScreen && isLargeEnough,
                isCurrent: isCurrent
            )
        }
    }

    /// The part of the window used by the video. Normally the content layout rect, below the
    /// title bar and toolbar. When the content extends under a transparent title bar, as in a
    /// chrome-less window, the video uses the whole window.
    private static func videoAreaSize(of window: NSWindow) -> NSSize {
        let videoCoversTitleBar = window.styleMask.contains(.fullSizeContentView) && window.titlebarAppearsTransparent
        return videoCoversTitleBar ? window.frame.size : window.contentLayoutRect.size
    }
}

/// Attaches a `WindowSizeController` to the window that hosts this view.
struct WindowSizeControllerAttacher: NSViewRepresentable {
    let controller: WindowSizeController

    func makeNSView(context: Context) -> NSView {
        let view = WindowChangeObservingView(frame: .zero)
        view.onWindowChange = { [weak controller] window in
            controller?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowChangeObservingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

struct WindowSizeCommands: Commands {
    @FocusedObject private var controller: WindowSizeController?

    var body: some Commands {
        CommandGroup(after: .windowSize) {
            if let controller, controller.isAvailable {
                Menu("Window Size") {
                    ForEach(controller.presets) { preset in
                        Toggle(preset.title, isOn: Binding(
                            get: { preset.isCurrent },
                            set: { _ in controller.apply(scale: preset.scale) }
                        ))
                        .disabled(!preset.isEnabled)
                    }
                }
            } else {
                // Menus with a submenu ignore .disabled, so show a disabled plain item instead.
                Button("Window Size") {}
                    .disabled(true)
            }
        }
    }
}
