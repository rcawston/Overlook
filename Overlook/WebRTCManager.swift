import Foundation
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(WebRTC)
import WebRTC
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
import Network
import Combine

struct InputEvent: Codable {
    let type: String
    let data: [String: JSONValue]
    
    enum CodingKeys: String, CodingKey {
        case type
        case data
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encode(data, forKey: .data)
    }
    
    init(type: String, data: [String: JSONValue]) {
        self.type = type
        self.data = data
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        data = try container.decode([String: JSONValue].self, forKey: .data)
    }
}

#if canImport(WebRTC)
@MainActor
class WebRTCManager: NSObject, ObservableObject {
    private final class SessionDelegate: NSObject, URLSessionDelegate {
        let allowInsecureTLS: Bool

        init(allowInsecureTLS: Bool) {
            self.allowInsecureTLS = allowInsecureTLS
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard allowInsecureTLS,
                  challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }

            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    @Published var videoView: RTCMTLNSVideoView?
    @Published var isConnected = false
    @Published var latency: Int = 0
    @Published var currentFrame: CVPixelBuffer?
    @Published var videoSize: CGSize?
    @Published var inboundVideoKbps: Int?
    @Published var inboundFps: Double?
    @Published var inboundVideoPlayoutDelayMs: Int?
    @Published var inboundVideoJitterMs: Int?
    @Published var inboundVideoDecodeMs: Int?
    @Published var inboundVideoPacketsLost: Int?
    @Published var iceCurrentRoundTripTimeMs: Int?
    @Published var audioEnabled = false
    @Published var micEnabled = false
    @Published var isConnecting = false
    @Published var hasEverConnectedToStream = false
    @Published var isStreamStalled = false
    @Published var lastDisconnectReason: String?
    @Published var lastVideoFrameAgeSeconds: Int?
    
    private var peerConnection: RTCPeerConnection?
    private var videoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var localAudioSender: RTCRtpSender?
    private var dataChannel: RTCDataChannel?
    private var factory: RTCPeerConnectionFactory?
    private var connectionTimer: Timer?
    private var latencyMeasurementStart: Date?

    private var lastInboundVideoBytesReceived: Int64?
    private var lastInboundVideoBytesTimestamp: TimeInterval?

    private var fpsWindowStartTime: CFTimeInterval = 0
    private var fpsFrameCount: Int = 0
    private var lastFpsPublishTime: CFTimeInterval = 0

    private let streamHealthLock = NSLock()
    private var lastVideoFrameTime: CFTimeInterval?
    private var connectedIceTime: CFTimeInterval?
    private var streamHealthTimer: Timer?

    private let streamStallThresholdSeconds: CFTimeInterval = 3.0
    private let initialFrameTimeoutSeconds: CFTimeInterval = 5.0
    
    private let allowInsecureTLS = true
    private var signalingSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?

    private var janusSessionId: Int?
    private var janusHandleId: Int?
    private var janusKeepAliveTimer: Timer?
    private var janusWaiters: [String: CheckedContinuation<[String: Any], Error>] = [:]

    private var isFrameCaptureEnabled: Bool = false
    private var lastFrameCaptureTime: CFTimeInterval = 0
    
    override init() {
        super.init()
        setupWebRTC()
    }
    
    private func setupWebRTC() {
        // Initialize WebRTC factory with hardware acceleration
        let encoderFactory = RTCDefaultVideoEncoderFactory()
        let decoderFactory = RTCDefaultVideoDecoderFactory()
        
        factory = RTCPeerConnectionFactory(
            encoderFactory: encoderFactory,
            decoderFactory: decoderFactory
        )
        
        // Setup video view
        videoView = RTCMTLNSVideoView(frame: .zero)
    }
    
