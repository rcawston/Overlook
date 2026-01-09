import SwiftUI
import AppKit
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(WebRTC)
import WebRTC
#endif

struct VideoSurfaceView: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var ocrManager: OCRManager

    @Binding var isOCRModeEnabled: Bool
    @Binding var selectedText: String
    @Binding var isShowingOCRResult: Bool

    let onReconnect: () -> Void

    @State private var ocrDragStart: CGPoint?
    @State private var ocrDragCurrent: CGPoint?
    @State private var ocrRegionsTask: Task<Void, Never>?

    private var ocrSelectionRect: CGRect? {
        guard let start = ocrDragStart, let current = ocrDragCurrent else { return nil }
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let width = abs(start.x - current.x)
        let height = abs(start.y - current.y)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

#if canImport(WebRTC)
                if let videoView = webRTCManager.videoView {
                    VideoViewRepresentable(
                        videoView: videoView,
                        onMouseMove: { pointInView in
                            guard !isOCRModeEnabled else { return }
                            inputManager.handleVideoMouseMove(
                                pointInView: pointInView,
                                viewSize: geometry.size,
                                videoSize: currentVideoSize()
                            )
                        },
                        onMouseButton: { button, isDown, pointInView in
                            guard !isOCRModeEnabled else { return }
                            inputManager.handleVideoMouseButton(
                                button: button,
                                isDown: isDown,
                                pointInView: pointInView,
                                viewSize: geometry.size,
                                videoSize: currentVideoSize()
                            )
                        },
                        onScrollWheel: { deltaX, deltaY in
                            guard !isOCRModeEnabled else { return }
                            inputManager.handleVideoMouseScroll(deltaX: deltaX, deltaY: deltaY)
                        }
                    )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Text("No Video Stream")
                        .foregroundColor(.white)
                }
#else
                Text("WebRTC not installed")
                    .foregroundColor(.white)
#endif

                if isOCRModeEnabled {
                    OCRSelectionOverlay(
                        regions: ocrManager.recognizedRegions,
                        selectionRectInView: ocrSelectionRect,
                        viewSize: geometry.size,
                        videoSize: currentVideoSize()
                    )
                }

                if isOCRModeEnabled {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if ocrDragStart == nil {
                                        ocrDragStart = value.startLocation
                                    }
                                    ocrDragCurrent = value.location
                                }
                                .onEnded { value in
                                    let location = value.location
                                    let start = ocrDragStart ?? value.startLocation
                                    let dx = location.x - start.x
                                    let dy = location.y - start.y
                                    let distance = hypot(dx, dy)

                                    if distance < 8 {
                                        performOCR(at: location, in: geometry)
                                    } else if let rect = ocrSelectionRect, rect.width > 4, rect.height > 4 {
                                        performOCR(inViewRect: rect, in: geometry)
                                    }

                                    ocrDragStart = nil
                                    ocrDragCurrent = nil
                                }
                        )
                }

                if webRTCManager.isConnecting || webRTCManager.isStreamStalled || (webRTCManager.hasEverConnectedToStream && !webRTCManager.isConnected) {
                    VStack(spacing: 10) {
                        Text(webRTCManager.isConnecting ? "Connecting…" : "Connection Lost")
                            .font(.headline)

                        if let reason = webRTCManager.lastDisconnectReason, !reason.isEmpty {
                            Text(reason)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }

                        if let age = webRTCManager.lastVideoFrameAgeSeconds, webRTCManager.isConnecting == false {
                            Text("Last video frame: \(age)s ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Button("Reconnect") {
                            onReconnect()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(webRTCManager.isConnecting)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                }
            }
        }
        .onChange(of: isOCRModeEnabled) { _, enabled in
            setOCRMode(enabled)
        }
        .onAppear {
            setOCRMode(isOCRModeEnabled)
        }
        .onDisappear {
            ocrRegionsTask?.cancel()
            ocrRegionsTask = nil
        }
    }

    private func setOCRMode(_ enabled: Bool) {
        webRTCManager.setFrameCaptureEnabled(enabled)
        if enabled {
            ocrRegionsTask?.cancel()
            ocrRegionsTask = Task { @MainActor in
                while !Task.isCancelled && isOCRModeEnabled {
                    _ = try? await ocrManager.detectTextRegions(in: webRTCManager.currentFrame)
                    try? await Task.sleep(nanoseconds: 650_000_000)
                }
            }
        } else {
            ocrRegionsTask?.cancel()
            ocrRegionsTask = nil
            ocrDragStart = nil
            ocrDragCurrent = nil
            ocrManager.recognizedRegions = []
        }
    }

    private func currentVideoSize() -> CGSize? {
        if let size = webRTCManager.videoSize, size.width > 0, size.height > 0 {
            return size
        }

        guard let pixelBuffer = webRTCManager.currentFrame else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if width <= 0 || height <= 0 {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private func performOCR(at location: CGPoint, in geometry: GeometryProxy) {
        let normalized = inputManager.normalizePointInViewToVideo(
            pointInView: location,
            viewSize: geometry.size,
            videoSize: currentVideoSize()
        )
        let videoPoint = CGPoint(x: normalized.x, y: 1.0 - normalized.y)

        Task {
            do {
                let text = try await ocrManager.recognizeText(at: videoPoint, in: webRTCManager.currentFrame)
                await MainActor.run {
                    selectedText = text
                    isShowingOCRResult = true
                }
            } catch {
                print("OCR failed: \(error)")
            }
        }
    }

    private func performOCR(inViewRect rect: CGRect, in geometry: GeometryProxy) {
        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)

        let n1 = inputManager.normalizePointInViewToVideo(
            pointInView: topLeft,
            viewSize: geometry.size,
            videoSize: currentVideoSize()
        )

        let n2 = inputManager.normalizePointInViewToVideo(
            pointInView: bottomRight,
            viewSize: geometry.size,
            videoSize: currentVideoSize()
        )

        let v1 = CGPoint(x: n1.x, y: 1.0 - n1.y)
        let v2 = CGPoint(x: n2.x, y: 1.0 - n2.y)

        let minX = max(0, min(v1.x, v2.x))
        let minY = max(0, min(v1.y, v2.y))
        let maxX = min(1, max(v1.x, v2.x))
        let maxY = min(1, max(v1.y, v2.y))

        let region = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
        guard region.width > 0.001, region.height > 0.001 else { return }

        Task {
            do {
                let text = try await ocrManager.recognizeTextInRegion(region, in: webRTCManager.currentFrame)
                await MainActor.run {
                    selectedText = text
                    isShowingOCRResult = true
                }
            } catch {
                print("OCR failed: \(error)")
            }
        }
    }
}

