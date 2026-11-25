import Foundation
import Network
import Combine
import CryptoKit
import Security

@MainActor
final class KVMDeviceManager: NSObject, ObservableObject {
    @Published var availableDevices: [KVMDevice] = []
    @Published var connectedDevice: KVMDevice?
    @Published var glkvmClient: GLKVMClient?
    @Published var isScanning = false
    @Published var scanProgress: Double = 0.0
    @Published var autoScanEnabled: Bool = false
    
    private var networkMonitor: NWPathMonitor?
    private var scanTimer: Timer?
    private var deviceDiscoverySessions: [NWBrowser] = []

    // Discovery probes send no credentials, so they accept any certificate and pin nothing.
    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config, delegate: DeviceTLSDelegate.unpinned(), delegateQueue: nil)
    }()

    private let commonProbeTargets: [(host: String, port: Int)] = [
        ("192.168.200.5", 443),
        ("192.168.200.1", 443),
        ("192.168.200.1", 80),
    ]

    private static let savedDevicesKey = "overlook.saved_devices.v1"

    private struct PersistedDevice: Codable, Hashable {
        let host: String
        let port: Int
        let name: String
        let type: KVMDeviceType
        // Tokens are kept in the Keychain and written here as "". The field remains so older
        // builds can still read the list; it holds a token only until its Keychain write succeeds.
        var authToken: String
        let capabilities: Set<KVMCapability>
        // Optional so records saved before this setting existed still decode (as Automatic).
        let pasteKeymap: String?
    }
    
    override init() {
        super.init()
        setupNetworkMonitoring()
        loadPersistedDevices()
        migratePlaintextTokens()
    }
    
    private func setupNetworkMonitoring() {
        networkMonitor = NWPathMonitor()
        networkMonitor?.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                if path.status == .satisfied, self?.autoScanEnabled == true {
                    self?.scanForDevices()
                }
            }
        }
        
        let queue = DispatchQueue(label: "com.overlook.network")
        networkMonitor?.start(queue: queue)
    }
    
    func scanForDevices() {
        guard !isScanning else { return }
        
        isScanning = true
        scanProgress = 0.0
        let pinnedDevices = availableDevices.filter { $0.id.hasPrefix("manual-") || $0.id.hasPrefix("saved-") }
        availableDevices = pinnedDevices
        
        // Start multiple discovery methods
        Task {
            await withTaskGroup(of: [KVMDevice].self) { group in
                // GL.iNet Comet discovery
                group.addTask {
                    await self.discoverGLiNetDevices()
                }
                
                // Generic KVM discovery
                group.addTask {
                    await self.discoverGenericKVMDevices()
                }
                
                // Network scan for known ports
                group.addTask {
                    await self.scanKnownPorts()
                }

                // Quick probe for common/default KVM addresses
                group.addTask {
                    await self.probeCommonTargets()
                }
                
                // Tailscale network discovery
                group.addTask {
                    await self.discoverTailscaleDevices()
                }
                
                // Collect results
                var allDevices: [KVMDevice] = []
                let pinnedDevices = await MainActor.run {
                    self.availableDevices.filter { $0.id.hasPrefix("manual-") || $0.id.hasPrefix("saved-") }
                }

                for await devices in group {
                    allDevices.append(contentsOf: devices)

                    let uniqueDevices = self.removeDuplicates(from: allDevices)
                    await MainActor.run {
                        let combined = self.removeDuplicates(from: pinnedDevices + uniqueDevices)
                        self.availableDevices = combined.sorted { $0.name < $1.name }
                    }
                }

                await MainActor.run {
                    self.isScanning = false
                    self.scanProgress = 1.0
                    self.scanTimer?.invalidate()
                    self.scanTimer = nil
                }
            }
        }
        
        // Update progress
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in
                if self.scanProgress < 0.9 {
                    self.scanProgress += 0.05
                }
            }
        }
    }
    
    private func discoverGLiNetDevices() async -> [KVMDevice] {
        actor DeviceCollector {
            private var devices: [KVMDevice] = []
            func add(_ device: KVMDevice) {
                devices.append(device)
            }
            func all() -> [KVMDevice] {
                devices
            }
        }

        let collector = DeviceCollector()
        
        // GL.iNet Comet uses mDNS/Bonjour discovery
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_comet._tcp", domain: nil), using: .tcp)
        
        return await withCheckedContinuation { continuation in
            browser.browseResultsChangedHandler = { results, changes in
                for result in results {
                    let device = Self.createGLiNetDevice(from: result.endpoint)
                    Task {
                        await collector.add(device)
                    }
                }
            }
            
            browser.start(queue: DispatchQueue(label: "com.overlook.glinet"))
            
            // Stop after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task {
                    let devices = await collector.all()
                    browser.cancel()
                    continuation.resume(returning: devices)
                }
            }
        }
    }
    
    nonisolated private static func createGLiNetDevice(from endpoint: NWEndpoint) -> KVMDevice {
        var name = "GL.iNet Comet"
        var host = ""
        let port = 443
        
        if case .service(let serviceName, let type, let domain, _) = endpoint {
            name = serviceName
            host = "\(serviceName).\(type).\(domain)"
        }
        
        return KVMDevice(
            id: "glinet-\(UUID().uuidString)",
            name: name,
            host: host,
            port: port,
            type: .glinetComet,
            authToken: "",
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
        )
    }
    
    private func discoverGenericKVMDevices() async -> [KVMDevice] {
        actor DeviceCollector {
            private var devices: [KVMDevice] = []
            func add(_ device: KVMDevice) {
                devices.append(device)
            }
            func all() -> [KVMDevice] {
                devices
            }
        }

        let collector = DeviceCollector()
        
        // Generic KVM discovery via mDNS
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_kvm._tcp", domain: nil), using: .tcp)
        
        return await withCheckedContinuation { continuation in
            browser.browseResultsChangedHandler = { results, changes in
                for result in results {
                    let device = Self.createGenericKVMDevice(from: result.endpoint)
                    Task {
                        await collector.add(device)
                    }
                }
            }
            
            browser.start(queue: DispatchQueue(label: "com.overlook.generic"))
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                Task {
                    let devices = await collector.all()
                    browser.cancel()
                    continuation.resume(returning: devices)
                }
            }
        }
    }
    
    nonisolated private static func createGenericKVMDevice(from endpoint: NWEndpoint) -> KVMDevice {
        var name = "Generic KVM"
        var host = ""
        let port = 8080
        
        if case .service(let serviceName, let type, let domain, _) = endpoint {
            name = serviceName
            host = "\(serviceName).\(type).\(domain)"
        }
        
        return KVMDevice(
            id: "generic-\(UUID().uuidString)",
            name: name,
            host: host,
            port: port,
            type: .generic,
            authToken: "",
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
        )
    }
    
    private func scanKnownPorts() async -> [KVMDevice] {
        var devices: [KVMDevice] = []
        
        // Common KVM ports to scan
        let knownPorts = [443, 8443, 80, 8080]
        let localNetwork = getLocalNetworkRange()

        let maxConcurrent = 64
        var targets: [(host: String, port: Int)] = []
        targets.reserveCapacity(localNetwork.count * knownPorts.count)
        for host in localNetwork {
            for port in knownPorts {
                targets.append((host: host, port: port))
            }
        }
        
        await withTaskGroup(of: KVMDevice?.self) { group in
            var nextIndex = 0
            var inFlight = 0

            while nextIndex < targets.count || inFlight > 0 {
                while inFlight < maxConcurrent && nextIndex < targets.count {
                    let target = targets[nextIndex]
                    nextIndex += 1
                    inFlight += 1
                    group.addTask {
                        await self.checkKVMService(host: target.host, port: target.port)
                    }
                }

                if let device = await group.next() {
                    inFlight -= 1
                    if let device {
                        devices.append(device)
                    }
                }
            }
        }
        
        return devices
    }
    
    private func getLocalNetworkRange() -> [String] {
        var prefixes: Set<String> = []
        var hosts: [String] = []

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddr) == 0, let first = ifaddr {
            defer { freeifaddrs(ifaddr) }

            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let p = ptr {
                defer { ptr = p.pointee.ifa_next }
                guard let addr = p.pointee.ifa_addr else { continue }
                if addr.pointee.sa_family != UInt8(AF_INET) { continue }

                let flags = Int32(p.pointee.ifa_flags)
                if (flags & IFF_LOOPBACK) != 0 { continue }

                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(
                    addr,
                    socklen_t(addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if result != 0 { continue }
                let ip = String(cString: hostname)

                let parts = ip.split(separator: ".")
                guard parts.count == 4 else { continue }

                // Only scan typical private IPv4 ranges.
                let p0 = Int(parts[0]) ?? 0
                let p1 = Int(parts[1]) ?? 0
                let isPrivate = (p0 == 10) || (p0 == 192 && p1 == 168) || (p0 == 172 && (16...31).contains(p1))
                guard isPrivate else { continue }

                // Pragmatic /24 scan based on the interface IP.
                prefixes.insert("\(parts[0]).\(parts[1]).\(parts[2])")
            }
        }

        if prefixes.isEmpty {
            prefixes = [
                "192.168.1",
                "192.168.0",
                "10.0.0",
            ]
        }

        prefixes.insert("192.168.200")

        for prefix in prefixes {
            for i in 1...254 {
                hosts.append("\(prefix).\(i)")
            }
        }

        return hosts
    }

    private func probeCommonTargets() async -> [KVMDevice] {
        var devices: [KVMDevice] = []
        for target in commonProbeTargets {
            if let device = await checkKVMService(host: target.host, port: target.port) {
                devices.append(device)
                continue
            }

            // If the port is open but the HTTP probe didn't identify the service,
            // still surface it for the common/default targets (helps with devices
            // that redirect/behave oddly on probe endpoints).
            if await probeTCPPortOpen(host: target.host, port: target.port) {
                devices.append(
                    KVMDevice(
                        id: "scanned-\(target.host)-\(target.port)",
                        name: "KVM @ \(target.host):\(target.port)",
                        host: target.host,
                        port: target.port,
                        type: .glinetComet,
                        authToken: "",
                        capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
                    )
                )
            }
        }
        return devices
    }

    private func probeTCPPortOpen(host: String, port: Int) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return false
        }

        final class Flag {
            var value: Bool = false
        }

        let queue = DispatchQueue(label: "com.overlook.probe.port")
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)

        return await withCheckedContinuation { continuation in
            let finished = Flag()

            let timeoutWorkItem = DispatchWorkItem {
                if finished.value { return }
                finished.value = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: false)
            }

            queue.asyncAfter(deadline: .now() + 0.7, execute: timeoutWorkItem)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }
    
    private func checkKVMService(host: String, port: Int) async -> KVMDevice? {
        if await probeGLKVM(host: host, port: port) {
            return KVMDevice(
                id: "scanned-\(host)-\(port)",
                name: "GLKVM @ \(host):\(port)",
                host: host,
                port: port,
                type: .glinetComet,
                authToken: "",
                capabilities: [.videoStreaming, .keyboardInput, .mouseInput, .virtualMedia, .powerManagement]
            )
        }

        if await probeWebUIKeywords(host: host, port: port) {
            return KVMDevice(
                id: "scanned-\(host)-\(port)",
                name: "KVM @ \(host):\(port)",
                host: host,
                port: port,
                type: .generic,
                authToken: "",
                capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
            )
        }

        return nil
    }

    private func probeGLKVM(host: String, port: Int) async -> Bool {
        let preferredSchemes: [String] = (port == 443 || port == 8443) ? ["https", "http"] : ["http", "https"]

        let paths = [
            "api/auth/check",
            "api/init/is_inited",
        ]

        for scheme in preferredSchemes {
            for path in paths {
                guard let url = URL(string: "\(scheme)://\(host):\(port)/\(path)") else { continue }
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.timeoutInterval = 3

                do {
                    let (_, response) = try await probeSession.data(for: request)
                    guard let http = response as? HTTPURLResponse else { continue }

                    switch http.statusCode {
                    case 200, 401, 403, 301, 302, 307, 308:
                        return true
                    default:
                        continue
                    }
                } catch {
                    continue
                }
            }
        }

        return false
    }

    private func probeWebUIKeywords(host: String, port: Int) async -> Bool {
        let preferredSchemes: [String] = (port == 443 || port == 8443) ? ["https", "http"] : ["http", "https"]

        for scheme in preferredSchemes {
            guard let url = URL(string: "\(scheme)://\(host):\(port)/") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 2

            do {
                let (data, response) = try await probeSession.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                guard (200...399).contains(http.statusCode) else { continue }
                let text = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()

                if text.contains("kvmd") || text.contains("glkvm") || text.contains("comet") || text.contains("kvm") {
                    return true
                }
            } catch {
                continue
            }
        }

        return false
    }
    
    private func discoverTailscaleDevices() async -> [KVMDevice] {
        var devices: [KVMDevice] = []
        
        // Check if Tailscale is available and discover devices on Tailscale network
        let tailscaleHosts = await getTailscaleHosts()
        
        for host in tailscaleHosts {
            if let device = await checkTailscaleKVM(host: host) {
                devices.append(device)
            }
        }
        
        return devices
    }
    
    private func getTailscaleHosts() async -> [String] {
        // Get Tailscale network hosts
        // This would typically involve calling tailscale API or parsing status output
        return []
    }
    
    private func checkTailscaleKVM(host: String) async -> KVMDevice? {
        // Check common KVM ports on Tailscale hosts
        let ports = [8443, 8080, 443]
        
        for port in ports {
            if let device = await checkKVMService(host: host, port: port) {
                var tailscaleDevice = device
                tailscaleDevice.type = .tailscale
                tailscaleDevice.name = "\(device.name) (Tailscale)"
                return tailscaleDevice
            }
        }
        
        return nil
    }
    
    private func removeDuplicates(from devices: [KVMDevice]) -> [KVMDevice] {
        var uniqueDevices: [KVMDevice] = []
        var seenHosts: Set<String> = []
        
        for device in devices {
            let hostKey = "\(device.host):\(device.port)"
            if !seenHosts.contains(hostKey) {
                seenHosts.insert(hostKey)
                uniqueDevices.append(device)
            }
        }
        
        return uniqueDevices
    }
    
    @discardableResult
    func addManualDevice(host: String, port: Int, type: KVMDeviceType, authToken: String = "") -> KVMDevice {
        let device = KVMDevice(
            id: "manual-\(UUID().uuidString)",
            name: "Manual KVM @ \(host):\(port)",
            host: host,
            port: port,
            type: type,
            authToken: authToken,
            capabilities: [.videoStreaming, .keyboardInput, .mouseInput]
        )
        
        availableDevices.append(device)
        return device
    }
    
    func removeDevice(_ device: KVMDevice) {
        availableDevices.removeAll { $0.id == device.id }
        
        if connectedDevice?.id == device.id {
            connectedDevice = nil
        }
    }

    func forgetDevice(_ device: KVMDevice) {
        let host = device.host
        let port = device.port

        var current = readPersistedDevices()
        current.removeAll { $0.host == host && $0.port == port }
        writePersistedDevices(current)

        let key = credentialKey(host: host, port: port)
        Task.detached {
            DeviceTokenStore.delete(account: key)
        }
        DeviceCertificatePins.removePin(host: host, port: port)

        availableDevices.removeAll { $0.host == host && $0.port == port }
        if connectedDevice?.host == host, connectedDevice?.port == port {
            connectedDevice = nil
            glkvmClient = nil
        }
    }
    
    @discardableResult
    func connectToDevice(_ device: KVMDevice, authToken: String? = nil, password: String? = nil, user: String = "admin") async throws -> KVMDevice {
        // Validate device connection
        let isValid = try await validateDeviceConnection(device)
        guard isValid else {
            throw KVMError.connectionFailed
        }
        
        // Update device auth token if provided
        var finalDevice: KVMDevice
        if let token = authToken {
            var updatedDevice = device
            updatedDevice.authToken = token

            // Update in available devices
            if let index = availableDevices.firstIndex(where: { $0.id == device.id }) {
                availableDevices[index] = updatedDevice
            }

            finalDevice = updatedDevice
        } else {
            finalDevice = device
            if finalDevice.authToken.isEmpty {
                let key = credentialKey(host: device.host, port: device.port)
                if let storedToken = await Task.detached(operation: { DeviceTokenStore.read(account: key) }).value {
                    finalDevice.authToken = storedToken
                }
            }
        }

        guard let client = try? GLKVMClient(device: finalDevice, allowInsecureTLS: true) else {
            throw KVMError.connectionFailed
        }

        do {
            try await client.authCheck()
        } catch let mismatch as DeviceCertificateMismatch {
            // Stopped during the TLS handshake: no token was sent, and no password must be.
            throw mismatch
        } catch {
            if let password, !password.isEmpty {
                let token = try await client.authLogin(user: user, password: password)
                client.authToken = token

                var updated = finalDevice
                updated.authToken = token
                if let index = availableDevices.firstIndex(where: { $0.id == updated.id }) {
                    availableDevices[index] = updated
                }
                finalDevice = updated
            } else {
                throw KVMError.authenticationFailed
            }
        }

        // Trust on first use: pin the certificate of the first successful connection.
        if DeviceCertificatePins.pin(host: finalDevice.host, port: finalDevice.port) == nil,
           let fingerprint = client.serverCertificateFingerprint {
            DeviceCertificatePins.setPin(fingerprint, host: finalDevice.host, port: finalDevice.port)
        }

        let tokenInKeychain = await storeToken(of: finalDevice)
        let persisted = persistDevice(finalDevice, tokenInKeychain: tokenInKeychain)
        connectedDevice = persisted
        glkvmClient = client
        return persisted
    }

    /// Replaces the pin with the certificate the device presented in `mismatch`. Only that exact
    /// certificate is trusted; if the device presents yet another one, the warning appears again.
    func trustNewCertificate(_ mismatch: DeviceCertificateMismatch) {
        DeviceCertificatePins.setPin(mismatch.presentedFingerprint, host: mismatch.host, port: mismatch.port)
    }

    /// Saves the device's token in the Keychain off the main thread, so a Keychain
    /// permission prompt never blocks the UI. Returns false if the write failed.
    private func storeToken(of device: KVMDevice) async -> Bool {
        let token = device.authToken
        guard !token.isEmpty else { return true }
        let key = credentialKey(host: device.host, port: device.port)
        return await Task.detached(operation: { DeviceTokenStore.save(token, account: key) }).value
    }

    private func persistDevice(_ device: KVMDevice, tokenInKeychain: Bool) -> KVMDevice {
        var current = readPersistedDevices()
        // A freshly discovered entry for a saved host has no paste layout yet; keep the saved one.
        let existingRecord = current.first(where: { $0.host == device.host && $0.port == device.port })
        let record = PersistedDevice(
            host: device.host,
            port: device.port,
            name: device.name,
            type: device.type,
            // If the Keychain write failed, keep the token here so it is not lost;
            // the migration at the next launch moves it.
            authToken: tokenInKeychain ? "" : device.authToken,
            capabilities: device.capabilities,
            pasteKeymap: device.pasteKeymap ?? existingRecord?.pasteKeymap
        )

        if let index = current.firstIndex(where: { $0.host == device.host && $0.port == device.port }) {
            current[index] = record
        } else {
            current.append(record)
        }
        writePersistedDevices(current)

        var saved = device
        saved.id = savedDeviceId(host: device.host, port: device.port)
        saved.pasteKeymap = record.pasteKeymap

        availableDevices.removeAll { $0.host == device.host && $0.port == device.port }
        availableDevices.append(saved)
        availableDevices = removeDuplicates(from: availableDevices).sorted { $0.name < $1.name }
        return saved
    }

    private func loadPersistedDevices() {
        let records = readPersistedDevices()
        guard !records.isEmpty else { return }

        let devices: [KVMDevice] = records.map { record in
            KVMDevice(
                id: savedDeviceId(host: record.host, port: record.port),
                name: record.name,
                host: record.host,
                port: record.port,
                type: record.type,
                authToken: record.authToken,
                capabilities: record.capabilities,
                pasteKeymap: record.pasteKeymap
            )
        }
        availableDevices = removeDuplicates(from: devices).sorted { $0.name < $1.name }
    }

    /// Earlier versions stored tokens in plain text in UserDefaults. Moves them to the Keychain
    /// off the main thread, then blanks each one whose Keychain write succeeded. A failed write
    /// leaves the token in place (and in memory) to be retried at the next launch.
    private func migratePlaintextTokens() {
        let pending = readPersistedDevices()
            .filter { !$0.authToken.isEmpty }
            .map { (key: credentialKey(host: $0.host, port: $0.port), token: $0.authToken) }
        guard !pending.isEmpty else { return }

        Task {
            let migrated = await Task.detached(operation: {
                pending.filter { DeviceTokenStore.save($0.token, account: $0.key) }
            }).value
            guard !migrated.isEmpty else { return }

            var current = readPersistedDevices()
            var changed = false
            for index in current.indices {
                let key = credentialKey(host: current[index].host, port: current[index].port)
                // Skip records whose token changed since the migration started.
                guard migrated.contains(where: { $0.key == key && $0.token == current[index].authToken }) else { continue }
                current[index].authToken = ""
                changed = true
            }
            if changed {
                writePersistedDevices(current)
            }
        }
    }

    /// Sets the keyboard layout used to type pasted text on the remote computer.
    /// `nil` means Automatic: the keymap configured on the device itself.
    func setPasteKeymap(_ keymap: String?, for device: KVMDevice) {
        let host = device.host
        let port = device.port

        var current = readPersistedDevices()
        if let index = current.firstIndex(where: { $0.host == host && $0.port == port }) {
            let record = current[index]
            current[index] = PersistedDevice(
                host: record.host,
                port: record.port,
                name: record.name,
                type: record.type,
                authToken: record.authToken,
                capabilities: record.capabilities,
                pasteKeymap: keymap
            )
            writePersistedDevices(current)
        }

        for index in availableDevices.indices where availableDevices[index].host == host && availableDevices[index].port == port {
            availableDevices[index].pasteKeymap = keymap
        }
        if connectedDevice?.host == host, connectedDevice?.port == port {
            connectedDevice?.pasteKeymap = keymap
        }
    }

    private func credentialKey(host: String, port: Int) -> String {
        "\(host):\(port)"
    }

    private func savedDeviceId(host: String, port: Int) -> String {
        let safeHost = host.replacingOccurrences(of: ":", with: "_")
        return "saved-\(safeHost)-\(port)"
    }

    private func readPersistedDevices() -> [PersistedDevice] {
        guard let data = UserDefaults.standard.data(forKey: Self.savedDevicesKey) else { return [] }
        return (try? JSONDecoder().decode([PersistedDevice].self, from: data)) ?? []
    }

    private func writePersistedDevices(_ devices: [PersistedDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: Self.savedDevicesKey)
    }
    
    private func validateDeviceConnection(_ device: KVMDevice) async throws -> Bool {
        guard let port = NWEndpoint.Port(rawValue: UInt16(device.port)) else {
            return false
        }

        final class Flag {
            var value: Bool = false
        }

        let queue = DispatchQueue(label: "com.overlook.validate")
        let connection = NWConnection(host: NWEndpoint.Host(device.host), port: port, using: .tcp)

        return await withCheckedContinuation { continuation in
            let finished = Flag()

            let timeoutWorkItem = DispatchWorkItem {
                if finished.value { return }
                finished.value = true
                connection.stateUpdateHandler = nil
                connection.cancel()
                continuation.resume(returning: false)
            }

            queue.asyncAfter(deadline: .now() + 5, execute: timeoutWorkItem)

            connection.stateUpdateHandler = { (state: NWConnection.State) in
                switch state {
                case .ready:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    if finished.value { return }
                    finished.value = true
                    timeoutWorkItem.cancel()
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }
    
    func disconnectFromDevice() {
        connectedDevice = nil
        glkvmClient = nil
    }
    
    deinit {
        networkMonitor?.cancel()
        scanTimer?.invalidate()
        deviceDiscoverySessions.forEach { $0.cancel() }
    }
}

// MARK: - KVM Device Model
struct KVMDevice: Identifiable, Codable {
    var id: String
    var name: String
    let host: String
    let port: Int
    var type: KVMDeviceType
    var authToken: String
    let capabilities: Set<KVMCapability>
    /// Keyboard layout (kvmd keymap name) used to type pasted text; `nil` uses the device's keymap.
    var pasteKeymap: String? = nil
    
    var connectionString: String {
        return "\(host):\(port)"
    }

    var httpScheme: String {
        GLKVMClient.defaultHTTPScheme(for: port)
    }

    var webSocketScheme: String {
        GLKVMClient.defaultWebSocketScheme(for: port)
    }

    var originURL: String {
        return "\(httpScheme)://\(host):\(port)"
    }
    
    var webRTCURL: String {
        return "\(webSocketScheme)://\(host):\(port)/janus/ws"
    }
}

extension KVMDevice: Hashable {
    static func == (lhs: KVMDevice, rhs: KVMDevice) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum KVMDeviceType: String, Codable, CaseIterable {
    case glinetComet = "glinet_comet"
    case generic = "generic"
    case tailscale = "tailscale"
    case custom = "custom"
    
    var displayName: String {
        switch self {
        case .glinetComet:
            return "GL.iNet Comet"
        case .generic:
            return "Generic KVM"
        case .tailscale:
            return "Tailscale KVM"
        case .custom:
            return "Custom KVM"
        }
    }
}

enum KVMCapability: String, Codable, CaseIterable {
    case videoStreaming = "video_streaming"
    case keyboardInput = "keyboard_input"
    case mouseInput = "mouse_input"
    case virtualMedia = "virtual_media"
    case powerManagement = "power_management"
    case ocrSupport = "ocr_support"
    
    var displayName: String {
        switch self {
        case .videoStreaming:
            return "Video Streaming"
        case .keyboardInput:
            return "Keyboard Input"
        case .mouseInput:
            return "Mouse Input"
        case .virtualMedia:
            return "Virtual Media"
        case .powerManagement:
            return "Power Management"
        case .ocrSupport:
            return "OCR Support"
        }
    }
}

enum KVMError: Error, LocalizedError {
    case deviceNotFound
    case connectionFailed
    case authenticationFailed
    case unsupportedCapability
    case networkUnavailable
    
    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "KVM device not found"
        case .connectionFailed:
            return "Failed to connect to KVM device"
        case .authenticationFailed:
            return "Authentication failed"
        case .unsupportedCapability:
            return "Device does not support this capability"
        case .networkUnavailable:
            return "Network is not available"
        }
    }
}

// MARK: - Keychain

/// Stores device session tokens as generic-password items in the macOS Keychain:
/// service `<bundle ID>.auth-token`, account `host:port`. Items are never synchronized
/// through iCloud and are only readable after the first unlock on this Mac. Tokens are
/// never logged. The functions are synchronous; call them off the main thread.
enum DeviceTokenStore {
    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "com.rcawston.Overlook").auth-token"
    }

    /// The data protection keychain needs a keychain access group (provisioning profile).
    /// Builds without one get errSecMissingEntitlement and use the login keychain instead.
    private static let keychains = [true, false]

    private static func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    static func read(account: String) -> String? {
        for dataProtection in keychains {
            var query = baseQuery(account: account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) {
                return value
            }
            if status != errSecItemNotFound, status != errSecMissingEntitlement {
                log("read", status)
            }
        }
        return nil
    }

    static func save(_ token: String, account: String) -> Bool {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        for dataProtection in keychains {
            let status = SecItemUpdate(baseQuery(account: account, dataProtection: dataProtection) as CFDictionary, attributes as CFDictionary)
            if status == errSecSuccess {
                return true
            }
            if status != errSecItemNotFound, status != errSecMissingEntitlement {
                log("update", status)
            }
        }

        for dataProtection in keychains {
            var item = baseQuery(account: account, dataProtection: dataProtection)
            item.merge(attributes) { _, new in new }
            item[kSecAttrLabel as String] = "Overlook session for \(account)"

            let status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecSuccess {
                return true
            }
            if status != errSecMissingEntitlement {
                log("add", status)
                return false
            }
        }
        return false
    }

    static func delete(account: String) {
        for dataProtection in keychains {
            let status = SecItemDelete(baseQuery(account: account, dataProtection: dataProtection) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound, status != errSecMissingEntitlement {
                log("delete", status)
            }
        }
    }

    private static func log(_ operation: String, _ status: OSStatus) {
        NSLog("[Overlook keychain] token %@ failed: %@", operation, "\(status)")
    }
}

