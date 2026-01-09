import SwiftUI
import Foundation
import AppKit

struct ContentView: View {
    @EnvironmentObject var webRTCManager: WebRTCManager
    @EnvironmentObject var inputManager: InputManager
    @EnvironmentObject var ocrManager: OCRManager
    @EnvironmentObject var kvmDeviceManager: KVMDeviceManager
    
    @State private var selectedDevice: KVMDevice?
    @State private var isConnected = false
    @State private var isOCRModeEnabled = false
    @State private var isShowingOCRResult = false
    @State private var showingSettings = false
    @State private var selectedText = ""

    @State private var showingManualConnect = false
    @State private var manualHostPort = ""
    @State private var manualPort = "443"

    @State private var manualPassword = ""

    @State private var showingPasswordPrompt = false
    @State private var pendingPasswordDevice: KVMDevice?
    @State private var pendingPassword = ""

    @State private var suppressDeviceAutoConnect = false

    @State private var showingConnections = false
    @State private var didAutoOpenConnections = false

    @State private var pausedCaptureKeyboardWasEnabled: Bool?
    @State private var pausedCaptureMouseWasEnabled: Bool?
    @State private var isInputCapturePausedForUI: Bool = false

    @State private var windowRef: NSWindow?

    @State private var isFullscreen: Bool = false
    @State private var showFullscreenControls: Bool = false
    @State private var fullscreenHoverTask: Task<Void, Never>?

    @AppStorage("overlook.appAppearance") private var appAppearance: String = "system"

    private var preferredColorScheme: ColorScheme? {
        switch appAppearance {
        case "light":
            return .light
        case "dark":
            return .dark
        default:
            return nil
        }
    }

    private var windowTitle: String {
        let device = kvmDeviceManager.connectedDevice

        let deviceLabel: String
        if let device {
            if device.type == .glinetComet {
                deviceLabel = "GLKVM"
            } else {
                deviceLabel = device.type.displayName
            }
        } else {
            deviceLabel = "Overlook"
        }

        let connectionState: String
        if device == nil || isConnected == false {
            connectionState = "Disconnected"
        } else {
            connectionState = "Connected"
        }

        let resolution: String
        if let size = webRTCManager.videoSize {
            resolution = "\(Int(size.width))x\(Int(size.height))"
        } else {
            resolution = "—"
        }

        let kbps: String
        if let value = webRTCManager.inboundVideoKbps {
            kbps = "\(value) kbps"
        } else {
            kbps = "— kbps"
        }

        let fps: String
        if let value = webRTCManager.inboundFps {
            fps = "\(Int(value.rounded())) fps dynamic"
        } else {
            fps = "— fps dynamic"
        }

        return "Overlook - \(deviceLabel) / \(connectionState) / \(resolution) / \(kbps) / \(fps)"
    }

    private func applyAppAppearance() {
        switch appAppearance {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }
    
    var body: some View {
        ZStack(alignment: .trailing) {
            if isFullscreen {
                VideoSurfaceView(
                    isOCRModeEnabled: $isOCRModeEnabled,
                    selectedText: $selectedText,
                    isShowingOCRResult: $isShowingOCRResult,
                    onReconnect: {
                        guard let device = kvmDeviceManager.connectedDevice else { return }
                        Task { @MainActor in
                            await webRTCManager.reconnect(to: device)
                        }
                    }
                )
                .ignoresSafeArea()
                .allowsHitTesting(!showingSettings)
            } else {
                VideoSurfaceView(
                    isOCRModeEnabled: $isOCRModeEnabled,
                    selectedText: $selectedText,
                    isShowingOCRResult: $isShowingOCRResult,
                    onReconnect: {
                        guard let device = kvmDeviceManager.connectedDevice else { return }
                        Task { @MainActor in
                            await webRTCManager.reconnect(to: device)
                        }
                    }
                )
                .allowsHitTesting(!showingSettings)
            }

            if isFullscreen && !showingSettings && !showingConnections {
                VStack(spacing: 0) {
                    Color.clear
                        .frame(height: 28)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            fullscreenHoverTask?.cancel()
                            if hovering {
                                fullscreenHoverTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 350_000_000)
                                    if isFullscreen {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            showFullscreenControls = true
                                        }
                                    }
                                }
                            } else {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showFullscreenControls = false
                                }
                            }
                        }