#if canImport(WebRTC)
struct VideoViewRepresentable: NSViewRepresentable {
    let videoView: RTCMTLNSVideoView
    let onMouseMove: (CGPoint) -> Void
    let onMouseButton: (MouseButton, Bool, CGPoint) -> Void
    let onScrollWheel: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> TrackingContainerView {
        let container = TrackingContainerView()
        container.onMouseMove = onMouseMove
        container.onMouseButton = onMouseButton
        container.onScrollWheel = onScrollWheel
        container.embedVideoView(videoView)
        return container
    }

    func updateNSView(_ nsView: TrackingContainerView, context: Context) {
        nsView.onMouseMove = onMouseMove
        nsView.onMouseButton = onMouseButton
        nsView.onScrollWheel = onScrollWheel
        nsView.embedVideoView(videoView)
    }
}

final class TrackingContainerView: NSView {
    var onMouseMove: ((CGPoint) -> Void)?
    var onMouseButton: ((MouseButton, Bool, CGPoint) -> Void)?
    var onScrollWheel: ((CGFloat, CGFloat) -> Void)?

    private var trackingAreaRef: NSTrackingArea?
    private var lastMoveTimestamp: TimeInterval = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .inVisibleRect,
            .mouseMoved,
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }

    func embedVideoView(_ videoView: RTCMTLNSVideoView) {
        if videoView.superview !== self {
            videoView.removeFromSuperview()
            addSubview(videoView)
        }
        videoView.frame = bounds
        videoView.autoresizingMask = [.width, .height]
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)

        let minInterval = 1.0 / 120.0
        let ts = event.timestamp
        if ts - lastMoveTimestamp < minInterval {
            return
        }
        lastMoveTimestamp = ts

        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseMove?(flipped)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.left, true, flipped)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.left, false, flipped)
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.right, true, flipped)
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.right, false, flipped)
    }

    override func otherMouseDown(with event: NSEvent) {
        super.otherMouseDown(with: event)
        guard event.buttonNumber == 2 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.middle, true, flipped)
    }

    override func otherMouseUp(with event: NSEvent) {
        super.otherMouseUp(with: event)
        guard event.buttonNumber == 2 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseButton?(.middle, false, flipped)
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseMove?(flipped)
    }

    override func rightMouseDragged(with event: NSEvent) {
        super.rightMouseDragged(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let flipped = CGPoint(x: p.x, y: bounds.height - p.y)
        onMouseMove?(flipped)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        onScrollWheel?(event.scrollingDeltaX, event.scrollingDeltaY)
    }
}
#endif
