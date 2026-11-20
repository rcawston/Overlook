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
    /// Credential keys (`host:port`) of devices with a password saved in the Keychain.
    @Published private(set) var savedPasswordDeviceKeys: Set<String> = []

    /// Saved passwords that a device rejected during this session. They are never
    /// tried again automatically, so a wrong password cannot lock out the account.
    private var rejectedSavedPasswordKeys: Set<String> = []
    
    private var networkMonitor: NWPathMonitor?
    private var scanTimer: Timer?
    private var deviceDiscoverySessions: [NWBrowser] = []

    private final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
               let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config, delegate: InsecureTLSDelegate(), delegateQueue: nil)
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
        // Always written empty; tokens are kept in the Keychain. The field remains so
        // older builds can still read the saved device list.
        var authToken: String
        let capabilities: Set<KVMCapability>
    }
    
    override init() {
        super.init()
        setupNetworkMonitoring()
        loadPersistedDevices()
        savedPasswordDeviceKeys = DeviceCredentialStore.accounts(of: .password)
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
        DeviceCredentialStore.delete(.authToken, account: key)
        DeviceCredentialStore.delete(.password, account: key)
        savedPasswordDeviceKeys.remove(key)
        rejectedSavedPasswordKeys.remove(key)

        availableDevices.removeAll { $0.host == host && $0.port == port }
        if connectedDevice?.host == host, connectedDevice?.port == port {
            connectedDevice = nil
            glkvmClient = nil
        }
    }
    
    func hasSavedPassword(for device: KVMDevice) -> Bool {
        savedPasswordDeviceKeys.contains(credentialKey(host: device.host, port: device.port))
    }

    func forgetSavedPassword(for device: KVMDevice) {
        let key = credentialKey(host: device.host, port: device.port)
        DeviceCredentialStore.delete(.password, account: key)
        savedPasswordDeviceKeys.remove(key)
        rejectedSavedPasswordKeys.remove(key)
    }

    /// Connects using the device's token, or the token stored in the Keychain. When the token
    /// is missing or rejected, `password` (entered by the user) is used, or else a password
    /// saved in the Keychain. A saved password is tried at most once: if the device rejects
    /// it, this throws `KVMError.savedPasswordRejected` so the user is asked instead.
    ///
    /// `rememberPassword` applies to a successful login with `password`: `true` saves it in
    /// the Keychain, `false` removes a saved one, `nil` leaves a saved one unchanged.
    @discardableResult
    func connectToDevice(_ device: KVMDevice, authToken: String? = nil, password: String? = nil, rememberPassword: Bool? = nil, user: String = "admin") async throws -> KVMDevice {
        // Validate device connection
        let isValid = try await validateDeviceConnection(device)
        guard isValid else {
            throw KVMError.connectionFailed
        }
        
        let key = credentialKey(host: device.host, port: device.port)

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
            if finalDevice.authToken.isEmpty, let storedToken = DeviceCredentialStore.read(.authToken, account: key) {
                finalDevice.authToken = storedToken
            }
        }

        guard let client = try? GLKVMClient(device: finalDevice, allowInsecureTLS: true) else {
            throw KVMError.connectionFailed
        }

        do {
            try await client.authCheck()
        } catch {
            let tokenRejected = Self.isAuthRejection(error)
            if tokenRejected, !finalDevice.authToken.isEmpty {
                DeviceCredentialStore.delete(.authToken, account: key)
            }

            let token: String
            if let password, !password.isEmpty {
                do {
                    token = try await client.authLogin(user: user, password: password)
                } catch where Self.isLoginRejection(error) {
                    throw KVMError.passwordRejected
                }
                updateSavedPassword(password, remember: rememberPassword, key: key)
            } else if rejectedSavedPasswordKeys.contains(key) {
                throw KVMError.savedPasswordRejected
            } else if tokenRejected || finalDevice.authToken.isEmpty,
                      let savedPassword = DeviceCredentialStore.read(.password, account: key) {
                do {
                    token = try await client.authLogin(user: user, password: savedPassword)
                } catch where Self.isLoginRejection(error) {
                    rejectedSavedPasswordKeys.insert(key)
                    throw KVMError.savedPasswordRejected
                }
            } else {
                throw KVMError.authenticationFailed
            }

            client.authToken = token

            var updated = finalDevice
            updated.authToken = token
            if let index = availableDevices.firstIndex(where: { $0.id == updated.id }) {
                availableDevices[index] = updated
            }
            finalDevice = updated
        }

        let persisted = persistDevice(finalDevice)
        connectedDevice = persisted
        glkvmClient = client
        return persisted
    }

    private func updateSavedPassword(_ password: String, remember: Bool?, key: String) {
        if remember == true {
            if DeviceCredentialStore.save(password, as: .password, account: key) {
                savedPasswordDeviceKeys.insert(key)
            }
        } else if remember == false || rejectedSavedPasswordKeys.contains(key) {
            // A saved password the device rejected is known to be wrong; do not keep it.
            DeviceCredentialStore.delete(.password, account: key)
            savedPasswordDeviceKeys.remove(key)
        }
        rejectedSavedPasswordKeys.remove(key)
    }

    /// The device answered, but did not accept the token (missing, expired or revoked).
    private static func isAuthRejection(_ error: Error) -> Bool {
        if case GLKVMClient.ClientError.httpError(let statusCode, _) = error {
            return statusCode == 401 || statusCode == 403
        }
        return false
    }

    /// The device answered the login, but did not return a session: wrong password, a locked
    /// account, or an extra step such as a second factor. Transport and server errors are not
    /// rejections, because the password was not evaluated.
    private static func isLoginRejection(_ error: Error) -> Bool {
        switch error {
        case GLKVMClient.ClientError.httpError(let statusCode, _):
            return statusCode < 500
        case GLKVMClient.ClientError.decodingFailed:
            return true
        default:
            return false
        }
    }

    private func persistDevice(_ device: KVMDevice) -> KVMDevice {
        if !device.authToken.isEmpty {
            DeviceCredentialStore.save(device.authToken, as: .authToken, account: credentialKey(host: device.host, port: device.port))
        }

        let record = PersistedDevice(
            host: device.host,
            port: device.port,
            name: device.name,
            type: device.type,
            authToken: "",
            capabilities: device.capabilities
        )

        var current = readPersistedDevices()
        if let index = current.firstIndex(where: { $0.host == device.host && $0.port == device.port }) {
            current[index] = record
        } else {
            current.append(record)
        }
        writePersistedDevices(current)

        var saved = device
        saved.id = savedDeviceId(host: device.host, port: device.port)

        availableDevices.removeAll { $0.host == device.host && $0.port == device.port }
        availableDevices.append(saved)
        availableDevices = removeDuplicates(from: availableDevices).sorted { $0.name < $1.name }
        return saved
    }

    private func loadPersistedDevices() {
        var records = readPersistedDevices()
        guard !records.isEmpty else { return }

        // One-time migration: earlier versions stored tokens in plain text in UserDefaults.
        // A token stays there only if the Keychain write fails; it is retried next launch.
        var migrated = false
        for index in records.indices where !records[index].authToken.isEmpty {
            let record = records[index]
            if DeviceCredentialStore.save(record.authToken, as: .authToken, account: credentialKey(host: record.host, port: record.port)) {
                records[index].authToken = ""
                migrated = true
            }
        }
        if migrated {
            writePersistedDevices(records)
        }

        let devices: [KVMDevice] = records.map { record in
            KVMDevice(
                id: savedDeviceId(host: record.host, port: record.port),
                name: record.name,
                host: record.host,
                port: record.port,
                type: record.type,
                // Read from the Keychain when connecting.
                authToken: "",
                capabilities: record.capabilities
            )
        }
        availableDevices = removeDuplicates(from: devices).sorted { $0.name < $1.name }
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
    case passwordRejected
    case savedPasswordRejected
    
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
        case .passwordRejected:
            return "The password was not accepted"
        case .savedPasswordRejected:
            return "The saved password was not accepted"
        }
    }

    /// Errors the user resolves by entering a password.
    var promptsForPassword: Bool {
        switch self {
        case .authenticationFailed, .passwordRejected, .savedPasswordRejected:
            return true
        default:
            return false
        }
    }

    func passwordPromptMessage(deviceName: String) -> String {
        switch self {
        case .passwordRejected:
            return "\(deviceName) did not accept the password. Check it and try again."
        case .savedPasswordRejected:
            return "\(deviceName) did not accept the saved password, so it was not tried again. Enter the current password to continue."
        default:
            return "Enter the password for \(deviceName)."
        }
    }
}

