import SwiftUI
#if canImport(WebRTC)
import WebRTC
#endif
import Vision
import Network

@main
struct OverlookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appDelegate.webRTCManager)
                .environmentObject(appDelegate.inputManager)
                .environmentObject(appDelegate.ocrManager)
                .environmentObject(appDelegate.kvmDeviceManager)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .windowResizability(.automatic)
        .commands {
            WindowSizeCommands()
            InputModeCommands()
        }
    }
}

struct ViewOnlyModeKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    /// The focused window's view-only flag. Only published while that window is connected.
    var viewOnlyMode: Binding<Bool>? {
        get { self[ViewOnlyModeKey.self] }
        set { self[ViewOnlyModeKey.self] = newValue }
    }
}

struct InputModeCommands: Commands {
    @FocusedBinding(\.viewOnlyMode) private var isViewOnly: Bool?

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            // ⌘⇧M is also intercepted by InputManager while keyboard capture is active,
            // because the capture monitor consumes key events before menu key equivalents.
            Toggle("View Only", isOn: Binding(
                get: { isViewOnly ?? false },
                set: { isViewOnly = $0 }
            ))
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(isViewOnly == nil)
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBarAgent: MenuBarAgent?

    let webRTCManager = WebRTCManager()
    let inputManager = InputManager()
    let ocrManager = OCRManager()
    let kvmDeviceManager = KVMDeviceManager()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarAgent = MenuBarAgent(
            kvmDeviceManager: kvmDeviceManager,
            webRTCManager: webRTCManager,
            inputManager: inputManager,
            showMainWindow: { [weak self] in
                self?.showMainWindow()
            }
        )
        menuBarAgent?.setup()
        
        // Configure app for KVM control
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let windows = NSApp.windows
        let candidate = windows.first(where: { $0.canBecomeKey && $0.isVisible }) ?? windows.first(where: { $0.canBecomeKey })
        candidate?.makeKeyAndOrderFront(nil)
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        menuBarAgent?.cleanup()
        return .terminateNow
    }
}
