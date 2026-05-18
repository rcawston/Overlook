import Foundation

typealias GLKVMJSONObject = [String: JSONValue]

struct GLKVMResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result
}

struct GLKVMEmptyResult: Decodable {}

struct GLKVMInitStatus: Decodable {
    let countryCode: String
    let isInited: Bool

    enum CodingKeys: String, CodingKey {
        case countryCode = "country_code"
        case isInited = "is_inited"
    }
}

struct GLKVMSystemGetConfigResult: Decodable {
    let config: GLKVMSystemConfig
}

struct GLKVMSystemConfigShortcut: Codable, Hashable {
    let keys: [String]
    let label: String
}

struct GLKVMSystemConfig: Codable, Hashable {
    var shortcuts: [GLKVMSystemConfigShortcut]
    var orientation: Int
    var streamQuality: Int
    var videoMode: String
    var showCursor: Bool
    var mousePolling: Int
    var mouseControl: Bool
    var relativeSense: Int
    var scrollRate: Int
    var reverseScrolling: String
    var keyboardControl: Bool
    var themeMode: String
    var mouseJiggle: Bool
    var keymap: String
    var gotMutedPanelTip: Bool
    var isAbsoluteMouse: Bool
    var fingerbotStrength: Int
    var videoProcessing: String

    enum CodingKeys: String, CodingKey {
        case shortcuts
        case orientation
        case streamQuality = "stream_quality"
        case videoMode = "video_mode"
        case showCursor = "show_cursor"
        case mousePolling = "mouse_polling"
        case mouseControl = "mouse_control"
        case relativeSense = "relative_sense"
        case scrollRate = "scroll_rate"
        case reverseScrolling = "reverse_scrolling"
        case keyboardControl = "keyboard_control"
        case themeMode = "theme_mode"
        case mouseJiggle = "mouse_jiggle"
        case keymap
        case gotMutedPanelTip = "got_muted_panel_tip"
        case isAbsoluteMouse = "is_absolute_mouse"
        case fingerbotStrength = "fingerbot_strength"
        case videoProcessing = "video_processing"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        shortcuts = (try? container.decode([GLKVMSystemConfigShortcut].self, forKey: .shortcuts)) ?? []
        orientation = (try? container.decode(Int.self, forKey: .orientation)) ?? 0
        streamQuality = (try? container.decode(Int.self, forKey: .streamQuality)) ?? 1
        videoMode = (try? container.decode(String.self, forKey: .videoMode)) ?? ""
        showCursor = (try? container.decode(Bool.self, forKey: .showCursor)) ?? true
        mousePolling = (try? container.decode(Int.self, forKey: .mousePolling)) ?? 10
        mouseControl = (try? container.decode(Bool.self, forKey: .mouseControl)) ?? true
        relativeSense = (try? container.decode(Int.self, forKey: .relativeSense)) ?? 10
        scrollRate = (try? container.decode(Int.self, forKey: .scrollRate)) ?? 5
        reverseScrolling = (try? container.decode(String.self, forKey: .reverseScrolling)) ?? "STANDARD"
        keyboardControl = (try? container.decode(Bool.self, forKey: .keyboardControl)) ?? true
        themeMode = (try? container.decode(String.self, forKey: .themeMode)) ?? "auto"
        mouseJiggle = (try? container.decode(Bool.self, forKey: .mouseJiggle)) ?? false
        keymap = (try? container.decode(String.self, forKey: .keymap)) ?? "en-us"
        gotMutedPanelTip = (try? container.decode(Bool.self, forKey: .gotMutedPanelTip)) ?? false
        isAbsoluteMouse = (try? container.decode(Bool.self, forKey: .isAbsoluteMouse)) ?? true
        fingerbotStrength = (try? container.decode(Int.self, forKey: .fingerbotStrength)) ?? 0
        videoProcessing = (try? container.decode(String.self, forKey: .videoProcessing)) ?? ""
    }
}

struct GLKVMTurnCredentials: Decodable {
    let password: String
    let ttl: Int
    let uris: [String]
    let username: String
}

struct GLKVMHidKeymapsState: Decodable, Hashable {
    struct Keymaps: Decodable, Hashable {
        let `default`: String
        let available: [String]
    }