// MARK: - Keychain

/// Stores device credentials as generic-password items in the macOS Keychain.
/// Items are per device (account `host:port`), never synchronized through iCloud, and
/// only readable after the first unlock on this Mac. Secrets are never logged.
enum DeviceCredentialStore {
    enum Kind: String {
        case authToken = "auth-token"
        case password

        var service: String {
            "\(Bundle.main.bundleIdentifier ?? "com.rcawston.Overlook").\(rawValue)"
        }
    }

    /// The data protection keychain needs a provisioning profile (keychain access group).
    /// Builds without one get errSecMissingEntitlement and use the login keychain instead.
    private static let keychains = [true, false]

    private static func baseQuery(_ kind: Kind, account: String?, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kind.service,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    static func read(_ kind: Kind, account: String) -> String? {
        for dataProtection in keychains {
            var query = baseQuery(kind, account: account, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) {
                return value
            }
            if status != errSecItemNotFound, status != errSecMissingEntitlement {
                log("read", kind, status)
            }
        }
        return nil
    }

    @discardableResult
    static func save(_ value: String, as kind: Kind, account: String) -> Bool {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]

        for dataProtection in keychains {
            let status = SecItemUpdate(baseQuery(kind, account: account, dataProtection: dataProtection) as CFDictionary, attributes as CFDictionary)
            if status == errSecSuccess {
                return true
            }
            if status != errSecItemNotFound, status != errSecMissingEntitlement {
                log("update", kind, status)
            }
        }

        for dataProtection in keychains {
            var item = baseQuery(kind, account: account, dataProtection: dataProtection)
            item.merge(attributes) { _, new in new }
            item[kSecAttrLabel as String] = "Overlook \(kind == .password ? "password" : "session") for \(account)"

            let status = SecItemAdd(item as CFDictionary, nil)
            if status == errSecSuccess {
                return true
            }
            if status != errSecMissingEntitlement {
                log("add", kind, status)
                return false
            }
        }
        return false
    }

    static func delete(_ kind: Kind, account: String) {
        for dataProtection in keychains {
            let status = SecItemDelete(baseQuery(kind, account: account, dataProtection: dataProtection) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound, status != errSecMissingEntitlement {
                log("delete", kind, status)
            }
        }
    }

    /// Accounts that have an item of this kind. Reads attributes only, never secrets.
    static func accounts(of kind: Kind) -> Set<String> {
        var accounts: Set<String> = []
        for dataProtection in keychains {
            var query = baseQuery(kind, account: nil, dataProtection: dataProtection)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let items = result as? [[String: Any]] {
                for item in items {
                    if let account = item[kSecAttrAccount as String] as? String {
                        accounts.insert(account)
                    }
                }
            } else if status != errSecItemNotFound, status != errSecMissingEntitlement {
                log("list", kind, status)
            }
        }
        return accounts
    }

    private static func log(_ operation: String, _ kind: Kind, _ status: OSStatus) {
        NSLog("[Overlook keychain] %@ %@ failed: %@", operation, kind.rawValue, "\(status)")
    }
}