                    if showFullscreenControls {
                        HStack(spacing: 10) {
                            Button(action: { showingConnections.toggle() }) {
                                Image(systemName: "personalhotspot")
                            }
                            .help("Connections")

                            Button(action: { fitWindowToGuest() }) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .disabled(webRTCManager.videoSize == nil)
                            .help("Fit window to guest")

                            Button(action: { toggleOCR() }) {
                                Image(systemName: isOCRModeEnabled ? "text.viewfinder" : "doc.text")
                            }
                            .disabled(!isConnected)
                            .help(isOCRModeEnabled ? "Disable OCR Selection" : "Enable OCR Selection")

                            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showingSettings.toggle() } }) {
                                Image(systemName: "gearshape")
                            }
                            .disabled(!isConnected)
                            .help("Settings")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.top, 6)
                        .padding(.leading, 12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .transition(.opacity)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showingSettings || showingConnections {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingSettings = false
                            showingConnections = false
                        }
                    }
            }

            WebUISettingsPanel(isPresented: $showingSettings)
                .frame(width: 360)
                .offset(x: showingSettings ? 0 : 360)
                .animation(Animation.easeInOut(duration: 0.2), value: showingSettings)
                .allowsHitTesting(showingSettings)

            VStack(spacing: 0) {
                ConnectionsPopoverView(
                    selectedDevice: $selectedDevice,
                    isConnected: isConnected,
                    isScanning: kvmDeviceManager.isScanning,
                    devices: kvmDeviceManager.availableDevices,
                    connectedDeviceName: kvmDeviceManager.connectedDevice?.name,
                    latency: webRTCManager.latency,
                    videoSize: webRTCManager.videoSize,
                    inboundVideoKbps: webRTCManager.inboundVideoKbps,
                    inboundFps: webRTCManager.inboundFps,
                    inboundVideoPlayoutDelayMs: webRTCManager.inboundVideoPlayoutDelayMs,
                    inboundVideoJitterMs: webRTCManager.inboundVideoJitterMs,
                    inboundVideoDecodeMs: webRTCManager.inboundVideoDecodeMs,
                    inboundVideoPacketsLost: webRTCManager.inboundVideoPacketsLost,
                    iceCurrentRoundTripTimeMs: webRTCManager.iceCurrentRoundTripTimeMs,
                    onScan: {
                        kvmDeviceManager.scanForDevices()
                    },
                    onManualConnect: {
                        showingManualConnect = true
                    },
                    onToggleConnection: {
                        toggleConnection()
                    },
                    onForgetSelectedDevice: {
                        guard let device = selectedDevice else { return }
                        guard device.id.hasPrefix("saved-") else { return }
                        kvmDeviceManager.forgetDevice(device)
                        selectedDevice = nil
                    }
                )
                .frame(width: 360)
                .background(.ultraThinMaterial)
                .padding(.top, 8)

                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .offset(x: showingConnections ? 0 : 360)
            .animation(.easeInOut(duration: 0.2), value: showingConnections)
            .allowsHitTesting(showingConnections)
        }
        .background(WindowAspectRatioSetter(videoSize: webRTCManager.videoSize))
        .background(WindowTitleSetter(title: windowTitle))
        .background(WindowReferenceSetter(window: $windowRef))
        .preferredColorScheme(preferredColorScheme)
        .onAppear {
            applyAppAppearance()
            inputManager.setup(with: webRTCManager)
            inputManager.setGLKVMClient(kvmDeviceManager.glkvmClient)

            updateInputCaptureForUIOverlays()

            if !didAutoOpenConnections, !isConnected {
                didAutoOpenConnections = true
                showingConnections = true
            }
        }
        .onChange(of: showingSettings) { _, _ in
            updateInputCaptureForUIOverlays()
        }
        .onChange(of: showingConnections) { _, _ in
            updateInputCaptureForUIOverlays()
        }
        .onChange(of: windowRef) { _, newValue in
            isFullscreen = newValue?.styleMask.contains(.fullScreen) ?? false
            showFullscreenControls = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            guard windowRef === window else { return }
            isFullscreen = true
            showFullscreenControls = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            guard let window = note.object as? NSWindow else { return }
            guard windowRef === window else { return }
            isFullscreen = false
            showFullscreenControls = false
        }
        .onReceive(kvmDeviceManager.$glkvmClient) { client in
            inputManager.setGLKVMClient(client)
        }
        .onReceive(kvmDeviceManager.$connectedDevice) { device in
            Task { @MainActor in
                if let device {
                    suppressDeviceAutoConnect = true
                    selectedDevice = device
                    isConnected = true
                    DispatchQueue.main.async {
                        suppressDeviceAutoConnect = false
                    }
                } else {
                    isConnected = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .overlookToggleCopyMode)) { _ in
            Task { @MainActor in
                isOCRModeEnabled.toggle()
            }
        }
        .onChange(of: appAppearance) { _, _ in
            applyAppAppearance()
        }
        .sheet(isPresented: $isShowingOCRResult) {
            OCRResultView(selectedText: $selectedText)
        }
        .sheet(isPresented: $showingManualConnect) {
            ManualConnectSheet(
                isPresented: $showingManualConnect,
                hostPort: $manualHostPort,
                port: $manualPort,
                password: $manualPassword,
                onConnect: {
                    manualConnect()
                }
            )
        }
        .sheet(isPresented: $showingPasswordPrompt) {
            PasswordPromptSheet(
                isPresented: $showingPasswordPrompt,
                password: $pendingPassword,
                onCancel: {
                    pendingPasswordDevice = nil
                    pendingPassword = ""
                },
                onConnect: {
                    if let device = pendingPasswordDevice {
                        connectToDevice(device, password: pendingPassword)
                    }
                    pendingPasswordDevice = nil
                    pendingPassword = ""
                }
            )
        }
        .toolbar {
            if isFullscreen == false {
                ToolbarItemGroup(placement: .automatic) {
                    Button(action: { showingConnections.toggle() }) {
                        Image(systemName: "personalhotspot")
                    }
                    .help("Connections")

                    Button(action: { fitWindowToGuest() }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .disabled(webRTCManager.videoSize == nil)
                    .help("Fit window to guest")

                    Button(action: { toggleOCR() }) {
                        Image(systemName: isOCRModeEnabled ? "text.viewfinder" : "doc.text")
                    }
                    .disabled(!isConnected)
                    .help(isOCRModeEnabled ? "Disable OCR Selection" : "Enable OCR Selection")

                    Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showingSettings.toggle() } }) {
                        Image(systemName: "gearshape")
                    }
                    .disabled(!isConnected)
                    .help("Settings")
                }
            }
        }
    }

    private func connectToDevice(_ device: KVMDevice, password: String? = nil) {
        Task {
            do {
                let connectedDevice = try await kvmDeviceManager.connectToDevice(device, password: password)
                await MainActor.run {
                    suppressDeviceAutoConnect = true
                    selectedDevice = connectedDevice
                    isConnected = true
                    showingConnections = false
                }
                DispatchQueue.main.async {
                    suppressDeviceAutoConnect = false
                }

                if let client = kvmDeviceManager.glkvmClient {
                    await MainActor.run {
                        inputManager.setGLKVMClient(client)
                        inputManager.startFullInputCapture()
                    }
                    try? await client.setHidConnected(true)
                }

 #if canImport(WebRTC)
                do {
                    try await webRTCManager.connect(to: connectedDevice)
                } catch {
                    print("WebRTC connect failed (API is still connected): \(error)")
                }
 #endif
            } catch {
                if let kvmError = error as? KVMError, kvmError == .authenticationFailed {
                    await MainActor.run {
                        pendingPasswordDevice = device
                        showingPasswordPrompt = true
                    }
                } else {
                    print("Failed to connect: \(error)")
                    await MainActor.run {
                        isConnected = false
                    }
                }
                return
            }
        }
    }

    private func manualConnect() {
        let trimmed = manualHostPort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var host = trimmed
        var portString = manualPort.trimmingCharacters(in: .whitespacesAndNewlines)

        if let schemeRange = host.range(of: "://") {
            host = String(host[schemeRange.upperBound...])
        }

        if let colonIndex = host.lastIndex(of: ":") {
            let maybeHost = String(host[..<colonIndex])
            let maybePort = String(host[host.index(after: colonIndex)...])
            if !maybeHost.isEmpty, !maybePort.isEmpty {
                host = maybeHost
                portString = maybePort
            }
        }

        let port = Int(portString) ?? 443
        let device = kvmDeviceManager.addManualDevice(host: host, port: port, type: .glinetComet)

        suppressDeviceAutoConnect = true
        selectedDevice = device
        DispatchQueue.main.async {
            suppressDeviceAutoConnect = false
        }

        let password = manualPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        connectToDevice(device, password: password.isEmpty ? nil : password)
    }

    private func toggleConnection() {
        if isConnected {
            webRTCManager.disconnect()

            let client = kvmDeviceManager.glkvmClient
            Task {
                try? await client?.setHidConnected(false)
            }

            kvmDeviceManager.disconnectFromDevice()
            inputManager.setGLKVMClient(nil)
            inputManager.stopFullInputCapture()
            isConnected = false
            showingConnections = true
        } else if let device = selectedDevice {
            connectToDevice(device)
        }
    }
    
    @MainActor
    private func toggleOCR() {
        isOCRModeEnabled.toggle()
    }

    @MainActor
    private func fitWindowToGuest() {
        guard let videoSize = webRTCManager.videoSize,
              videoSize.width > 0,
              videoSize.height > 0 else { return }
        guard let window = windowRef ?? NSApp.keyWindow else { return }

        let currentFrame = window.frame
        let currentLayout = window.contentLayoutRect

        let deltaW = currentFrame.size.width - currentLayout.size.width
        let deltaH = currentFrame.size.height - currentLayout.size.height

        var desiredLayoutW = CGFloat(videoSize.width)
        var desiredLayoutH = CGFloat(videoSize.height)

        if let screen = window.screen ?? NSScreen.main {
            let maxLayoutW = max(100, screen.visibleFrame.size.width - deltaW)
            let maxLayoutH = max(100, screen.visibleFrame.size.height - deltaH)
            let scale = min(1.0, maxLayoutW / desiredLayoutW, maxLayoutH / desiredLayoutH)
            desiredLayoutW = floor(desiredLayoutW * scale)
            desiredLayoutH = floor(desiredLayoutH * scale)
        }

        var newFrame = currentFrame
        newFrame.size = NSSize(width: desiredLayoutW + deltaW, height: desiredLayoutH + deltaH)
        newFrame.origin.y += currentFrame.size.height - newFrame.size.height
        window.setFrame(newFrame, display: true, animate: true)
    }

    @MainActor
    private func updateInputCaptureForUIOverlays() {
        let overlayOpen = showingSettings || showingConnections

        if overlayOpen {
            if isInputCapturePausedForUI == false {
                pausedCaptureKeyboardWasEnabled = inputManager.isKeyboardCaptureEnabled
                pausedCaptureMouseWasEnabled = inputManager.isMouseCaptureEnabled

                if inputManager.isKeyboardCaptureEnabled {
                    inputManager.stopKeyboardCapture()
                }
                if inputManager.isMouseCaptureEnabled {
                    inputManager.stopMouseCapture()
                }

                isInputCapturePausedForUI = true
            }
            return
        }

        guard isInputCapturePausedForUI else { return }

        if isConnected {
            if let wasKeyboard = pausedCaptureKeyboardWasEnabled {
                if wasKeyboard {
                    inputManager.startKeyboardCapture()
                }
            }
            if let wasMouse = pausedCaptureMouseWasEnabled {
                if wasMouse {
                    inputManager.startMouseCapture()
                }
            }
        }

        pausedCaptureKeyboardWasEnabled = nil
        pausedCaptureMouseWasEnabled = nil
        isInputCapturePausedForUI = false
    }
}