    let keymaps: Keymaps
}

struct GLKVMStreamerState: Decodable, Hashable {
    struct Features: Decodable, Hashable {
        let quality: Bool
        let resolution: Bool
        let h264: Bool
        let zeroDelay: Bool

        enum CodingKeys: String, CodingKey {
            case quality
            case resolution
            case h264
            case zeroDelay = "zero_delay"
        }
    }

    struct Limits: Decodable, Hashable {
        struct MinMax: Decodable, Hashable {
            let min: Int
            let max: Int
        }

        let desiredFps: MinMax
        let h264Bitrate: MinMax
        let h264Gop: MinMax

        enum CodingKeys: String, CodingKey {
            case desiredFps = "desired_fps"
            case h264Bitrate = "h264_bitrate"
            case h264Gop = "h264_gop"
        }
    }

    struct Params: Decodable, Hashable {
        let desiredFps: Int?
        let quality: Int?
        let h264Bitrate: Int?
        let h264Gop: Int?
        let zeroDelay: Bool?
        let resolution: String?

        enum CodingKeys: String, CodingKey {
            case desiredFps = "desired_fps"
            case quality
            case h264Bitrate = "h264_bitrate"
            case h264Gop = "h264_gop"
            case zeroDelay = "zero_delay"
            case resolution
        }
    }

    let features: Features?
    let limits: Limits?
    let params: Params?
}

struct GLKVMMSDPartitionDevice: Decodable, Hashable {
    let path: String
    let size: Int
    let uuid: String
    let filesystem: String
    let label: String
    let isCurrent: Bool

    enum CodingKeys: String, CodingKey {
        case path
        case size
        case uuid
        case filesystem
        case label
        case isCurrent = "is_current"
    }
}

struct GLKVMMSDPartitionShowResult: Decodable, Hashable {
    let devices: [String: GLKVMMSDPartitionDevice]
}

struct GLKVMMSDWriteImageInfo: Decodable, Hashable {
    let name: String
    let size: Int
    let written: Int
}

struct GLKVMMSDWriteResult: Decodable, Hashable {
    let image: GLKVMMSDWriteImageInfo
}

struct GLKVMWebSocketEvent: Decodable, Hashable {
    let eventType: String
    let event: JSONValue?

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case event
    }
}

struct GLKVMWebSocketSend: Encodable {
    let eventType: String
    let event: JSONValue

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case event
    }
}

struct GLKVMAuthLoginResult: Decodable {
    let token: String?

    enum CodingKeys: String, CodingKey {
        case token
        case authToken = "auth_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = try container.decodeIfPresent(String.self, forKey: .token)
            ?? container.decodeIfPresent(String.self, forKey: .authToken)
    }
}

final class GLKVMClient {
    enum ClientError: Error {
        case invalidBaseURL
        case invalidURL
        case httpError(statusCode: Int, body: String?)
        case decodingFailed
    }

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

    let baseURL: URL
    var authToken: String?

    private let session: URLSession

    init(host: String, port: Int = 443, authToken: String? = nil, allowInsecureTLS: Bool = true) throws {
        let scheme = Self.defaultHTTPScheme(for: port)
        guard let url = URL(string: "\(scheme)://\(host):\(port)") else {
            throw ClientError.invalidBaseURL
        }

        self.baseURL = url
        self.authToken = authToken

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30

        self.session = URLSession(configuration: config, delegate: SessionDelegate(allowInsecureTLS: allowInsecureTLS), delegateQueue: nil)
    }

    static func defaultHTTPScheme(for port: Int) -> String {
        switch port {
        case 80, 8080:
            return "http"
        default:
            return "https"
        }
    }

    static func defaultWebSocketScheme(for port: Int) -> String {
        defaultHTTPScheme(for: port) == "https" ? "wss" : "ws"
    }

    convenience init(device: KVMDevice, allowInsecureTLS: Bool = true) throws {
        try self.init(host: device.host, port: device.port, authToken: device.authToken.isEmpty ? nil : device.authToken, allowInsecureTLS: allowInsecureTLS)
    }

