import Foundation
import Cocoa
import CoreGraphics
import Combine
import SwiftUI

extension Notification.Name {
    static let overlookToggleCopyMode = Notification.Name("overlook.toggleCopyMode")
}

@MainActor
class InputManager: ObservableObject {
    private var webRTCManager: WebRTCManager?
    private var glkvmClient: GLKVMClient?
    private var glkvmWebSocketClient: GLKVMClient.WebSocketClient?
    private var keyEventMonitor: Any?
    private var mouseEventMonitor: Any?
    private var isCapturing = false
    private var mouseModeRefreshTask: Task<Void, Never>?

    private struct PendingAbsoluteMouseMove {
        let toX: Int
        let toY: Int
    }

    private struct PendingRelativeMouseMove {
        var deltaX: Int
        var deltaY: Int
    }

    private var pendingAbsoluteMouseMove: PendingAbsoluteMouseMove?
    private var pendingRelativeMouseMove: PendingRelativeMouseMove?
    private var mouseMoveSenderTask: Task<Void, Never>?
    private static let mouseMoveSendIntervalNs: UInt64 = 8_333_333

    private var pendingCommandKeyCode: UInt16?
    private var activeCommandKeyCode: UInt16?
    private var commandKeySentToRemote: Bool = false
    private var suppressedKeyUps: Set<UInt16> = []
    
    @Published var isKeyboardCaptureEnabled = false
    @Published var isMouseCaptureEnabled = false

    enum TransportMode: String, CaseIterable {
        case webRTC
        case glkvmWebSocket
    }

    @Published var transportMode: TransportMode = .glkvmWebSocket
    @Published private(set) var isGLKVMAbsoluteMouseMode = true
    
    func setup(with webRTCManager: WebRTCManager) {
        self.webRTCManager = webRTCManager
    }

    func setGLKVMClient(_ client: GLKVMClient?) {
        mouseModeRefreshTask?.cancel()
        mouseModeRefreshTask = nil
        glkvmClient = client
        isGLKVMAbsoluteMouseMode = true
        pendingAbsoluteMouseMove = nil
        pendingRelativeMouseMove = nil
        if client == nil {
            disconnectGLKVMWebSocket()
            return
        }
        Task { [weak self] in
            await self?.reconnectGLKVMWebSocketIfNeeded()
        }
        mouseModeRefreshTask = Task { [weak self, weak client] in
            guard let client else { return }
            do {
                let config = try await client.getSystemConfig()
                await MainActor.run {
                    guard let self, self.glkvmClient === client else { return }
                    self.setGLKVMAbsoluteMouseMode(config.isAbsoluteMouse)
                }
            } catch {
                // Keep the default absolute-mode behavior if settings cannot be loaded.
            }
        }
    }

    func setGLKVMAbsoluteMouseMode(_ isAbsolute: Bool) {
        guard isGLKVMAbsoluteMouseMode != isAbsolute else { return }
        isGLKVMAbsoluteMouseMode = isAbsolute
        pendingAbsoluteMouseMove = nil
        pendingRelativeMouseMove = nil
    }

    func handleVideoMouseMove(pointInView: CGPoint, deltaInView: CGSize = .zero, viewSize: CGSize, videoSize: CGSize?) {
        guard isMouseCaptureEnabled else { return }
        let normalized = normalizePointInViewToVideo(pointInView: pointInView, viewSize: viewSize, videoSize: videoSize)
        let moveEvent = MouseMoveEvent(position: normalized, delta: deltaInView, timestamp: CACurrentMediaTime())
        if transportMode == .glkvmWebSocket {
            if isGLKVMAbsoluteMouseMode {
                enqueueAbsoluteMouseMoveEvent(moveEvent)
            } else {
                enqueueRelativeMouseMoveEvent(moveEvent)
            }
        } else {
            sendMouseMoveEvent(moveEvent)
        }
    }

    private func enqueueAbsoluteMouseMoveEvent(_ event: MouseMoveEvent) {
        guard isNormalized(event.position) else { return }
        let (toX, toY) = glkvmAbsolutePoint(fromNormalized: event.position)
        pendingAbsoluteMouseMove = PendingAbsoluteMouseMove(toX: toX, toY: toY)
        if mouseMoveSenderTask == nil {
            startMouseMoveSender()
        }
    }