// MARK: - Certificate pinning

/// SHA-256 fingerprints of device certificates, pinned on first use per `host:port`.
/// GLKVM devices serve self-signed certificates that the system cannot verify, so the
/// fingerprint seen on the first successful connection is saved and every later TLS
/// connection to that address must present the same certificate. Fingerprints are not
/// secret, so they live in UserDefaults next to the saved device list.
enum DeviceCertificatePins {
    private static let defaultsKey = "overlook.certificate_pins.v1"

    private static func key(host: String, port: Int) -> String {
        "\(host.lowercased()):\(port)"
    }

    private static func readAll() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
    }

    static func pin(host: String, port: Int) -> String? {
        readAll()[key(host: host, port: port)]
    }

    static func setPin(_ fingerprint: String, host: String, port: Int) {
        var pins = readAll()
        pins[key(host: host, port: port)] = fingerprint
        UserDefaults.standard.set(pins, forKey: defaultsKey)
    }

    static func removePin(host: String, port: Int) {
        var pins = readAll()
        guard pins.removeValue(forKey: key(host: host, port: port)) != nil else { return }
        UserDefaults.standard.set(pins, forKey: defaultsKey)
    }

    /// SHA-256 of the leaf certificate's DER encoding, as uppercase hex pairs separated by
    /// colons (the format of `openssl x509 -noout -fingerprint -sha256`).
    static func leafFingerprint(of trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return nil
        }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// The first and last four bytes, for comparing fingerprints at a glance.
    static func shortForm(_ fingerprint: String) -> String {
        let bytes = fingerprint.split(separator: ":")
        guard bytes.count > 8 else { return fingerprint }
        return bytes.prefix(4).joined(separator: ":") + "…" + bytes.suffix(4).joined(separator: ":")
    }
}