    func connect(to device: KVMDevice) async throws {
        guard let factory = factory else {
            throw WebRTCError.factoryNotInitialized
        }

        isConnecting = true
        isStreamStalled = false
        lastDisconnectReason = nil
        lastVideoFrameAgeSeconds = nil
        streamHealthLock.lock()
        lastVideoFrameTime = nil
        streamHealthLock.unlock()
        connectedIceTime = nil
        hasEverConnectedToStream = false

        do {
            if videoView == nil {
                videoView = RTCMTLNSVideoView(frame: .zero)
            }
            
            // Create peer connection
            let configuration = RTCConfiguration()
            configuration.iceServers = [
                RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
            ]
            configuration.sdpSemantics = .unifiedPlan
            
            let constraints = RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: ["OfferToReceiveVideo": "true"]
            )
            
            peerConnection = factory.peerConnection(
                with: configuration,
                constraints: constraints,
                delegate: self
            )

            if micEnabled {
                let granted = await ensureMicrophoneAccess()
                if granted {
                    setupLocalMicrophoneTrackIfNeeded(factory: factory)
                }
            }
            
            // Setup data channel for input events
            setupDataChannel()
            
            // Connect to signaling server
            try await connectToSignalingServer(device: device)
            
            // Start connection quality monitoring
            startLatencyMonitoring()
            startStreamHealthMonitoring()
        } catch {
            let reason = "Connect failed: \(String(describing: error))"
            disconnect()
            lastDisconnectReason = reason
            throw error
        }
    }

    func reconnect(to device: KVMDevice) async {
        disconnect()
        do {
            try await connect(to: device)
        } catch {
            isConnecting = false
            lastDisconnectReason = "Reconnect failed: \(String(describing: error))"
        }
    }

    func setFrameCaptureEnabled(_ enabled: Bool) {
        isFrameCaptureEnabled = enabled

        if enabled == false {
            currentFrame = nil
        }
    }
    
    private func setupDataChannel() {
        guard let peerConnection = peerConnection else { return }
        
        let dataChannelConfig = RTCDataChannelConfiguration()
        dataChannelConfig.isOrdered = true
        dataChannelConfig.isNegotiated = false
        dataChannelConfig.channelId = 0
        
        dataChannel = peerConnection.dataChannel(
            forLabel: "input-events",
            configuration: dataChannelConfig
        )
        dataChannel?.delegate = self
    }
    
    private func connectToSignalingServer(device: KVMDevice) async throws {
        guard let rawURL = URL(string: device.webRTCURL) else {
            throw WebRTCError.invalidSignalingURL
        }

        let url = normalizedWebSocketURL(rawURL)
        print("WebRTC signaling connect: \(url.absoluteString)")

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: SessionDelegate(allowInsecureTLS: allowInsecureTLS), delegateQueue: nil)
        signalingSession = session

        var request = URLRequest(url: url)
        if !device.authToken.isEmpty {
            request.setValue("auth_token=\(device.authToken)", forHTTPHeaderField: "Cookie")
        }
        request.setValue("https://\(device.host):\(device.port)", forHTTPHeaderField: "Origin")
        request.setValue("janus-protocol", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        webSocketTask = session.webSocketTask(with: request)
        
        webSocketTask?.resume()

        Task {
            await listenForSignalingMessages()
        }

        // Janus session setup
        let createTransaction = makeJanusTransaction()
        try await sendJanusMessage([
            "janus": "create",
            "transaction": createTransaction,
        ])

        let createResponse = try await waitForJanusTransaction(createTransaction)
        guard let data = createResponse["data"] as? [String: Any],
              let sessionId = data["id"] as? Int else {
            throw WebRTCError.signalingConnectionLost
        }
        janusSessionId = sessionId

        let attachTransaction = makeJanusTransaction()
        try await sendJanusMessage([
            "janus": "attach",
            "plugin": "janus.plugin.ustreamer",
            "opaque_id": "oid-\(UUID().uuidString)",
            "transaction": attachTransaction,
            "session_id": sessionId,
        ])

        let attachResponse = try await waitForJanusTransaction(attachTransaction)
        guard let attachData = attachResponse["data"] as? [String: Any],
              let handleId = attachData["id"] as? Int else {
            throw WebRTCError.signalingConnectionLost
        }
        janusHandleId = handleId

        // Request to start watching video stream
        let watchTransaction = makeJanusTransaction()
        try await sendJanusMessage([
            "janus": "message",
            "body": [
                "request": "watch",
                "params": [
                    "orientation": 0,
                    "audio": audioEnabled,
                    "video": true,
                    "mic": micEnabled,
                    "camera": false,
                ],
            ],
            "transaction": watchTransaction,
            "session_id": sessionId,
            "handle_id": handleId,
        ])

        startJanusKeepAlive()
    }

