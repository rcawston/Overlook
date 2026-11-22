import SwiftUI
import AppKit
import Combine

@MainActor
class MenuBarAgent: NSObject, ObservableObject {
    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var popover: NSPopover?
    private var monitoringWindow: NSWindow?

    private let kvmDeviceManager: KVMDeviceManager
    private let webRTCManager: WebRTCManager
    private let inputManager: InputManager
    private let showMainWindow: () -> Void
    
    @Published var isConnected = false
    @Published var currentDevice: KVMDevice?
    @Published var availableDevices: [KVMDevice] = []
    
    private var cancellables = Set<AnyCancellable>()

    init(
        kvmDeviceManager: KVMDeviceManager,
        webRTCManager: WebRTCManager,
        inputManager: InputManager,
        showMainWindow: @escaping () -> Void
    ) {
        self.kvmDeviceManager = kvmDeviceManager
        self.webRTCManager = webRTCManager
        self.inputManager = inputManager
        self.showMainWindow = showMainWindow
        super.init()
    }
    
    func setup() {
        createStatusItem()
        createMenu()
        setupKeyboardShortcuts()

        inputManager.setup(with: webRTCManager)
        bindManagers()
    }

    private func bindManagers() {
        availableDevices = kvmDeviceManager.availableDevices
        currentDevice = kvmDeviceManager.connectedDevice
        isConnected = (kvmDeviceManager.connectedDevice != nil)
        updateStatusIcon()
        updateDeviceMenu()

        kvmDeviceManager.$availableDevices
            .sink { [weak self] devices in
                guard let self else { return }
                self.availableDevices = devices
                self.updateDeviceMenu()
            }
            .store(in: &cancellables)

        kvmDeviceManager.$savedPasswordDeviceKeys
            .dropFirst()
            .sink { [weak self] _ in
                // Published before the value changes; rebuild once it has.
                DispatchQueue.main.async { self?.updateDeviceMenu() }
            }
            .store(in: &cancellables)

        kvmDeviceManager.$connectedDevice
            .sink { [weak self] device in
                guard let self else { return }
                self.currentDevice = device
                self.isConnected = (device != nil)
                self.inputManager.setPasteKeymap(device?.pasteKeymap)
                self.updateStatusIcon()
                self.updateStatusMenuItem()
                self.updateDeviceMenu()
            }
            .store(in: &cancellables)
    }
    
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Overlook")
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        
        updateStatusIcon()
    }
    
    private func createMenu() {
        menu = NSMenu()

        let showItem = NSMenuItem(title: "Show Overlook", action: #selector(showMainWindowAction), keyEquivalent: "")
        showItem.target = self
        menu?.addItem(showItem)
        menu?.addItem(NSMenuItem.separator())
        
        // Device section
        let deviceItem = NSMenuItem(title: "Devices", action: nil, keyEquivalent: "")
        deviceItem.submenu = createDeviceMenu()
        menu?.addItem(deviceItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        // Connection status
        let statusItem = NSMenuItem(title: "Status: Disconnected", action: nil, keyEquivalent: "")
        statusItem.tag = 100
        menu?.addItem(statusItem)

        let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnectAction), keyEquivalent: "")
        disconnectItem.target = self
        disconnectItem.tag = 101
        disconnectItem.isEnabled = false
        menu?.addItem(disconnectItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        // Quick actions
        let connectItem = NSMenuItem(title: "Quick Connect", action: #selector(showQuickConnect), keyEquivalent: "k")
        connectItem.target = self
        menu?.addItem(connectItem)
        
        let scanItem = NSMenuItem(title: "Scan for Devices", action: #selector(scanForDevices), keyEquivalent: "r")
        scanItem.target = self
        menu?.addItem(scanItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        // OCR toggle
        let ocrItem = NSMenuItem(title: "Enable OCR", action: #selector(toggleOCR), keyEquivalent: "o")
        ocrItem.target = self
        ocrItem.tag = 200
        menu?.addItem(ocrItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        // Preferences
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu?.addItem(prefsItem)
        
        menu?.addItem(NSMenuItem.separator())
        
        // Quit
        let quitItem = NSMenuItem(title: "Quit Overlook", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu?.addItem(quitItem)

        updateStatusMenuItem()
    }
    
    private func createDeviceMenu() -> NSMenu {
        let deviceMenu = NSMenu()
        
        let noDevicesItem = NSMenuItem(title: "No devices found", action: nil, keyEquivalent: "")
        noDevicesItem.tag = 300
        deviceMenu.addItem(noDevicesItem)
        
        return deviceMenu
    }
    
    private func updateDeviceMenu() {
        guard let deviceMenuItem = menu?.items.first(where: { $0.title == "Devices" }),
              let deviceMenu = deviceMenuItem.submenu else { return }
        
        deviceMenu.removeAllItems()
        
        if availableDevices.isEmpty {
            let noDevicesItem = NSMenuItem(title: "No devices found", action: nil, keyEquivalent: "")
            noDevicesItem.tag = 300
            deviceMenu.addItem(noDevicesItem)
        } else {
            for device in availableDevices {
                let deviceItem = NSMenuItem(title: device.name, action: #selector(connectToDevice(_:)), keyEquivalent: "")
                deviceItem.target = self
                deviceItem.representedObject = device
                
                if currentDevice?.host == device.host, currentDevice?.port == device.port {
                    deviceItem.state = .on
                }
                
                deviceMenu.addItem(deviceItem)
            }
        }
        
        deviceMenu.addItem(NSMenuItem.separator())

        // Forget saved devices
        let savedDevices = availableDevices.filter { $0.id.hasPrefix("saved-") }
        let forgetItem = NSMenuItem(title: "Forget Saved Device", action: nil, keyEquivalent: "")
        let forgetMenu = NSMenu()
        if savedDevices.isEmpty {
            forgetMenu.addItem(NSMenuItem(title: "No saved devices", action: nil, keyEquivalent: ""))
        } else {
            for device in savedDevices {
                let item = NSMenuItem(title: device.name, action: #selector(forgetDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                forgetMenu.addItem(item)
            }
        }
        forgetItem.submenu = forgetMenu
        deviceMenu.addItem(forgetItem)

        // Forget passwords saved in the Keychain
        let passwordDevices = savedDevices.filter { kvmDeviceManager.hasSavedPassword(for: $0) }
        let forgetPasswordItem = NSMenuItem(title: "Forget Saved Password", action: nil, keyEquivalent: "")
        let forgetPasswordMenu = NSMenu()
        if passwordDevices.isEmpty {
            forgetPasswordMenu.addItem(NSMenuItem(title: "No saved passwords", action: nil, keyEquivalent: ""))
        } else {
            for device in passwordDevices {
                let item = NSMenuItem(title: device.name, action: #selector(forgetSavedPassword(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                forgetPasswordMenu.addItem(item)
            }
        }
        forgetPasswordItem.submenu = forgetPasswordMenu
        deviceMenu.addItem(forgetPasswordItem)

        // Remove manual devices
        let manualDevices = availableDevices.filter { $0.id.hasPrefix("manual-") }
        let removeItem = NSMenuItem(title: "Remove Manual Device", action: nil, keyEquivalent: "")
        let removeMenu = NSMenu()
        if manualDevices.isEmpty {
            removeMenu.addItem(NSMenuItem(title: "No manual devices", action: nil, keyEquivalent: ""))
        } else {
            for device in manualDevices {
                let item = NSMenuItem(title: device.name, action: #selector(removeManualDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device
                removeMenu.addItem(item)
            }
        }
        removeItem.submenu = removeMenu
        deviceMenu.addItem(removeItem)
        
        deviceMenu.addItem(NSMenuItem.separator())
        
        let addDeviceItem = NSMenuItem(title: "Add Manual Device...", action: #selector(showAddDevice), keyEquivalent: "")
        addDeviceItem.target = self
        deviceMenu.addItem(addDeviceItem)
    }
    
    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        
        if event.type == .rightMouseUp {
            // Show context menu
            statusItem?.menu = menu
            statusItem?.button?.performClick(nil)
            statusItem?.menu = nil
        } else {
            // Show popover
            togglePopover(nil)
        }
    }

    private func updateStatusMenuItem() {
        if let statusItem = menu?.items.first(where: { $0.tag == 100 }) {
            if let device = kvmDeviceManager.connectedDevice {
                statusItem.title = "Connected to \(device.name)"
            } else {
                statusItem.title = "Status: Disconnected"
            }
        }
        if let disconnectItem = menu?.items.first(where: { $0.tag == 101 }) {
            disconnectItem.isEnabled = (kvmDeviceManager.connectedDevice != nil)
        }
    }

    private func promptForPassword(message: String, prefill: String?, rememberByDefault: Bool) -> (password: String, remember: Bool)? {
        let alert = NSAlert()
        alert.messageText = "Password Required"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 50))

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 22))
        passwordField.placeholderString = "Password"
        passwordField.stringValue = prefill ?? ""

        let rememberCheckbox = NSButton(checkboxWithTitle: "Remember password in Keychain", target: nil, action: nil)
        rememberCheckbox.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        rememberCheckbox.state = rememberByDefault ? .on : .off

        view.addSubview(passwordField)
        view.addSubview(rememberCheckbox)
        alert.accessoryView = view
        alert.window.initialFirstResponder = passwordField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }

        let pw = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return pw.isEmpty ? nil : (pw, rememberCheckbox.state == .on)
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    @objc private func togglePopover(_ sender: Any?) {
        if let popover = popover, popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }
    
    private func showPopover() {
        guard let statusItem = statusItem else { return }
        
        if popover == nil {
            popover = NSPopover()
            popover?.contentSize = NSSize(width: 300, height: 400)
            popover?.behavior = .transient
            popover?.contentViewController = NSHostingController(
                rootView: MenuBarView(
                    kvmDeviceManager: kvmDeviceManager,
                    onShowWindow: { [weak self] in self?.showMainWindow() },
                    onScan: { [weak self] in self?.kvmDeviceManager.scanForDevices() },
                    onConnect: { [weak self] device in
                        guard let self else { return }
                        Task { await self.connectSession(to: device) }
                    },
                    onDisconnect: { [weak self] in
                        guard let self else { return }
                        self.disconnectSession()
                    },
                    onForget: { [weak self] device in
                        guard let self else { return }
                        self.kvmDeviceManager.forgetDevice(device)
                    }
                )
            )
        }
        
        popover?.show(relativeTo: statusItem.button!.bounds, of: statusItem.button!, preferredEdge: .minY)
    }
    
    private func closePopover() {
        popover?.performClose(nil)
    }
    
    @objc private func connectToDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? KVMDevice else { return }

        Task { await connectSession(to: device) }
    }

    private func connectSession(to device: KVMDevice, password: String? = nil) async {
        showMainWindow()

        var password = password
        var rememberPassword: Bool?
        while true {
            do {
                let connected = try await kvmDeviceManager.connectToDevice(device, password: password, rememberPassword: rememberPassword)
                await finishSessionConnect(connected)
            } catch let kvmError as KVMError where kvmError.promptsForPassword {
                // Prefill only; the password is sent when the user clicks Connect.
                let savedPassword = kvmError == .passwordRejected ? nil : await kvmDeviceManager.savedPassword(for: device)
                guard let entry = promptForPassword(
                    message: kvmError.passwordPromptMessage(for: device, prefilled: savedPassword != nil),
                    prefill: savedPassword,
                    rememberByDefault: rememberPassword ?? kvmDeviceManager.hasSavedPassword(for: device)
                ) else { return }
                password = entry.password
                rememberPassword = entry.remember
                continue
            } catch {
                showError(title: "Failed to connect", message: String(describing: error))
            }
            return
        }
    }

    private func finishSessionConnect(_ connectedDevice: KVMDevice) async {
        if let client = kvmDeviceManager.glkvmClient {
            inputManager.setGLKVMClient(client)
            inputManager.startFullInputCapture()
            try? await client.setHidConnected(true)
        }

        closePopover()

#if canImport(WebRTC)
        do {
            try await webRTCManager.connect(to: connectedDevice)
        } catch {
            // still consider ourselves connected at the API layer
            showError(title: "WebRTC connect failed", message: String(describing: error))
        }
#endif
    }

    @objc private func disconnectAction() {
        disconnectSession()
    }

    private func disconnectSession() {
        webRTCManager.disconnect()

        let client = kvmDeviceManager.glkvmClient
        Task {
            try? await client?.setHidConnected(false)
        }

        kvmDeviceManager.disconnectFromDevice()
        inputManager.setGLKVMClient(nil)
        inputManager.stopFullInputCapture()

        closePopover()
    }
    
    @objc private func showQuickConnect() {
        let alert = NSAlert()
        alert.messageText = "Quick Connect"
        alert.informativeText = "Enter the IP/host and port of your KVM device"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        let view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 260, height: 86)

        let hostField = NSTextField(frame: NSRect(x: 0, y: 56, width: 260, height: 22))
        hostField.placeholderString = "Host or IP (optionally host:port)"

        let portField = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 22))
        portField.placeholderString = "Port"
        portField.stringValue = "443"
        portField.integerValue = 443

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        passwordField.placeholderString = "Password (optional)"

        view.addSubview(hostField)
        view.addSubview(portField)
        view.addSubview(passwordField)
        alert.accessoryView = view

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let raw = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        var host = raw
        var portString = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

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
        let password = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            await connectSession(to: device, password: password.isEmpty ? nil : password)
        }
    }
    
    @objc private func scanForDevices() {
        kvmDeviceManager.scanForDevices()
    }
    
    @objc private func toggleOCR() {
        NotificationCenter.default.post(name: .overlookToggleCopyMode, object: nil)
        
        // Update menu item
        if let ocrItem = menu?.items.first(where: { $0.tag == 200 }) {
            ocrItem.title = ocrItem.title.contains("Enable") ? "Disable OCR" : "Enable OCR"
        }
    }
    
    @objc private func showPreferences() {
        showMainWindow()
    }
    
    @objc private func showAddDevice() {
        // Show add device dialog
        let alert = NSAlert()
        alert.messageText = "Add Manual Device"
        alert.informativeText = "Enter the IP address and port of your KVM device"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        
        // Add text fields for IP and port
        let view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 60)
        
        let ipField = NSTextField(frame: NSRect(x: 0, y: 30, width: 200, height: 20))
        ipField.placeholderString = "IP Address"
        ipField.stringValue = ""
        
        let portField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        portField.placeholderString = "Port"
        portField.stringValue = "8443"
        portField.integerValue = 8443
        
        view.addSubview(ipField)
        view.addSubview(portField)
        
        alert.accessoryView = view
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let ip = ipField.stringValue
            let port = portField.integerValue
            
            if !ip.isEmpty && port > 0 {
                _ = kvmDeviceManager.addManualDevice(host: ip, port: port, type: .glinetComet)
            }
        }
    }

    @objc private func forgetDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? KVMDevice else { return }
        if kvmDeviceManager.connectedDevice?.host == device.host, kvmDeviceManager.connectedDevice?.port == device.port {
            showError(title: "Cannot forget", message: "Disconnect before forgetting this device.")
            return
        }
        kvmDeviceManager.forgetDevice(device)
    }

    @objc private func forgetSavedPassword(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? KVMDevice else { return }
        kvmDeviceManager.forgetSavedPassword(for: device)
    }

    @objc private func removeManualDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? KVMDevice else { return }
        if kvmDeviceManager.connectedDevice?.host == device.host, kvmDeviceManager.connectedDevice?.port == device.port {
            showError(title: "Cannot remove", message: "Disconnect before removing this device.")
            return
        }
        kvmDeviceManager.removeDevice(device)
    }

    @objc private func showMainWindowAction() {
        showMainWindow()
    }
    
    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
    
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        
        if isConnected {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Overlook - Connected")
            button.contentTintColor = .systemGreen
        } else {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Overlook - Disconnected")
            button.contentTintColor = .labelColor
        }
    }
    
    private func setupKeyboardShortcuts() {
        // Global keyboard shortcuts for quick actions
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyEvent(event)
        }
    }
    
    private func handleGlobalKeyEvent(_ event: NSEvent) {
        guard event.modifierFlags.contains([.command, .shift]) else { return }
        
        switch event.keyCode {
        case 9: // V key - Quick connect
            showQuickConnect()
        case 31: // O key - Toggle OCR
            toggleOCR()
        case 15: // R key - Scan devices
            scanForDevices()
        default:
            break
        }
    }
    
    func updateConnectionStatus(_ connected: Bool, device: KVMDevice?) {
        isConnected = connected
        currentDevice = device
        
        Task { @MainActor in
            updateStatusIcon()
            
            if let statusItem = menu?.items.first(where: { $0.tag == 100 }) {
                if connected, let device = device {
                    statusItem.title = "Connected to \(device.name)"
                } else {
                    statusItem.title = "Status: Disconnected"
                }
            }
            
            updateDeviceMenu()
        }
    }
    
    func updateAvailableDevices(_ devices: [KVMDevice]) {
        availableDevices = devices
        
        Task { @MainActor in
            updateDeviceMenu()
        }
    }
    
    func cleanup() {
        statusItem = nil
        menu = nil
        popover = nil
        monitoringWindow = nil
        cancellables.removeAll()
    }
}