    private func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidURL
        }

        components.path = "/" + trimmed
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw ClientError.invalidURL
        }

        return url
    }

    private func request<Response: Decodable>(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        responseType: Response.Type
    ) async throws -> Response {
        let url = try makeURL(path: path, queryItems: query)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        if let authToken, !authToken.isEmpty {
            request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decodingFailed
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            var errorMessage: String? = nil
            if let wrapped = try? JSONDecoder().decode(GLKVMResponse<GLKVMJSONObject>.self, from: data) {
                if case .string(let s) = wrapped.result["error_msg"] {
                    errorMessage = s
                } else if case .string(let s) = wrapped.result["message"] {
                    errorMessage = s
                }
            }
            throw ClientError.httpError(statusCode: http.statusCode, body: errorMessage ?? bodyString)
        }

        let decoder = JSONDecoder()
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary \(data.count)B>"
            NSLog("[Overlook glkvm] decode failed for %@ (status=%d): %@ | body: %@", url.absoluteString, http.statusCode, "\(error)", preview)
            throw ClientError.decodingFailed
        }
    }

    func isInited() async throws -> GLKVMInitStatus {
        let response = try await request(
            method: "GET",
            path: "api/init/is_inited",
            responseType: GLKVMResponse<GLKVMInitStatus>.self
        )

        return response.result
    }

    func authCheck() async throws {
        _ = try await request(
            method: "GET",
            path: "api/auth/check",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func authLogin(user: String = "admin", password: String) async throws -> String {
        let boundary = "----OverlookBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"user\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append("\(user)\r\n".data(using: .utf8) ?? Data())
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"passwd\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append("\(password)\r\n".data(using: .utf8) ?? Data())
        body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())

        let url = try makeURL(path: "api/auth/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decodingFailed
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            throw ClientError.httpError(statusCode: http.statusCode, body: bodyString)
        }

        if let wrapped = try? JSONDecoder().decode(GLKVMResponse<GLKVMAuthLoginResult>.self, from: data) {
            if let token = wrapped.result.token, !token.isEmpty {
                return token
            }
            if wrapped.ok == false {
                let bodyString = String(data: data, encoding: .utf8)
                throw ClientError.httpError(statusCode: http.statusCode, body: bodyString)
            }
        }

        if let token = authTokenFromSetCookieHeaders(in: http, for: url) {
            return token
        }

        let preview = String(data: data.prefix(512), encoding: .utf8) ?? "<binary \(data.count)B>"
        NSLog("[Overlook glkvm] login succeeded but no auth token was found. body: %@", preview)
        throw ClientError.decodingFailed
    }

    func getSystemConfig() async throws -> GLKVMSystemConfig {
        let response = try await request(
            method: "GET",
            path: "api/system/get_config",
            responseType: GLKVMResponse<GLKVMSystemGetConfigResult>.self
        )

        return response.result.config
    }

    func setSystemConfig(_ config: GLKVMSystemConfig) async throws -> GLKVMSystemConfig {
        let encoder = JSONEncoder()
        let body = try encoder.encode(config)

        let response = try await request(
            method: "POST",
            path: "api/system/set_config",
            body: body,
            contentType: "application/json",
            responseType: GLKVMResponse<GLKVMSystemGetConfigResult>.self
        )

        return response.result.config
    }

    func getStreamerState() async throws -> GLKVMStreamerState {
        let response = try await request(
            method: "GET",
            path: "api/streamer",
            responseType: GLKVMResponse<GLKVMStreamerState>.self
        )
        return response.result
    }

    func setStreamerParams(_ params: [String: String]) async throws {
        let queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        _ = try await request(
            method: "POST",
            path: "api/streamer/set_params",
            query: queryItems,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func setHIDParams(_ params: [String: String]) async throws {
        let queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        _ = try await request(
            method: "POST",
            path: "api/hid/set_params",
            query: queryItems,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func getTurnCredentials() async throws -> GLKVMTurnCredentials {
        let response = try await request(
            method: "GET",
            path: "api/turn/get_turn",
            responseType: GLKVMResponse<GLKVMTurnCredentials>.self
        )

        return response.result
    }

    func websocketURL() throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidURL
        }
        components.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components.path = "/api/ws"
        guard let url = components.url else {
            throw ClientError.invalidURL
        }
        return url
    }

    func mediaWebsocketURL() throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidURL
        }
        components.scheme = baseURL.scheme == "http" ? "ws" : "wss"
        components.path = "/api/media/ws"
        guard let url = components.url else {
            throw ClientError.invalidURL
        }
        return url
    }
}