private struct WindowReferenceSetter: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let w = nsView.window else { return }
        if window !== w {
            window = w
        }
    }
}

private struct WindowAspectRatioSetter: NSViewRepresentable {
    let videoSize: CGSize?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }

        if context.coordinator.didConfigureWindow == false {
            context.coordinator.didConfigureWindow = true
            window.titlebarAppearsTransparent = false
            window.styleMask.remove(.fullSizeContentView)
            context.coordinator.attach(to: window)
        }

        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            if context.coordinator.lastAspect != nil {
                context.coordinator.lastAspect = nil
                context.coordinator.didInitialResizeForAspect = false
                context.coordinator.videoAspect = nil
            }
            return
        }

        let aspect = NSSize(width: videoSize.width, height: videoSize.height)
        if let last = context.coordinator.lastAspect {
            let dw = abs(last.width - aspect.width)
            let dh = abs(last.height - aspect.height)
            if dw < 1, dh < 1 {
                return
            }
        }

        context.coordinator.lastAspect = aspect
        context.coordinator.videoAspect = Double(aspect.width / aspect.height)

        if context.coordinator.didInitialResizeForAspect == false {
            context.coordinator.didInitialResizeForAspect = true

            let currentFrame = window.frame
            let currentLayout = window.contentLayoutRect.size
            let deltaH = currentFrame.size.height - currentLayout.height

            if currentLayout.width > 0 {
                let desiredLayoutHeight = currentLayout.width * (aspect.height / aspect.width)
                if desiredLayoutHeight.isFinite, desiredLayoutHeight > 0 {
                    var newFrame = currentFrame
                    newFrame.size.height = desiredLayoutHeight + deltaH
                    window.setFrame(newFrame, display: true)
                }
            }
        }
    }

    final class Coordinator: NSObject {
        var lastAspect: NSSize?
        var didInitialResizeForAspect: Bool = false
        var didConfigureWindow: Bool = false

        weak var window: NSWindow?
        weak var forwardedDelegate: NSWindowDelegate?
        var videoAspect: Double?

        private var storedWindowedTitlebarAppearsTransparent: Bool?
        private var storedWindowedStyleMaskHadFullSizeContentView: Bool?
        private var storedWindowedTitleVisibility: NSWindow.TitleVisibility?
        private var storedWindowedToolbarIsVisible: Bool?

        func attach(to window: NSWindow) {
            if self.window === window {
                return
            }

            self.window = window
            forwardedDelegate = window.delegate
            window.delegate = self

            if storedWindowedTitlebarAppearsTransparent == nil {
                storedWindowedTitlebarAppearsTransparent = window.titlebarAppearsTransparent
                storedWindowedStyleMaskHadFullSizeContentView = window.styleMask.contains(.fullSizeContentView)
                storedWindowedTitleVisibility = window.titleVisibility
                storedWindowedToolbarIsVisible = window.toolbar?.isVisible
            }
        }

        private func applyFullscreenChrome(window: NSWindow) {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.toolbar?.isVisible = false
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .none
            }
        }

        private func restoreWindowedChrome(window: NSWindow) {
            if let stored = storedWindowedTitlebarAppearsTransparent {
                window.titlebarAppearsTransparent = stored
            }
            if let hadFullSize = storedWindowedStyleMaskHadFullSizeContentView {
                if hadFullSize {
                    window.styleMask.insert(.fullSizeContentView)
                } else {
                    window.styleMask.remove(.fullSizeContentView)
                }
            }
            if let stored = storedWindowedTitleVisibility {
                window.titleVisibility = stored
            }
            if let stored = storedWindowedToolbarIsVisible {
                window.toolbar?.isVisible = stored
            }
            if #available(macOS 11.0, *) {
                window.titlebarSeparatorStyle = .automatic
            }
        }

        private func adjustFrameToVideoAspect(window: NSWindow) {
            guard let aspect = videoAspect, aspect.isFinite, aspect > 0 else { return }

            let currentFrame = window.frame
            let currentLayout = window.contentLayoutRect.size

            let deltaW = currentFrame.size.width - currentLayout.width
            let deltaH = currentFrame.size.height - currentLayout.height

            guard currentLayout.width > 0 else { return }

            let desiredLayoutH = currentLayout.width / aspect
            guard desiredLayoutH.isFinite, desiredLayoutH > 0 else { return }

            var newFrame = currentFrame
            newFrame.size.height = desiredLayoutH + deltaH
            newFrame.origin.y += currentFrame.size.height - newFrame.size.height
            window.setFrame(newFrame, display: true, animate: false)
        }
    }
}

