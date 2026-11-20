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
            CleanViewCommands()
        }
    }
}

struct CleanViewKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    /// The focused window's clean-view flag. Not published while that window is in full screen.
    var cleanView: Binding<Bool>? {
        get { self[CleanViewKey.self] }
        set { self[CleanViewKey.self] = newValue }
    }
}

struct CleanViewCommands: Commands {
    @FocusedBinding(\.cleanView) private var isCleanView: Bool?

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            // ⌃⌘C is also intercepted by InputManager while keyboard capture is active,
            // because the capture monitor consumes key events before menu key equivalents.
            Toggle("Clean View", isOn: Binding(
                get: { isCleanView ?? false },
                set: { isCleanView = $0 }
            ))
            .keyboardShortcut("c", modifiers: [.command, .control])
            .disabled(isCleanView == nil)
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