    private func startJanusKeepAlive() {
        janusKeepAliveTimer?.invalidate()
        janusKeepAliveTimer = Timer.scheduledTimer(withTimeInterval: 25.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await self.sendJanusKeepAlive()
                } catch {
                    // Ignore keepalive errors, next user action will reconnect
                }
            }
        }
    }

    private func sendJanusKeepAlive() async throws {
        guard let sessionId = janusSessionId else { return }
        try await sendJanusMessage([
            "janus": "keepalive",
            "session_id": sessionId,
            "transaction": makeJanusTransaction(),
        ])
    }

    private func sendJanusTrickleCandidate(_ candidate: RTCIceCandidate) async throws {
        guard let sessionId = janusSessionId,
              let handleId = janusHandleId else {
            return
        }

        try await sendJanusMessage([
            "janus": "trickle",
            "candidate": [
                "candidate": candidate.sdp,
                "sdpMid": candidate.sdpMid ?? "0",
                "sdpMLineIndex": Int(candidate.sdpMLineIndex),
            ],
            "transaction": makeJanusTransaction(),
            "session_id": sessionId,
            "handle_id": handleId,
        ])
    }

    private func sendJanusTrickleCompleted() async throws {
        guard let sessionId = janusSessionId,
              let handleId = janusHandleId else {
            return
        }

        try await sendJanusMessage([
            "janus": "trickle",
            "candidate": ["completed": true],
            "transaction": makeJanusTransaction(),
            "session_id": sessionId,
            "handle_id": handleId,
        ])
    }

    private func makeJanusTransaction() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func waitForJanusTransaction(_ transaction: String) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            janusWaiters[transaction] = continuation
        }
    }

    private func sendJanusMessage(_ message: [String: Any]) async throws {
        guard let webSocketTask = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            throw WebRTCError.signalingConnectionLost
        }
        try await webSocketTask.send(.string(text))
    }

    private func normalizedWebSocketURL(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        if comps.scheme == "https" {
            comps.scheme = "wss"
        } else if comps.scheme == "http" {
            comps.scheme = "ws"
        } else if comps.scheme == nil {
            comps.scheme = "wss"
        }

        return comps.url ?? url
    }
    
    private func listenForSignalingMessages() async {
        while let webSocketTask = webSocketTask {
            do {
                let message = try await webSocketTask.receive()
                await handleSignalingMessage(message)
            } catch {
                print("WebSocket receive error: \(error)")
                isConnecting = false
                if isConnected || hasEverConnectedToStream || lastDisconnectReason == nil {
                    lastDisconnectReason = "Signaling connection lost"
                }
                break
            }
        }
    }
    
    private func handleSignalingMessage(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .string(let string):
            guard let data = string.data(using: .utf8),
                  let signalingMessage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            await handleJanusMessage(signalingMessage)
            
        case .data(let data):
            guard let signalingMessage = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            await handleJanusMessage(signalingMessage)
            
        @unknown default:
            break
        }
    }

    private func handleJanusMessage(_ message: [String: Any]) async {
        if let transaction = message["transaction"] as? String,
           let waiter = janusWaiters.removeValue(forKey: transaction) {
            waiter.resume(returning: message)
            return
        }

        guard let janusType = message["janus"] as? String else { return }
        if janusType == "trickle" {
            guard let candidateObj = message["candidate"] as? [String: Any],
                  let candidateString = candidateObj["candidate"] as? String,
                  let peerConnection = peerConnection else {
                return
            }

            if (candidateObj["completed"] as? Bool) == true {
                return
            }

            let sdpMid = candidateObj["sdpMid"] as? String
            let sdpMLineIndex: Int32
            if let idx32 = candidateObj["sdpMLineIndex"] as? Int32 {
                sdpMLineIndex = idx32
            } else if let idx = candidateObj["sdpMLineIndex"] as? Int {
                sdpMLineIndex = Int32(idx)
            } else {
                sdpMLineIndex = 0
            }
            let iceCandidate = RTCIceCandidate(sdp: candidateString, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
            peerConnection.add(iceCandidate) { _ in }
            return
        }

        if janusType != "event" { return }

        guard let jsep = message["jsep"] as? [String: Any],
              let jsepType = jsep["type"] as? String,
              jsepType == "offer",
              let sdpString = jsep["sdp"] as? String else {
            return
        }

        await handleOfferSDP(sdpString)
    }
    
    private func handleOfferSDP(_ sdpString: String) async {
        guard let peerConnection = peerConnection else { return }
        
        let sessionDescription = RTCSessionDescription(
            type: .offer,
            sdp: sdpString
        )
        
        await withCheckedContinuation { continuation in
            peerConnection.setRemoteDescription(sessionDescription) { error in
                if let error = error {
                    print("Failed to set remote description: \(error)")
                }
                continuation.resume()
            }
        }
        
        // Create and send answer
        await createAndSendAnswer()
    }
    
    private func createAndSendAnswer() async {
        guard let peerConnection = peerConnection else { return }
        
        await withCheckedContinuation { continuation in
            peerConnection.answer(for: RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: nil
            )) { sessionDescription, error in
                if let error = error {
                    print("Failed to create answer: \(error)")
                    continuation.resume()
                    return
                }
                
                guard let sessionDescription = sessionDescription else {
                    continuation.resume()
                    return
                }
                
                peerConnection.setLocalDescription(sessionDescription) { error in
                    if let error = error {
                        print("Failed to set local description: \(error)")
                    }
                    continuation.resume()
                }
            }
        }
        
        // Send answer to Janus
        guard let localDescription = peerConnection.localDescription,
              let sessionId = janusSessionId,
              let handleId = janusHandleId else {
            return
        }

        let startTransaction = makeJanusTransaction()
        do {
            try await sendJanusMessage([
                "janus": "message",
                "body": ["request": "start"],
                "transaction": startTransaction,
                "session_id": sessionId,
                "handle_id": handleId,
                "jsep": [
                    "type": "answer",
                    "sdp": localDescription.sdp,
                ],
            ])
        } catch {
            print("Failed to send Janus answer: \(error)")
        }
    }
    
    private func startLatencyMonitoring() {
        connectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task {
                await self.measureLatency()
                await self.measureStreamStats()
            }
        }
    }

    private func startStreamHealthMonitoring() {
        streamHealthTimer?.invalidate()
        streamHealthTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }

            let now = CACurrentMediaTime()

            if self.isConnected == false {
                self.isStreamStalled = false
                self.lastVideoFrameAgeSeconds = nil
                return
            }

            let lastFrame: CFTimeInterval?
            self.streamHealthLock.lock()
            lastFrame = self.lastVideoFrameTime
            self.streamHealthLock.unlock()

            let age: CFTimeInterval?
            if let lastFrame {
                age = now - lastFrame
            } else {
                age = nil
            }

            if let age {
                self.lastVideoFrameAgeSeconds = max(0, Int(age.rounded()))
            } else {
                self.lastVideoFrameAgeSeconds = nil
            }

            if let age, age > self.streamStallThresholdSeconds {
                if self.isStreamStalled == false {
                    self.isStreamStalled = true
                    self.lastDisconnectReason = "Video stream stalled"
                }
                return
            }

            if self.lastVideoFrameTime == nil,
               let connectedAt = self.connectedIceTime,
               now - connectedAt > self.initialFrameTimeoutSeconds {
                if self.isStreamStalled == false {
                    self.isStreamStalled = true
                    self.lastDisconnectReason = "Video stream stalled"
                }
                return
            }

            if self.isStreamStalled {
                self.isStreamStalled = false
                self.lastDisconnectReason = nil
            }
        }
    }

    private func measureStreamStats() async {
        guard let peerConnection else {
            await MainActor.run {
                inboundVideoKbps = nil
                inboundVideoPlayoutDelayMs = nil
                inboundVideoJitterMs = nil
                inboundVideoDecodeMs = nil
                inboundVideoPacketsLost = nil
                iceCurrentRoundTripTimeMs = nil
            }
            return
        }

        let lastBytes = lastInboundVideoBytesReceived
        let lastTs = lastInboundVideoBytesTimestamp

        peerConnection.statistics { report in
            func numberValue(_ any: Any?) -> NSNumber? {
                any as? NSNumber
            }

            var bytesReceived: Int64?
            var jitterSeconds: Double?
            var jitterBufferDelaySeconds: Double?
            var jitterBufferEmittedCount: Double?
            var totalDecodeTimeSeconds: Double?
            var framesDecoded: Double?
            var packetsLost: Int?

            var currentRoundTripTimeSeconds: Double?

            for statistic in report.statistics.values {
                if statistic.type == "candidate-pair" {
                    let selected = (statistic.values["selected"] as? Bool)
                        ?? (numberValue(statistic.values["selected"])?.boolValue)
                        ?? false
                    guard selected else { continue }

                    if let rtt = numberValue(statistic.values["currentRoundTripTime"])?.doubleValue {
                        currentRoundTripTimeSeconds = rtt
                    }
                    continue
                }

                guard statistic.type == "inbound-rtp" else { continue }

                if let kind = statistic.values["kind"] as? String, kind != "video" { continue }
                if let mediaType = statistic.values["mediaType"] as? String, mediaType != "video" { continue }

                if let n = numberValue(statistic.values["bytesReceived"]) {
                    bytesReceived = n.int64Value
                }
                if let n = numberValue(statistic.values["jitter"]) {
                    jitterSeconds = n.doubleValue
                }
                if let n = numberValue(statistic.values["jitterBufferDelay"]) {
                    jitterBufferDelaySeconds = n.doubleValue
                }
                if let n = numberValue(statistic.values["jitterBufferEmittedCount"]) {
                    jitterBufferEmittedCount = n.doubleValue
                }
                if let n = numberValue(statistic.values["totalDecodeTime"]) {
                    totalDecodeTimeSeconds = n.doubleValue
                }
                if let n = numberValue(statistic.values["framesDecoded"]) {
                    framesDecoded = n.doubleValue
                }
                if let n = numberValue(statistic.values["packetsLost"]) {
                    packetsLost = n.intValue
                }

                break
            }

            let now = Date().timeIntervalSince1970

            guard let bytesReceived else {
                Task { @MainActor in
                    self.lastInboundVideoBytesReceived = nil
                    self.lastInboundVideoBytesTimestamp = nil
                    self.inboundVideoKbps = nil
                    self.inboundVideoPlayoutDelayMs = nil
                    self.inboundVideoJitterMs = nil
                    self.inboundVideoDecodeMs = nil
                    self.inboundVideoPacketsLost = nil
                    self.iceCurrentRoundTripTimeMs = nil
                }
                return
            }

            var kbps: Int?
            if let lastBytes, let lastTs {
                let dt = now - lastTs
                let db = Double(bytesReceived - lastBytes)
                if dt > 0, db >= 0 {
                    kbps = Int((db * 8.0 / dt) / 1000.0)
                }
            }

            let jitterMs: Int?
            if let jitterSeconds {
                jitterMs = Int((jitterSeconds * 1000.0).rounded())
            } else {
                jitterMs = nil
            }

            let playoutDelayMs: Int?
            if let jitterBufferDelaySeconds,
               let jitterBufferEmittedCount,
               jitterBufferEmittedCount > 0 {
                playoutDelayMs = Int(((jitterBufferDelaySeconds / jitterBufferEmittedCount) * 1000.0).rounded())
            } else {
                playoutDelayMs = nil
            }

            let decodeMs: Int?
            if let totalDecodeTimeSeconds,
               let framesDecoded,
               framesDecoded > 0 {
                decodeMs = Int(((totalDecodeTimeSeconds / framesDecoded) * 1000.0).rounded())
            } else {
                decodeMs = nil
            }

            let rttMs: Int?
            if let currentRoundTripTimeSeconds {
                rttMs = Int((currentRoundTripTimeSeconds * 1000.0).rounded())
            } else {
                rttMs = nil
            }

            Task { @MainActor in
                self.lastInboundVideoBytesReceived = bytesReceived
                self.lastInboundVideoBytesTimestamp = now
                self.inboundVideoKbps = kbps
                self.inboundVideoPlayoutDelayMs = playoutDelayMs
                self.inboundVideoJitterMs = jitterMs
                self.inboundVideoDecodeMs = decodeMs
                self.inboundVideoPacketsLost = packetsLost
                self.iceCurrentRoundTripTimeMs = rttMs
            }
        }
    }
    
    private func measureLatency() async {
        latencyMeasurementStart = Date()
        
        // Send ping message through data channel
        let pingMessage: [String: Any] = ["type": "ping", "timestamp": Date().timeIntervalSince1970]
        
        guard let data = try? JSONSerialization.data(withJSONObject: pingMessage) else {
            return
        }
        
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        dataChannel?.sendData(buffer)
    }
    
    func sendInputEvent(_ event: InputEvent) {
        guard let data = try? JSONEncoder().encode(event),
              let dataChannel = dataChannel,
              dataChannel.readyState == .open else {
            return
        }
        
        let buffer = RTCDataBuffer(data: data, isBinary: true)
        dataChannel.sendData(buffer)
    }
    
    func disconnect() {
        connectionTimer?.invalidate()
        connectionTimer = nil

        streamHealthTimer?.invalidate()
        streamHealthTimer = nil

        janusKeepAliveTimer?.invalidate()
        janusKeepAliveTimer = nil
        janusSessionId = nil
        janusHandleId = nil
        let waiters = janusWaiters
        janusWaiters.removeAll()
        for (_, waiter) in waiters {
            waiter.resume(throwing: WebRTCError.signalingConnectionLost)
        }
        
        webSocketTask?.cancel()
        webSocketTask = nil
        
        dataChannel?.close()
        dataChannel = nil
        
        peerConnection?.close()
        peerConnection = nil

        localAudioSender = nil
        localAudioTrack = nil
        
        videoView = nil
        isConnected = false
        isConnecting = false
        hasEverConnectedToStream = false
        isStreamStalled = false
        lastDisconnectReason = nil
        lastVideoFrameAgeSeconds = nil
        streamHealthLock.lock()
        lastVideoFrameTime = nil
        streamHealthLock.unlock()
        connectedIceTime = nil
        latency = 0
        videoSize = nil
        isFrameCaptureEnabled = false
        inboundVideoKbps = nil
        inboundFps = nil
        inboundVideoPlayoutDelayMs = nil
        inboundVideoJitterMs = nil
        inboundVideoDecodeMs = nil
        inboundVideoPacketsLost = nil
        iceCurrentRoundTripTimeMs = nil
        lastInboundVideoBytesReceived = nil
        lastInboundVideoBytesTimestamp = nil
        fpsWindowStartTime = 0
        fpsFrameCount = 0
        lastFpsPublishTime = 0
    }

    private func ensureMicrophoneAccess() async -> Bool {
#if canImport(AVFoundation)
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
#else
        return false
#endif
    }

    private func setupLocalMicrophoneTrackIfNeeded(factory: RTCPeerConnectionFactory) {
        guard localAudioTrack == nil else { return }
        guard let peerConnection else { return }

        let audioSource = factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "audio0")
        localAudioTrack = audioTrack
        localAudioSender = peerConnection.add(audioTrack, streamIds: ["stream0"])
    }
}