extension WindowAspectRatioSetter.Coordinator: NSWindowDelegate {
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        return forwardedDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        forwardedDelegate
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let aspect = videoAspect else { return frameSize }

        let currentFrame = sender.frame.size
        let currentLayout = sender.contentLayoutRect.size

        let deltaW = currentFrame.width - currentLayout.width
        let deltaH = currentFrame.height - currentLayout.height

        let proposedLayoutW = frameSize.width - deltaW
        let proposedLayoutH = frameSize.height - deltaH

        guard proposedLayoutW > 0, proposedLayoutH > 0 else { return frameSize }

        let dw = abs(frameSize.width - currentFrame.width)
        let dh = abs(frameSize.height - currentFrame.height)

        let constrained: NSSize
        if dw >= dh {
            let desiredLayoutH = proposedLayoutW / aspect
            constrained = NSSize(width: frameSize.width, height: desiredLayoutH + deltaH)
        } else {
            let desiredLayoutW = proposedLayoutH * aspect
            constrained = NSSize(width: desiredLayoutW + deltaW, height: frameSize.height)
        }

        if let forwardedDelegate,
           forwardedDelegate.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))) {
            return forwardedDelegate.windowWillResize?(sender, to: constrained) ?? constrained
        }

        return constrained
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            forwardedDelegate?.windowDidEnterFullScreen?(notification)
            return
        }
        applyFullscreenChrome(window: window)
        forwardedDelegate?.windowDidEnterFullScreen?(notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else {
            forwardedDelegate?.windowDidExitFullScreen?(notification)
            return
        }
        restoreWindowedChrome(window: window)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.adjustFrameToVideoAspect(window: window)
        }

        forwardedDelegate?.windowDidExitFullScreen?(notification)
    }
}