    private func enqueueRelativeMouseMoveEvent(_ event: MouseMoveEvent) {
        let deltaX = Int(event.delta.width.rounded())
        let deltaY = Int(event.delta.height.rounded())
        guard deltaX != 0 || deltaY != 0 else { return }

        if var pending = pendingRelativeMouseMove {
            pending.deltaX += deltaX
            pending.deltaY += deltaY
            pendingRelativeMouseMove = pending
        } else {
            pendingRelativeMouseMove = PendingRelativeMouseMove(deltaX: deltaX, deltaY: deltaY)
        }

        if mouseMoveSenderTask == nil {
            startMouseMoveSender()
        }
    }

    private func startMouseMoveSender() {
        guard mouseMoveSenderTask == nil else { return }

        let sendIntervalNs = Self.mouseMoveSendIntervalNs

        mouseMoveSenderTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                let snapshot: (
                    absoluteMove: PendingAbsoluteMouseMove?,
                    relativeMove: PendingRelativeMouseMove?,
                    isAbsoluteMouseMode: Bool,
                    mode: TransportMode,
                    ws: GLKVMClient.WebSocketClient?
                ) = await MainActor.run {
                    let absoluteMove = self.pendingAbsoluteMouseMove
                    let relativeMove = self.pendingRelativeMouseMove
                    self.pendingAbsoluteMouseMove = nil
                    self.pendingRelativeMouseMove = nil
                    return (
                        absoluteMove,
                        relativeMove,
                        self.isGLKVMAbsoluteMouseMode,
                        self.transportMode,
                        self.glkvmWebSocketClient
                    )
                }

                let hasMove = snapshot.isAbsoluteMouseMode ? snapshot.absoluteMove != nil : snapshot.relativeMove != nil
                guard hasMove else {
                    await MainActor.run {
                        self.mouseMoveSenderTask = nil
                    }
                    return
                }

                if snapshot.mode == .glkvmWebSocket, let ws = snapshot.ws {
                    if snapshot.isAbsoluteMouseMode, let move = snapshot.absoluteMove {
                        try? await ws.sendHidMouseMove(toX: move.toX, toY: move.toY)
                    } else if let move = snapshot.relativeMove {
                        await Self.sendRelativeMouseMove(move, through: ws)
                    }
                }

                try? await Task.sleep(nanoseconds: sendIntervalNs)
            }
        }
    }

    private func stopMouseMoveSender() {
        pendingAbsoluteMouseMove = nil
        pendingRelativeMouseMove = nil
        mouseMoveSenderTask?.cancel()
        mouseMoveSenderTask = nil
    }

    func handleVideoMouseButton(button: MouseButton, isDown: Bool, pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?) {
        guard isMouseCaptureEnabled else { return }
        let normalized = normalizePointInViewToVideo(pointInView: pointInView, viewSize: viewSize, videoSize: videoSize)
        let buttonEvent = MouseButtonEvent(button: button, isDown: isDown, position: normalized, timestamp: CACurrentMediaTime())
        sendMouseButtonEvent(buttonEvent)
    }

    func handleVideoMouseScroll(deltaX: CGFloat, deltaY: CGFloat) {
        guard isMouseCaptureEnabled else { return }
        let scrollEvent = MouseScrollEvent(deltaX: deltaX, deltaY: deltaY, timestamp: CACurrentMediaTime())
        sendMouseScrollEvent(scrollEvent)
    }

    func setTransportMode(_ mode: TransportMode) {
        transportMode = mode
        switch mode {
        case .webRTC:
            stopMouseMoveSender()
            disconnectGLKVMWebSocket()
        case .glkvmWebSocket:
            Task { [weak self] in
                await self?.reconnectGLKVMWebSocketIfNeeded()
            }
        }
    }

    func disconnectGLKVMWebSocket() {
        stopMouseMoveSender()
        let ws = glkvmWebSocketClient
        glkvmWebSocketClient = nil
        Task {
            await ws?.disconnect()
        }
    }
    
    func startKeyboardCapture() {
        guard keyEventMonitor == nil else {
            isCapturing = true
            isKeyboardCaptureEnabled = true
            return
        }
        
        isCapturing = true
        isKeyboardCaptureEnabled = true
        
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
            guard let self, self.isKeyboardCaptureEnabled else { return event }
            return nil
        }
    }
    
    func stopKeyboardCapture() {
        isKeyboardCaptureEnabled = false
        
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
        
        if !isMouseCaptureEnabled {
            isCapturing = false
        }
    }
    
    func startMouseCapture() {
        isCapturing = true
        isMouseCaptureEnabled = true
    }
    
    func stopMouseCapture() {
        isMouseCaptureEnabled = false
        
        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }
        
        if !isKeyboardCaptureEnabled {
            isCapturing = false
        }
    }
    
    private func handleKeyEvent(_ event: NSEvent) {
        guard isKeyboardCaptureEnabled else { return }

        switch event.type {
        case .keyDown, .keyUp:
            let keyCode = event.keyCode
            let isKeyDown = event.type == .keyDown
            let modifiers = event.modifierFlags

            if !isKeyDown, suppressedKeyUps.contains(keyCode) {
                suppressedKeyUps.remove(keyCode)
                return
            }

            if isKeyDown, modifiers.contains(.command) {
                if keyCode == 8 {
                    prepareForLocalCommandShortcut()
                    suppressedKeyUps.insert(keyCode)
                    NotificationCenter.default.post(name: .overlookToggleCopyMode, object: nil)
                    return
                }
                if keyCode == 9 {
                    prepareForLocalCommandShortcut()
                    suppressedKeyUps.insert(keyCode)
                    pasteClipboardToRemote()
                    return
                }

                if let pending = pendingCommandKeyCode,
                   commandKeySentToRemote == false,
                   transportMode == .glkvmWebSocket,
                   let ws = glkvmWebSocketClient,
                   let metaKey = glkvmKeyForMacKeyCode(pending),
                   let keyName = glkvmKeyForMacKeyCode(keyCode) {
                    activeCommandKeyCode = pending
                    pendingCommandKeyCode = nil
                    commandKeySentToRemote = true

                    Task {
                        try? await ws.sendHidKey(key: metaKey, state: true)
                        try? await ws.sendHidKey(key: keyName, state: true)
                    }
                    return
                }

                flushPendingCommandKeyIfNeeded(timestamp: event.timestamp, modifiers: modifiers)
            }

            let keyEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: isKeyDown,
                modifiers: modifiers,
                timestamp: event.timestamp
            )

            sendKeyEvent(keyEvent)

        case .flagsChanged:
            let keyCode = event.keyCode
            guard let keyName = glkvmKeyForMacKeyCode(keyCode) else { return }

            let flags = event.modifierFlags
            let isDown: Bool
            switch keyName {
            case "ShiftLeft", "ShiftRight":
                isDown = flags.contains(.shift)
            case "ControlLeft", "ControlRight":
                isDown = flags.contains(.control)
            case "AltLeft", "AltRight":
                isDown = flags.contains(.option)
            case "MetaLeft", "MetaRight":
                isDown = flags.contains(.command)
                if isDown {
                    pendingCommandKeyCode = keyCode
                    activeCommandKeyCode = nil
                    commandKeySentToRemote = false
                    return
                }

                if commandKeySentToRemote {
                    let keyEvent = KeyEvent(
                        keyCode: activeCommandKeyCode ?? keyCode,
                        isKeyDown: false,
                        modifiers: flags,
                        timestamp: event.timestamp
                    )
                    sendKeyEvent(keyEvent)
                }

                clearPendingCommandKey()
                return
            case "CapsLock":
                isDown = flags.contains(.capsLock)
            default:
                return
            }

            let keyEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: isDown,
                modifiers: flags,
                timestamp: event.timestamp
            )
            sendKeyEvent(keyEvent)

        default:
            break
        }
    }

    private func prepareForLocalCommandShortcut() {
        if commandKeySentToRemote,
           transportMode == .glkvmWebSocket,
           let ws = glkvmWebSocketClient,
           let code = activeCommandKeyCode,
           let metaKey = glkvmKeyForMacKeyCode(code) {
            Task {
                try? await ws.sendHidKey(key: metaKey, state: false)
            }
        }

        pendingCommandKeyCode = activeCommandKeyCode ?? pendingCommandKeyCode
        activeCommandKeyCode = nil
        commandKeySentToRemote = false
    }

    private func clearPendingCommandKey() {
        pendingCommandKeyCode = nil
        activeCommandKeyCode = nil
        commandKeySentToRemote = false
    }

    private func flushPendingCommandKeyIfNeeded(timestamp: TimeInterval, modifiers: NSEvent.ModifierFlags) {
        guard let pendingCommandKeyCode, commandKeySentToRemote == false else { return }
        activeCommandKeyCode = pendingCommandKeyCode
        self.pendingCommandKeyCode = nil
        commandKeySentToRemote = true

        let keyEvent = KeyEvent(
            keyCode: activeCommandKeyCode ?? pendingCommandKeyCode,
            isKeyDown: true,
            modifiers: modifiers,
            timestamp: timestamp
        )
        sendKeyEvent(keyEvent)
    }

    private func pasteClipboardToRemote() {
        guard let client = glkvmClient else { return }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            do {
                try await client.hidPrint(text: trimmed)
            } catch {
                print("Paste to remote failed: \(error)")
            }
        }
    }
    
    private func handleMouseEvent(_ event: NSEvent) {
        guard isMouseCaptureEnabled else { return }
        
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            let mouseEvent = MouseButtonEvent(
                button: event.type == .leftMouseDown || event.type == .leftMouseUp ? .left : .right,
                isDown: event.type == .leftMouseDown || event.type == .rightMouseDown,
                position: CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y),
                timestamp: event.timestamp
            )
            sendMouseButtonEvent(mouseEvent)
            
        case .mouseMoved:
            let mouseEvent = MouseMoveEvent(
                position: CGPoint(x: event.locationInWindow.x, y: event.locationInWindow.y),
                delta: CGSize(width: event.deltaX, height: -event.deltaY),
                timestamp: event.timestamp
            )
            sendMouseMoveEvent(mouseEvent)
            
        case .scrollWheel:
            let scrollEvent = MouseScrollEvent(
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                timestamp: event.timestamp
            )
            sendMouseScrollEvent(scrollEvent)
            
        default:
            break
        }
    }
    
    func sendClick(at location: CGPoint, in geometry: GeometryProxy, videoSize: CGSize? = nil) {
        let normalizedPosition = normalizePointInViewToVideo(
            pointInView: location,
            viewSize: geometry.size,
            videoSize: videoSize
        )
        
        let clickEvent = MouseButtonEvent(
            button: .left,
            isDown: true,
            position: normalizedPosition,
            timestamp: CACurrentMediaTime()
        )
        
        sendMouseButtonEvent(clickEvent)
        
        // Send release event after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let releaseEvent = MouseButtonEvent(
                button: .left,
                isDown: false,
                position: normalizedPosition,
                timestamp: CACurrentMediaTime()
            )
            self.sendMouseButtonEvent(releaseEvent)
        }
    }
    
    private func sendKeyEvent(_ event: KeyEvent) {
        if transportMode == .glkvmWebSocket,
           let key = glkvmKeyForMacKeyCode(event.keyCode),
           let ws = glkvmWebSocketClient {
            Task {
                try? await ws.sendHidKey(key: key, state: event.isKeyDown)
            }
            return
        }

        let inputEvent = InputEvent(
            type: "keyboard",
            data: [
                "keyCode": .int(Int(event.keyCode)),
                "isKeyDown": .bool(event.isKeyDown),
                "modifiers": .int(Int(event.modifiers.rawValue)),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    private func sendMouseButtonEvent(_ event: MouseButtonEvent) {
        if transportMode == .glkvmWebSocket,
           let button = glkvmMouseButtonName(event.button),
           let ws = glkvmWebSocketClient {
            let shouldMove = isGLKVMAbsoluteMouseMode && isNormalized(event.position)
            let absolutePoint = shouldMove ? glkvmAbsolutePoint(fromNormalized: event.position) : nil
            Task {
                if let absolutePoint {
                    try? await ws.sendHidMouseMove(toX: absolutePoint.0, toY: absolutePoint.1)
                }
                try? await ws.sendHidMouseButton(button: button, state: event.isDown)
            }
            return
        }

        let inputEvent = InputEvent(
            type: "mouse-button",
            data: [
                "button": .int(event.button.rawValue),
                "isDown": .bool(event.isDown),
                "x": .double(event.position.x),
                "y": .double(event.position.y),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    private func sendMouseMoveEvent(_ event: MouseMoveEvent) {
        if transportMode == .glkvmWebSocket, isGLKVMAbsoluteMouseMode, isNormalized(event.position), let ws = glkvmWebSocketClient {
            let (toX, toY) = glkvmAbsolutePoint(fromNormalized: event.position)
            Task {
                try? await ws.sendHidMouseMove(toX: toX, toY: toY)
            }
            return
        }

        if transportMode == .glkvmWebSocket, !isGLKVMAbsoluteMouseMode, let ws = glkvmWebSocketClient {
            let move = PendingRelativeMouseMove(
                deltaX: Int(event.delta.width.rounded()),
                deltaY: Int(event.delta.height.rounded())
            )
            guard move.deltaX != 0 || move.deltaY != 0 else { return }
            Task {
                await Self.sendRelativeMouseMove(move, through: ws)
            }
            return
        }

        let inputEvent = InputEvent(
            type: "mouse-move",
            data: [
                "x": .double(event.position.x),
                "y": .double(event.position.y),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    private func sendMouseScrollEvent(_ event: MouseScrollEvent) {
        if transportMode == .glkvmWebSocket, let ws = glkvmWebSocketClient {
            let dx = Self.clampInt(Int(event.deltaX.rounded()), min: -127, max: 127)
            let dy = Self.clampInt(Int(event.deltaY.rounded()), min: -127, max: 127)
            Task {
                try? await ws.sendHidMouseWheel(deltaX: dx, deltaY: dy)
            }
            return
        }

        let inputEvent = InputEvent(
            type: "mouse-scroll",
            data: [
                "deltaX": .double(event.deltaX),
                "deltaY": .double(event.deltaY),
                "timestamp": .double(event.timestamp)
            ]
        )
        
        webRTCManager?.sendInputEvent(inputEvent)
    }
    
    func sendKeyCombination(_ keys: [UInt16], modifiers: NSEvent.ModifierFlags) {
        for keyCode in keys {
            let keyDownEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: true,
                modifiers: modifiers,
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyDownEvent)
        }
        
        // Send key up events after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for keyCode in keys.reversed() {
                let keyUpEvent = KeyEvent(
                    keyCode: keyCode,
                    isKeyDown: false,
                    modifiers: modifiers,
                    timestamp: CACurrentMediaTime()
                )
                self.sendKeyEvent(keyUpEvent)
            }
        }
    }
    
    func sendText(_ text: String) {
        for character in text {
            let keyCode = self.keyCodeForCharacter(character)
            let keyEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: true,
                modifiers: [],
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyEvent)
            
            // Send key up event
            let keyUpEvent = KeyEvent(
                keyCode: keyCode,
                isKeyDown: false,
                modifiers: [],
                timestamp: CACurrentMediaTime()
            )
            sendKeyEvent(keyUpEvent)
        }
    }
    
    private func keyCodeForCharacter(_ character: Character) -> UInt16 {
        // Basic mapping for common characters
        // In a real implementation, you'd want a more comprehensive mapping
        switch character {
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6
        case " ": return 49
        case "\n": return 36
        case ",": return 43
        case ".": return 47
        case "/": return 44
        case ";": return 41
        case "'": return 39
        case "[": return 33
        case "]": return 30
        case "\\": return 42
        case "`": return 50
        case "-": return 27
        case "=": return 24
        default: return 0
        }
    }
    
    deinit {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }

        if let monitor = mouseEventMonitor {
            NSEvent.removeMonitor(monitor)
            mouseEventMonitor = nil
        }

        mouseModeRefreshTask?.cancel()
        mouseModeRefreshTask = nil
    }

    private func reconnectGLKVMWebSocketIfNeeded() async {
        if transportMode != .glkvmWebSocket {
            return
        }
        guard let client = glkvmClient else {
            return
        }

        if glkvmWebSocketClient == nil {
            let ws = try? client.makeWebSocketClient(stream: false)
            glkvmWebSocketClient = ws
            await ws?.connect()
        }
    }

    private func isNormalized(_ point: CGPoint) -> Bool {
        point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1
    }

    private func glkvmAbsolutePoint(fromNormalized point: CGPoint) -> (Int, Int) {
        let clampedX = max(0, min(1, point.x))
        let clampedY = max(0, min(1, point.y))
        let maxAxis = 32767.0

        let signedX = (clampedX * 2.0 - 1.0) * maxAxis
        let signedY = (clampedY * 2.0 - 1.0) * maxAxis

        return (Int(signedX.rounded()), Int(signedY.rounded()))
    }

    func normalizePointInViewToVideo(pointInView: CGPoint, viewSize: CGSize, videoSize: CGSize?) -> CGPoint {
        guard viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }

        guard let videoSize, videoSize.width > 0, videoSize.height > 0 else {
            let clampedX = max(0, min(1, pointInView.x / viewSize.width))
            let clampedY = max(0, min(1, pointInView.y / viewSize.height))
            return CGPoint(x: clampedX, y: clampedY)
        }

        let viewAspect = viewSize.width / viewSize.height
        let videoAspect = videoSize.width / videoSize.height

        var contentRect = CGRect(origin: .zero, size: viewSize)

        if viewAspect > videoAspect {
            let contentWidth = viewSize.height * videoAspect
            let xOffset = (viewSize.width - contentWidth) / 2.0
            contentRect = CGRect(x: xOffset, y: 0, width: contentWidth, height: viewSize.height)
        } else {
            let contentHeight = viewSize.width / videoAspect
            let yOffset = (viewSize.height - contentHeight) / 2.0
            contentRect = CGRect(x: 0, y: yOffset, width: viewSize.width, height: contentHeight)
        }

        let clampedX = max(contentRect.minX, min(contentRect.maxX, pointInView.x))
        let clampedY = max(contentRect.minY, min(contentRect.maxY, pointInView.y))

        let normalizedX = (clampedX - contentRect.minX) / contentRect.width
        let normalizedY = (clampedY - contentRect.minY) / contentRect.height

        return CGPoint(x: max(0, min(1, normalizedX)), y: max(0, min(1, normalizedY)))
    }

    private func glkvmMouseButtonName(_ button: MouseButton) -> String? {
        switch button {
        case .left:
            return "left"
        case .right:
            return "right"
        case .middle:
            return "middle"
        }
    }

    private func glkvmKeyForMacKeyCode(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 0: return "KeyA"
        case 11: return "KeyB"
        case 8: return "KeyC"
        case 2: return "KeyD"
        case 14: return "KeyE"
        case 3: return "KeyF"
        case 5: return "KeyG"
        case 4: return "KeyH"
        case 34: return "KeyI"
        case 38: return "KeyJ"
        case 40: return "KeyK"
        case 37: return "KeyL"
        case 46: return "KeyM"
        case 45: return "KeyN"
        case 31: return "KeyO"
        case 35: return "KeyP"
        case 12: return "KeyQ"
        case 15: return "KeyR"
        case 1: return "KeyS"
        case 17: return "KeyT"
        case 32: return "KeyU"
        case 9: return "KeyV"
        case 13: return "KeyW"
        case 7: return "KeyX"
        case 16: return "KeyY"
        case 6: return "KeyZ"

        case 18: return "Digit1"
        case 19: return "Digit2"
        case 20: return "Digit3"
        case 21: return "Digit4"
        case 23: return "Digit5"
        case 22: return "Digit6"
        case 26: return "Digit7"
        case 28: return "Digit8"
        case 25: return "Digit9"
        case 29: return "Digit0"

        case 50: return "Backquote"
        case 27: return "Minus"
        case 24: return "Equal"
        case 33: return "BracketLeft"
        case 30: return "BracketRight"
        case 41: return "Semicolon"
        case 39: return "Quote"
        case 42: return "Backslash"
        case 43: return "Comma"
        case 47: return "Period"
        case 44: return "Slash"

        case 49: return "Space"
        case 48: return "Tab"
        case 36: return "Enter"
        case 51: return "Backspace"
        case 53: return "Escape"

        case 82: return "Numpad0"
        case 83: return "Numpad1"
        case 84: return "Numpad2"
        case 85: return "Numpad3"
        case 86: return "Numpad4"
        case 87: return "Numpad5"
        case 88: return "Numpad6"
        case 89: return "Numpad7"
        case 91: return "Numpad8"
        case 92: return "Numpad9"
        case 65: return "NumpadDecimal"
        case 67: return "NumpadMultiply"
        case 69: return "NumpadAdd"
        case 78: return "NumpadSubtract"
        case 75: return "NumpadDivide"
        case 76: return "NumpadEnter"
        case 81: return "NumpadEqual"

        case 114: return "Help"

        case 115: return "Home"
        case 119: return "End"
        case 116: return "PageUp"
        case 121: return "PageDown"
        case 117: return "Delete"

        case 123: return "ArrowLeft"
        case 124: return "ArrowRight"
        case 125: return "ArrowDown"
        case 126: return "ArrowUp"

        case 55: return "MetaLeft"
        case 54: return "MetaRight"
        case 56: return "ShiftLeft"
        case 60: return "ShiftRight"
        case 58: return "AltLeft"
        case 61: return "AltRight"
        case 59: return "ControlLeft"
        case 62: return "ControlRight"
        case 57: return "CapsLock"

        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"

        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"

        default:
            return nil
        }
    }

    private static func sendRelativeMouseMove(_ move: PendingRelativeMouseMove, through ws: GLKVMClient.WebSocketClient) async {
        var remainingX = move.deltaX
        var remainingY = move.deltaY

        while remainingX != 0 || remainingY != 0 {
            let dx = clampInt(remainingX, min: -127, max: 127)
            let dy = clampInt(remainingY, min: -127, max: 127)
            try? await ws.sendHidMouseRelative(deltaX: dx, deltaY: dy)
            remainingX -= dx
            remainingY -= dy
        }
    }

    private static func clampInt(_ value: Int, min: Int, max: Int) -> Int {
        if value < min { return min }
        if value > max { return max }
        return value
    }
}

// MARK: - Input Event Types
struct KeyEvent {
    let keyCode: UInt16
    let isKeyDown: Bool
    let modifiers: NSEvent.ModifierFlags
    let timestamp: CFTimeInterval
}

struct MouseButtonEvent {
    let button: MouseButton
    let isDown: Bool
    let position: CGPoint
    let timestamp: CFTimeInterval
}

struct MouseMoveEvent {
    let position: CGPoint
    let delta: CGSize
    let timestamp: CFTimeInterval
}

struct MouseScrollEvent {
    let deltaX: CGFloat
    let deltaY: CGFloat
    let timestamp: CFTimeInterval
}

enum MouseButton: Int, Codable {
    case left = 0
    case right = 1
    case middle = 2
}

// MARK: - Input Capture Extensions
extension InputManager {
    func toggleKeyboardCapture() {
        if isKeyboardCaptureEnabled {
            stopKeyboardCapture()
        } else {
            startKeyboardCapture()
        }
    }
    
    func toggleMouseCapture() {
        if isMouseCaptureEnabled {
            stopMouseCapture()
        } else {
            startMouseCapture()
        }
    }
    
    func startFullInputCapture() {
        startKeyboardCapture()
        startMouseCapture()
    }
    
    func stopFullInputCapture() {
        stopKeyboardCapture()
        stopMouseCapture()
    }
}

// MARK: - Accessibility Permissions Helper
extension InputManager {
    func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }
    
    func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    func showAccessibilityPermissionDialog() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permissions Required"
        alert.informativeText = "Overlook needs accessibility permissions to capture keyboard and mouse input for remote control. Please grant permissions in System Preferences > Security & Privacy > Privacy > Accessibility."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Preferences")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Open System Preferences to Accessibility section
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Input Validation and Filtering
extension InputManager {
    private func shouldCaptureKeyEvent(_ event: NSEvent) -> Bool {
        // Filter out system key combinations that should remain local
        let systemKeyCombinations: [UInt16] = [
            55, // Command
            56, // Shift
            57, // Option
            58, // Control
            59, // Caps Lock
            60, // Function
        ]
        
        return !systemKeyCombinations.contains(event.keyCode)
    }
    
    private func shouldCaptureMouseEvent(_ event: NSEvent) -> Bool {
        // Filter out mouse events that should remain local
        // This is a basic implementation - you might want to add more sophisticated filtering
        return true
    }
}