/// A device presented a different certificate than the one pinned for its address.
/// The connection was stopped during the TLS handshake, before any request, token or
/// password was sent.
struct DeviceCertificateMismatch: Error, CustomStringConvertible {
    let host: String
    let port: Int
    let pinnedFingerprint: String
    let presentedFingerprint: String

    var hostPort: String {
        "\(host):\(port)"
    }

    /// The warning shown in the main window and from the menu bar.
    var warningMessage: String {
        """
        \(hostPort) presented a different certificate than the one Overlook saved for it. Overlook stopped the connection and sent nothing.

        Saved: \(DeviceCertificatePins.shortForm(pinnedFingerprint))
        Now: \(DeviceCertificatePins.shortForm(presentedFingerprint))

        This is expected after a firmware update, a reset or a regenerated certificate. Otherwise, another device may be answering at this address. Trust the new certificate only if you know why it changed.
        """
    }

    var description: String {
        "The certificate of \(hostPort) has changed (saved \(DeviceCertificatePins.shortForm(pinnedFingerprint)), now \(DeviceCertificatePins.shortForm(presentedFingerprint))). The connection was stopped and nothing was sent."
    }
}

/// The one place where Overlook evaluates TLS server trust for device connections:
/// the HTTP API and login, the `/api/ws` WebSocket (all through `GLKVMClient`),
/// Janus signaling (`WebRTCManager`) and the discovery probe.
///
/// With an endpoint, the device's self-signed certificate is accepted only if its
/// fingerprint matches the pin for `host:port`. Without a pin yet, the first certificate
/// this session sees is accepted and kept in `observedFingerprint`, so the caller can pin
/// it once the connection succeeds; later connections in the same session must match it.
/// A mismatch cancels the handshake and is kept in `mismatch`.
///
/// Without an endpoint (discovery probes, which send no credentials), any certificate is
/// accepted and nothing is pinned.
final class DeviceTLSDelegate: NSObject, URLSessionDelegate {
    private let endpoint: (host: String, port: Int)?
    private let lock = NSLock()
    private var _observedFingerprint: String?
    private var _mismatch: DeviceCertificateMismatch?