private struct WindowTitleSetter: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        if window.title != title {
            window.title = title
        }
        if window.styleMask.contains(.fullScreen) == false {
            window.titleVisibility = .visible
        }
    }
}

struct ConnectionsPopoverView: View {
    @Binding var selectedDevice: KVMDevice?

    let isConnected: Bool
    let isScanning: Bool
    let devices: [KVMDevice]
    let connectedDeviceName: String?
    let latency: Int

    let videoSize: CGSize?
    let inboundVideoKbps: Int?
    let inboundFps: Double?
    let inboundVideoPlayoutDelayMs: Int?
    let inboundVideoJitterMs: Int?
    let inboundVideoDecodeMs: Int?
    let inboundVideoPacketsLost: Int?
    let iceCurrentRoundTripTimeMs: Int?

    let onScan: () -> Void
    let onManualConnect: () -> Void
    let onToggleConnection: () -> Void
    let onForgetSelectedDevice: () -> Void

    var body: some View {
        let resolutionText: String = {
            guard let videoSize, videoSize.width > 0, videoSize.height > 0 else { return "—" }
            return "\(Int(videoSize.width))x\(Int(videoSize.height))"
        }()

        let kbpsText = inboundVideoKbps.map { "\($0) kbps" } ?? "— kbps"
        let fpsText = inboundFps.map { "\(Int($0.rounded())) fps" } ?? "— fps"
        let playoutDelayText = inboundVideoPlayoutDelayMs.map { "\($0) ms" } ?? "—"
        let jitterText = inboundVideoJitterMs.map { "\($0) ms" } ?? "—"
        let decodeText = inboundVideoDecodeMs.map { "\($0) ms" } ?? "—"
        let lossText = inboundVideoPacketsLost.map { String($0) } ?? "—"
        let rttText = iceCurrentRoundTripTimeMs.map { "\($0) ms" } ?? "—"

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connections")
                    .font(.headline)
                Spacer()
                Button(action: onToggleConnection) {
                    Image(systemName: isConnected ? "personalhotspot.slash" : "personalhotspot")
                }
                .disabled(!isConnected && selectedDevice == nil)
                .help(isConnected ? "Disconnect" : "Connect")
            }