// MARK: - RTCPeerConnectionDelegate
extension WebRTCManager: @preconcurrency RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        Task { @MainActor in
            print("Signaling state changed: \(stateChanged)")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor in
            print("Media stream added")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Task { @MainActor in
            print("Media stream removed")
        }
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        Task { @MainActor in
            print("Should negotiate")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceConnectionState) {
        Task { @MainActor in
            isConnected = (stateChanged == .connected || stateChanged == .completed)
            if isConnected {
                isConnecting = false
                hasEverConnectedToStream = true
                connectedIceTime = CACurrentMediaTime()
                lastDisconnectReason = nil
            } else {
                if stateChanged == .disconnected {
                    lastDisconnectReason = "Video connection lost"
                    isConnecting = false
                } else if stateChanged == .failed {
                    lastDisconnectReason = "Video connection failed"
                    isConnecting = false
                } else if stateChanged == .closed {
                    lastDisconnectReason = "Video connection closed"
                    isConnecting = false
                }
            }
            print("ICE connection state changed: \(stateChanged)")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCIceGatheringState) {
        Task { @MainActor in
            print("ICE gathering state changed: \(stateChanged)")

            if stateChanged == .complete {
                do {
                    try await sendJanusTrickleCompleted()
                } catch {
                    // ignore
                }
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            do {
                try await sendJanusTrickleCandidate(candidate)
            } catch {
                print("Failed to send Janus ICE candidate: \(error)")
            }
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        Task { @MainActor in
            print("ICE candidates removed")
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor in
            print("Data channel opened")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        videoTrack = track
        if let videoView {
            track.add(videoView)
        }
        track.add(self)
    }
}

// MARK: - RTCDataChannelDelegate
extension WebRTCManager: @preconcurrency RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor in
            print("Data channel state changed: \(dataChannel.readyState)")
        }
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard buffer.isBinary,
              let message = try? JSONDecoder().decode(InputMessage.self, from: buffer.data) else {
            return
        }
        
        Task { @MainActor in
            await handleDataChannelMessage(message)
        }
    }
    
    private func handleDataChannelMessage(_ message: InputMessage) async {
        switch message.type {
        case "pong":
            if let startTime = latencyMeasurementStart {
                latency = Int(Date().timeIntervalSince(startTime) * 1000)
                latencyMeasurementStart = nil
            }
        case "video-frame":
            // Handle video frame metadata if needed
            break
        default:
            break
        }
    }
 }

// MARK: - RTCVideoRenderer
extension WebRTCManager: @preconcurrency RTCVideoRenderer {
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }

        let now = CACurrentMediaTime()

        streamHealthLock.lock()
        lastVideoFrameTime = now
        streamHealthLock.unlock()

        if fpsWindowStartTime == 0 {
            fpsWindowStartTime = now
            lastFpsPublishTime = now
        }

        fpsFrameCount += 1

        if now - lastFpsPublishTime >= 0.5 {
            let dt = now - fpsWindowStartTime
            if dt > 0 {
                let fps = Double(fpsFrameCount) / dt
                Task { @MainActor in
                    inboundFps = fps
                }
            }
            fpsWindowStartTime = now
            fpsFrameCount = 0
            lastFpsPublishTime = now
        }

        guard isFrameCaptureEnabled else { return }

        let minInterval: CFTimeInterval = 1.0 / 12.0
        if now - lastFrameCaptureTime < minInterval {
            return
        }
        lastFrameCaptureTime = now

        if let cvBuffer = frame.buffer as? RTCCVPixelBuffer {
            let pb = cvBuffer.pixelBuffer
            Task { @MainActor in
                currentFrame = pb
            }
        }
    }
    
    func setSize(_ size: CGSize) {
        Task { @MainActor in
            if size.width > 0, size.height > 0 {
                videoSize = size
            }
        }
    }
}

// MARK: - Supporting Types
enum WebRTCError: Error {
    case factoryNotInitialized
    case invalidSignalingURL
    case signalingConnectionLost
    case peerConnectionFailed
}

struct InputMessage: Codable {
    let type: String
    let timestamp: TimeInterval?
}

#else

@MainActor
final class WebRTCManager: NSObject, ObservableObject {
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var hasEverConnectedToStream = false
    @Published var isStreamStalled = false
    @Published var lastDisconnectReason: String?
    @Published var lastVideoFrameAgeSeconds: Int?
    @Published var latency: Int = 0
    @Published var currentFrame: CVPixelBuffer?
    @Published var audioEnabled = false
    @Published var micEnabled = false
    
    func connect(to device: KVMDevice) async throws {
        isConnected = false
    }

    func reconnect(to device: KVMDevice) async {
        disconnect()
    }
    
    func sendInputEvent(_ event: InputEvent) {
    }
    
    func disconnect() {
        isConnected = false
        isConnecting = false
        hasEverConnectedToStream = false
        isStreamStalled = false
        lastDisconnectReason = nil
        lastVideoFrameAgeSeconds = nil
        latency = 0
        currentFrame = nil
    }
}

#endif