// MARK: - Menu Bar View
struct MenuBarView: View {
    @ObservedObject var kvmDeviceManager: KVMDeviceManager

    let onShowWindow: () -> Void
    let onScan: () -> Void
    let onConnect: (KVMDevice) -> Void
    let onDisconnect: () -> Void
    let onForget: (KVMDevice) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "display.2")
                    .font(.title2)
                Text("Overlook")
                    .font(.headline)
                Spacer()
                Button("Show") {
                    onShowWindow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            
            Divider()
            
            // Device list
            ScrollView {
                LazyVStack(spacing: 8) {
                    if kvmDeviceManager.availableDevices.isEmpty {
                        Text("No devices found")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(kvmDeviceManager.availableDevices) { device in
                            MenuBarDeviceRow(
                                device: device,
                                isConnected: kvmDeviceManager.connectedDevice?.host == device.host && kvmDeviceManager.connectedDevice?.port == device.port,
                                onConnect: {
                                    onConnect(device)
                                },
                                onDisconnect: {
                                    onDisconnect()
                                },
                                onForget: {
                                    onForget(device)
                                },
                                onRemoveManual: {
                                    kvmDeviceManager.removeDevice(device)
                                }
                            )
                        }
                    }
                }
                .padding()
            }
            
            Divider()
            
            // Actions
            HStack {
                Button("Scan") {
                    onScan()
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 300, height: 400)
    }
}

struct MenuBarDeviceRow: View {
    let device: KVMDevice

    let isConnected: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onForget: () -> Void
    let onRemoveManual: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(device.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(device.connectionString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()

            if device.id.hasPrefix("saved-") {
                Button {
                    onForget()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Forget saved device")
                .disabled(isConnected)
            } else if device.id.hasPrefix("manual-") {
                Button {
                    onRemoveManual()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove manual device")
                .disabled(isConnected)
            }
            
            Button(isConnected ? "Disconnect" : "Connect") {
                if isConnected {
                    onDisconnect()
                } else {
                    onConnect()
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}