            Picker("Device", selection: $selectedDevice) {
                Text("Select Device").tag(nil as KVMDevice?)
                ForEach(devices) { device in
                    Text(device.name).tag(device as KVMDevice?)
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                Button("Scan") { onScan() }
                    .disabled(isScanning)

                Button("Manual Connect…") { onManualConnect() }

                Button("Forget") { onForgetSelectedDevice() }
                    .disabled(isConnected || selectedDevice?.id.hasPrefix("saved-") != true)

                Spacer()

                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(connectedDeviceName ?? (selectedDevice?.name ?? "No Device"))
                    .font(.caption)

                HStack {
                    Text(isConnected ? "Connected" : "Disconnected")
                        .font(.caption)
                        .foregroundColor(isConnected ? .green : .red)

                    Spacer()

                    Text("Latency: \(latency)ms")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WebRTC")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("Video")
                        .font(.caption)
                    Spacer()
                    Text("\(resolutionText) · \(fpsText) · \(kbpsText)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Playout")
                        .font(.caption)
                    Spacer()
                    Text(playoutDelayText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Jitter")
                        .font(.caption)
                    Spacer()
                    Text(jitterText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Decode")
                        .font(.caption)
                    Spacer()
                    Text(decodeText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Lost")
                        .font(.caption)
                    Spacer()
                    Text(lossText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("ICE RTT")
                        .font(.caption)
                    Spacer()
                    Text(rttText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
    }
}

#Preview {
    ContentView()
        .environmentObject(WebRTCManager())
        .environmentObject(InputManager())
        .environmentObject(OCRManager())
        .environmentObject(KVMDeviceManager())
}