private func authTokenFromSetCookieHeaders(in response: HTTPURLResponse, for url: URL) -> String? {
    var headerFields: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
        headerFields[String(describing: key)] = String(describing: value)
    }

    return HTTPCookie
        .cookies(withResponseHeaderFields: headerFields, for: url)
        .first(where: { $0.name == "auth_token" })?
        .value
}

extension GLKVMClient.ClientError: CustomStringConvertible {
    var description: String {
        switch self {
        case .invalidBaseURL:
            return "invalidBaseURL"
        case .invalidURL:
            return "invalidURL"
        case .decodingFailed:
            return "decodingFailed"
        case .httpError(let statusCode, let body):
            if let body, !body.isEmpty {
                return "httpError(\(statusCode)): \(body)"
            }
            return "httpError(\(statusCode))"
        }
    }
}

extension GLKVMClient {
    private func requestData(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Data {
        let url = try makeURL(path: path, queryItems: query)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        if let authToken, !authToken.isEmpty {
            request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.decodingFailed
        }

        guard (200...299).contains(http.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8)
            var errorMessage: String? = nil
            if let wrapped = try? JSONDecoder().decode(GLKVMResponse<GLKVMJSONObject>.self, from: data) {
                if case .string(let s) = wrapped.result["error_msg"] {
                    errorMessage = s
                } else if case .string(let s) = wrapped.result["message"] {
                    errorMessage = s
                }
            }
            throw ClientError.httpError(statusCode: http.statusCode, body: errorMessage ?? bodyString)
        }

        return data
    }
}

extension GLKVMClient {
    func getEDID() async throws -> String {
        let data = try await requestData(
            method: "GET",
            path: "api/upgrade/get_edid"
        )

        let decoder = JSONDecoder()

        if let wrapped = try? decoder.decode(GLKVMResponse<String>.self, from: data) {
            return wrapped.result
        }

        if let wrapped = try? decoder.decode(GLKVMResponse<GLKVMJSONObject>.self, from: data) {
            if case .string(let s) = wrapped.result["edid"] {
                return s
            }
            if case .string(let s) = wrapped.result["EDID"] {
                return s
            }
        }

        if let s = String(data: data, encoding: .utf8) {
            return s
        }

        throw ClientError.decodingFailed
    }

    func setEDID(_ edid: String) async throws {
        let boundary = "----geckoformboundary\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
        body.append("Content-Disposition: form-data; name=\"edid\"\r\n\r\n".data(using: .utf8) ?? Data())
        body.append("\(edid)\r\n".data(using: .utf8) ?? Data())
        body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())

        _ = try await requestData(
            method: "POST",
            path: "api/upgrade/edid",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
    }
}

extension GLKVMClient {
    func getHidState() async throws -> GLKVMJSONObject {
        let response = try await request(
            method: "GET",
            path: "api/hid",
            responseType: GLKVMResponse<GLKVMJSONObject>.self
        )
        return response.result
    }