    convenience init(host: String, port: Int) {
        self.init(endpoint: (host, port))
    }

    /// Accepts any certificate without pinning. Only for requests that carry no credentials.
    static func unpinned() -> DeviceTLSDelegate {
        DeviceTLSDelegate(endpoint: nil)
    }

    private init(endpoint: (host: String, port: Int)?) {
        self.endpoint = endpoint
    }

    var observedFingerprint: String? {
        lock.lock()
        defer { lock.unlock() }
        return _observedFingerprint
    }

    var mismatch: DeviceCertificateMismatch? {
        lock.lock()
        defer { lock.unlock() }
        return _mismatch
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let endpoint else {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        guard let fingerprint = DeviceCertificatePins.leafFingerprint(of: trust),
              accept(fingerprint, host: endpoint.host, port: endpoint.port) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    private func accept(_ fingerprint: String, host: String, port: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let expected = DeviceCertificatePins.pin(host: host, port: port) ?? _observedFingerprint,
           expected != fingerprint {
            _mismatch = DeviceCertificateMismatch(host: host, port: port, pinnedFingerprint: expected, presentedFingerprint: fingerprint)
            NSLog("[Overlook tls] certificate of %@:%d changed: pinned %@, presented %@; connection stopped", host, port, expected, fingerprint)
            return false
        }

        if _observedFingerprint == nil {
            _observedFingerprint = fingerprint
        }
        return true
    }
}