    func setHidConnected(_ connected: Bool) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/set_connected",
            query: [URLQueryItem(name: "connected", value: connected ? "true" : "false")],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func resetHid() async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/reset",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func getHidKeymaps() async throws -> GLKVMHidKeymapsState {
        let response = try await request(
            method: "GET",
            path: "api/hid/keymaps",
            responseType: GLKVMResponse<GLKVMHidKeymapsState>.self
        )
        return response.result
    }

    func hidPrint(text: String, keymap: String? = nil, limit: Int? = nil, slow: Bool? = nil) async throws {
        var query: [URLQueryItem] = []
        if let keymap {
            query.append(URLQueryItem(name: "keymap", value: keymap))
        }
        if let limit {
            query.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if let slow {
            query.append(URLQueryItem(name: "slow", value: slow ? "true" : "false"))
        }
        let body = text.data(using: .utf8) ?? Data()
        _ = try await request(
            method: "POST",
            path: "api/hid/print",
            query: query,
            body: body,
            contentType: "text/plain; charset=utf-8",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidShortcut(keys: [String]) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_shortcut",
            query: [URLQueryItem(name: "keys", value: keys.joined(separator: ","))],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidKey(key: String, state: Bool? = nil, finish: Bool? = nil) async throws {
        var query: [URLQueryItem] = [URLQueryItem(name: "key", value: key)]
        if let state {
            query.append(URLQueryItem(name: "state", value: state ? "true" : "false"))
        }
        if let finish {
            query.append(URLQueryItem(name: "finish", value: finish ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_key",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidMouseButton(button: String, state: Bool? = nil) async throws {
        var query: [URLQueryItem] = [URLQueryItem(name: "button", value: button)]
        if let state {
            query.append(URLQueryItem(name: "state", value: state ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_mouse_button",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidMouseMove(toX: Int, toY: Int) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_mouse_move",
            query: [
                URLQueryItem(name: "to_x", value: String(toX)),
                URLQueryItem(name: "to_y", value: String(toY)),
            ],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidMouseRelative(deltaX: Int, deltaY: Int) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_mouse_relative",
            query: [
                URLQueryItem(name: "delta_x", value: String(deltaX)),
                URLQueryItem(name: "delta_y", value: String(deltaY)),
            ],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func sendHidMouseWheel(deltaX: Int, deltaY: Int) async throws {
        _ = try await request(
            method: "POST",
            path: "api/hid/events/send_mouse_wheel",
            query: [
                URLQueryItem(name: "delta_x", value: String(deltaX)),
                URLQueryItem(name: "delta_y", value: String(deltaY)),
            ],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

extension GLKVMClient {
    func getMsdState() async throws -> GLKVMJSONObject {
        let response = try await request(
            method: "GET",
            path: "api/msd",
            responseType: GLKVMResponse<GLKVMJSONObject>.self
        )
        return response.result
    }

    func setMsdParams(image: String? = nil, cdrom: Bool? = nil, rw: Bool? = nil) async throws {
        var query: [URLQueryItem] = []
        if let image {
            query.append(URLQueryItem(name: "image", value: image))
        }
        if let cdrom {
            query.append(URLQueryItem(name: "cdrom", value: cdrom ? "true" : "false"))
        }
        if let rw {
            query.append(URLQueryItem(name: "rw", value: rw ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/msd/set_params",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func setMsdConnected(_ connected: Bool) async throws {
        _ = try await request(
            method: "POST",
            path: "api/msd/set_connected",
            query: [URLQueryItem(name: "connected", value: connected ? "true" : "false")],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdPartitionShow() async throws -> GLKVMMSDPartitionShowResult {
        let response = try await request(
            method: "GET",
            path: "api/msd/partition_show",
            responseType: GLKVMResponse<GLKVMMSDPartitionShowResult>.self
        )
        return response.result
    }

    func msdPartitionConnect() async throws {
        _ = try await request(
            method: "GET",
            path: "api/msd/partition_connect",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdPartitionDisconnect() async throws {
        _ = try await request(
            method: "GET",
            path: "api/msd/partition_disconnect",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdPartitionFormat(path: String) async throws {
        _ = try await request(
            method: "GET",
            path: "api/msd/partition_format",
            query: [URLQueryItem(name: "path", value: path)],
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdRead(image: String, compress: String? = nil) async throws -> Data {
        var query: [URLQueryItem] = [URLQueryItem(name: "image", value: image)]
        if let compress {
            query.append(URLQueryItem(name: "compress", value: compress))
        }
        return try await requestData(
            method: "GET",
            path: "api/msd/read",
            query: query
        )
    }

    func msdWrite(image: String, data: Data, prefix: String? = nil, removeIncomplete: Bool? = nil) async throws -> GLKVMMSDWriteResult {
        var query: [URLQueryItem] = [URLQueryItem(name: "image", value: image)]
        if let prefix {
            query.append(URLQueryItem(name: "prefix", value: prefix))
        }
        if let removeIncomplete {
            query.append(URLQueryItem(name: "remove_incomplete", value: removeIncomplete ? "true" : "false"))
        }
        let response = try await request(
            method: "POST",
            path: "api/msd/write",
            query: query,
            body: data,
            contentType: "application/octet-stream",
            responseType: GLKVMResponse<GLKVMMSDWriteResult>.self
        )
        return response.result
    }

    func msdWriteRemote(url: URL, image: String? = nil, prefix: String? = nil, insecure: Bool? = nil, timeout: Double? = nil, removeIncomplete: Bool? = nil) async throws -> [GLKVMMSDWriteResult] {
        var query: [URLQueryItem] = [URLQueryItem(name: "url", value: url.absoluteString)]
        if let image {
            query.append(URLQueryItem(name: "image", value: image))
        }
        if let prefix {
            query.append(URLQueryItem(name: "prefix", value: prefix))
        }
        if let insecure {
            query.append(URLQueryItem(name: "insecure", value: insecure ? "true" : "false"))
        }
        if let timeout {
            query.append(URLQueryItem(name: "timeout", value: String(timeout)))
        }
        if let removeIncomplete {
            query.append(URLQueryItem(name: "remove_incomplete", value: removeIncomplete ? "true" : "false"))
        }

        let data = try await requestData(
            method: "POST",
            path: "api/msd/write_remote",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded"
        )

        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(whereSeparator: \.isNewline)
        let decoder = JSONDecoder()

        var results: [GLKVMMSDWriteResult] = []
        results.reserveCapacity(lines.count)

        for line in lines {
            let lineData = Data(line.utf8)
            if let wrapped = try? decoder.decode(GLKVMResponse<GLKVMMSDWriteResult>.self, from: lineData) {
                results.append(wrapped.result)
                continue
            }
            if let unwrapped = try? decoder.decode(GLKVMMSDWriteResult.self, from: lineData) {
                results.append(unwrapped)
                continue
            }
        }

        return results
    }

    func msdRemove(image: String) async throws {
        _ = try await request(
            method: "POST",
            path: "api/msd/remove",
            query: [URLQueryItem(name: "image", value: image)],
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func msdReset() async throws {
        _ = try await request(
            method: "POST",
            path: "api/msd/reset",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

extension GLKVMClient {
    enum AtxPowerAction: String {
        case on
        case off
        case offHard = "off_hard"
        case resetHard = "reset_hard"
    }

    enum AtxButton: String {
        case power
        case powerLong = "power_long"
        case reset
    }

    func getAtxState() async throws -> GLKVMJSONObject {
        let response = try await request(
            method: "GET",
            path: "api/atx",
            responseType: GLKVMResponse<GLKVMJSONObject>.self
        )
        return response.result
    }

    func atxPower(_ action: AtxPowerAction, wait: Bool? = nil) async throws {
        var query: [URLQueryItem] = [URLQueryItem(name: "action", value: action.rawValue)]
        if let wait {
            query.append(URLQueryItem(name: "wait", value: wait ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/atx/power",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }

    func atxClick(_ button: AtxButton, wait: Bool? = nil) async throws {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "button", value: button.rawValue),
        ]
        if let wait {
            query.append(URLQueryItem(name: "wait", value: wait ? "true" : "false"))
        }
        _ = try await request(
            method: "POST",
            path: "api/atx/click",
            query: query,
            body: Data(),
            contentType: "application/x-www-form-urlencoded",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

extension GLKVMClient {
    func resetStreamer() async throws {
        _ = try await request(
            method: "POST",
            path: "api/streamer/reset",
            responseType: GLKVMResponse<GLKVMEmptyResult>.self
        )
    }
}

extension GLKVMClient {
    func makeWebSocketClient(stream: Bool = true) throws -> WebSocketClient {
        let url = try websocketURL()

        var request = URLRequest(url: url)
        if let authToken, !authToken.isEmpty {
            request.setValue("auth_token=\(authToken)", forHTTPHeaderField: "Cookie")
        }

        return WebSocketClient(session: session, request: request)
    }

    actor WebSocketClient {
        enum WebSocketError: Error {
            case notConnected
            case encodingFailed
            case decodingFailed
        }

        nonisolated let events: AsyncStream<GLKVMWebSocketEvent>
        private let continuation: AsyncStream<GLKVMWebSocketEvent>.Continuation

        private let session: URLSession
        private let request: URLRequest

        private var task: URLSessionWebSocketTask?
        private var receiveTask: Task<Void, Never>?
        private var pingTask: Task<Void, Never>?

        init(session: URLSession, request: URLRequest) {
            self.session = session
            self.request = request

            var c: AsyncStream<GLKVMWebSocketEvent>.Continuation!
            self.events = AsyncStream { continuation in
                c = continuation
            }
            self.continuation = c
        }

        func connect() {
            guard task == nil else { return }
            let ws = session.webSocketTask(with: request)
            task = ws
            ws.resume()

            receiveTask = Task { [weak self] in
                guard let self else { return }
                await self.receiveLoop()
            }

            pingTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { break }
                    try? await self.send(eventType: "ping")
                }
            }
        }

        func disconnect() {
            receiveTask?.cancel()
            receiveTask = nil

            pingTask?.cancel()
            pingTask = nil

            task?.cancel(with: .goingAway, reason: nil)
            task = nil

            continuation.finish()
        }

        func send(eventType: String, event: JSONValue = .object([:])) async throws {
            guard let task else {
                throw WebSocketError.notConnected
            }

            let payload = GLKVMWebSocketSend(eventType: eventType, event: event)
            let encoder = JSONEncoder()
            let data: Data
            do {
                data = try encoder.encode(payload)
            } catch {
                throw WebSocketError.encodingFailed
            }

            let text = String(decoding: data, as: UTF8.self)
            try await task.send(.string(text))
        }

        private func sendBinary(_ data: Data) async throws {
            guard let task else {
                throw WebSocketError.notConnected
            }
            try await task.send(.data(data))
        }

        func sendHidKey(key: String, state: Bool, finish: Bool = false) async throws {
            var payload = Data()
            payload.reserveCapacity(2 + key.utf8.count)
            payload.append(0x01)
            payload.append(state ? 0x01 : 0x00)
            payload.append(contentsOf: key.utf8)
            try await sendBinary(payload)

            if finish {
                let finishPayload = Data([0x01, 0x00])
                try await sendBinary(finishPayload)
            }
        }

        func sendHidMouseButton(button: String, state: Bool) async throws {
            var payload = Data()
            payload.reserveCapacity(2 + button.utf8.count)
            payload.append(0x02)
            payload.append(state ? 0x01 : 0x00)
            payload.append(contentsOf: button.utf8)
            try await sendBinary(payload)
        }

        func sendHidMouseMove(toX: Int, toY: Int) async throws {
            let sx = Int16(clamping: toX)
            let sy = Int16(clamping: toY)
            let ux = UInt16(bitPattern: sx)
            let uy = UInt16(bitPattern: sy)
            let payload = Data([
                0x03,
                UInt8((ux >> 8) & 0xFF),
                UInt8(ux & 0xFF),
                UInt8((uy >> 8) & 0xFF),
                UInt8(uy & 0xFF),
            ])
            try await sendBinary(payload)
        }

        func sendHidMouseRelative(deltaX: Int, deltaY: Int, squash: Bool = false) async throws {
            let dx = UInt8(bitPattern: Int8(clamping: deltaX))
            let dy = UInt8(bitPattern: Int8(clamping: deltaY))
            let payload = Data([
                0x04,
                squash ? 0x01 : 0x00,
                dx,
                dy,
            ])
            try await sendBinary(payload)
        }

        func sendHidMouseWheel(deltaX: Int, deltaY: Int, squash: Bool = false) async throws {
            let dx = UInt8(bitPattern: Int8(clamping: deltaX))
            let dy = UInt8(bitPattern: Int8(clamping: deltaY))
            let payload = Data([
                0x05,
                squash ? 0x01 : 0x00,
                dx,
                dy,
            ])
            try await sendBinary(payload)
        }

        private func receiveLoop() async {
            let decoder = JSONDecoder()
            while !Task.isCancelled {
                guard let task else { break }
                do {
                    let msg = try await task.receive()
                    switch msg {
                    case .string(let text):
                        guard let data = text.data(using: .utf8) else { continue }
                        if let event = try? decoder.decode(GLKVMWebSocketEvent.self, from: data) {
                            continuation.yield(event)
                        }
                    case .data(let data):
                        if let event = try? decoder.decode(GLKVMWebSocketEvent.self, from: data) {
                            continuation.yield(event)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    break
                }
            }
        }
    }
}
