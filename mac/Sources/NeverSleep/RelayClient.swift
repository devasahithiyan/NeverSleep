import Foundation
import CryptoKit
import NeverSleepCore

@MainActor
protocol RelayHandler: AnyObject {
    func relayStateSnapshot() -> [String: Any]
    func relayHandle(_ cmd: RemoteCommand) async throws -> [String: Any]?
}

struct RelayError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Keeps one outbound, authenticated WebSocket to the relay (the Mac sits behind NAT, so the
/// relay can never dial in). Reconnects with exponential backoff and jitter.
@MainActor
final class RelayClient: NSObject, ObservableObject {
    enum Status: Equatable {
        case notPaired, connecting, connected, disconnected(String)
        var text: String {
            switch self {
            case .notPaired: return "Not paired"
            case .connecting: return "Connecting…"
            case .connected: return "Connected"
            case .disconnected(let why): return "Offline (\(why))"
            }
        }
    }

    @Published private(set) var status: Status = .notPaired {
        didSet {
            guard oldValue != status else { return }
            switch status {
            case .connected: ActivityLog.shared.record("remote", "Connected to relay")
            case .disconnected(let why) where oldValue == .connected:
                ActivityLog.shared.record("remote", "Disconnected from relay: \(why)")
            default: break
            }
        }
    }
    @Published private(set) var pairingCode: String?
    @Published private(set) var pairingError: String?
    @Published private(set) var credentials: DeviceCredentials?
    /// One-time code to sign a browser in to this (already paired) Mac.
    @Published private(set) var browserCode: String?
    @Published private(set) var browserCodeExpires: Date?
    @Published var browserNotice: String?
    private var browserCodeTimer: Timer?

    weak var handler: RelayHandler?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var backoff: TimeInterval = 1
    private var reconnectWork: DispatchWorkItem?
    private var pingTimer: Timer?
    private var heartbeatTimer: Timer?
    private var pairingTask: Task<Void, Never>?
    private var generation = 0

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 30
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        credentials = Keychain.load()
        status = credentials == nil ? .notPaired : .disconnected("starting")
    }

    // MARK: URL rules

    /// HTTPS only. Plain http is allowed for localhost so `wrangler dev` can be tested.
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let host = url.host, url.user == nil, url.query == nil else { return nil }
        let local = host == "localhost" || host == "127.0.0.1"
        guard url.scheme == "https" || (url.scheme == "http" && local) else { return nil }
        return url
    }

    private static func endpoint(_ base: URL, _ path: String, websocket: Bool = false) -> URL {
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if websocket { c.scheme = (c.scheme == "https") ? "wss" : "ws" }
        return c.url!
    }

    // MARK: Pairing

    /// 1. Generate a random device token locally; send only its SHA-256 to the relay.
    /// 2. The relay answers with a one-time code, shown in the menu bar.
    /// 3. The user types the code into the logged-in dashboard.
    /// 4. We poll until the relay says the code was claimed, then keep the token in the Keychain.
    func startPairing(relayURL: String, deviceName: String) {
        cancelPairing()
        pairingError = nil
        guard let base = Self.normalizedBaseURL(relayURL) else {
            pairingError = "Relay URL must start with https://"
            return
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            pairingError = "Could not generate a token"
            return
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let tokenHash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()

        pairingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let start = try await self.postJSON(Self.endpoint(base, "api/pair/start"),
                                                    ["name": String(deviceName.prefix(64)), "tokenHash": tokenHash])
                guard let pairID = start["pairId"] as? String, let code = start["code"] as? String else {
                    throw RelayError(message: "Unexpected reply from relay")
                }
                self.pairingCode = code
                let deadline = Date().addingTimeInterval(10 * 60)
                while !Task.isCancelled && Date() < deadline {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    let poll = try await self.postJSON(Self.endpoint(base, "api/pair/poll"),
                                                       ["pairId": pairID, "token": token])
                    if poll["status"] as? String == "claimed", let deviceID = poll["deviceId"] as? String {
                        let creds = DeviceCredentials(relayURL: base.absoluteString, deviceID: deviceID, token: token)
                        guard Keychain.save(creds) else { throw RelayError(message: "Could not save to Keychain") }
                        self.credentials = creds
                        self.pairingCode = nil
                        ActivityLog.shared.record("remote", "Paired with relay \(base.host ?? "")")
                        self.connect()
                        return
                    }
                }
                if !Task.isCancelled { throw RelayError(message: "Pairing code expired. Try again.") }
            } catch is CancellationError {
            } catch {
                self.pairingCode = nil
                self.pairingError = error.localizedDescription
            }
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairingCode = nil
    }

    func unpair() {
        clearBrowserCode()
        disconnect()
        Keychain.delete()
        credentials = nil
        status = .notPaired
    }

    private func postJSON(_ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RelayError(message: (obj["error"] as? String) ?? "Relay returned an error")
        }
        return obj
    }

    // MARK: Connection

    func connect() {
        reconnectWork?.cancel()
        guard let creds = credentials, let base = Self.normalizedBaseURL(creds.relayURL) else {
            status = .notPaired
            return
        }
        teardownSocket()
        generation += 1
        var req = URLRequest(url: Self.endpoint(base, "api/device/connect", websocket: true))
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue(creds.deviceID, forHTTPHeaderField: "X-Device-Id")
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 1 << 20
        task = t
        status = .connecting
        t.resume()
        receive(on: t, generation: generation)
    }

    func disconnect() {
        reconnectWork?.cancel()
        teardownSocket()
        if credentials != nil { status = .disconnected("stopped") }
    }

    private func teardownSocket() {
        pingTimer?.invalidate(); pingTimer = nil
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func didOpen() {
        status = .connected
        backoff = 1
        sendState()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ping() }
        }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendState() }
        }
    }

    private func ping() {
        let gen = generation
        task?.sendPing { [weak self] err in
            guard let err else { return }
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                self.scheduleReconnect(err.localizedDescription)
            }
        }
    }

    private func scheduleReconnect(_ why: String) {
        teardownSocket()
        guard credentials != nil else { status = .notPaired; return }
        status = .disconnected(why)
        reconnectWork?.cancel()
        let delay = backoff + Double.random(in: 0...(backoff / 2))
        backoff = min(backoff * 2, 60)
        let work = DispatchWorkItem { [weak self] in Task { @MainActor in self?.connect() } }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func receive(on t: URLSessionWebSocketTask, generation gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .failure(let err):
                    self.scheduleReconnect(err.localizedDescription)
                case .success(let msg):
                    if case .connecting = self.status { self.didOpen() }
                    if case .string(let text) = msg { await self.handleMessage(text) }
                    self.receive(on: t, generation: gen)
                }
            }
        }
    }

    private func handleMessage(_ text: String) async {
        guard text.utf8.count <= 64 * 1024,
              let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "command":
            guard let id = obj["id"] as? String, id.count <= 64, let cmdName = obj["cmd"] as? String else { return }
            let args = obj["args"] as? [String: Any] ?? [:]
            do {
                let cmd = try RemoteCommand.parse(cmd: cmdName, args: args)
                guard let handler else { throw RelayError(message: "not ready") }
                let data = try await handler.relayHandle(cmd)
                send(["type": "result", "id": id, "ok": true, "data": data ?? [:]])
            } catch {
                if error is RemoteCommand.ParseError {
                    ActivityLog.shared.record("remote", "Rejected dashboard command '\(cmdName.prefix(40))': \(error)")
                }
                send(["type": "result", "id": id, "ok": false, "error": String(describing: error).prefix(300).description])
            }
            sendState()
        case "browserCode":
            if let code = obj["code"] as? String, code.count <= 16 {
                browserCode = code
                let exp = (obj["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                    ?? Date().addingTimeInterval(600)
                browserCodeExpires = exp
                browserNotice = nil
                browserCodeTimer?.invalidate()
                browserCodeTimer = Timer.scheduledTimer(withTimeInterval: max(1, exp.timeIntervalSinceNow), repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.clearBrowserCode() }
                }
            } else {
                browserNotice = (obj["error"] as? String).map { String($0.prefix(200)) } ?? "Could not get a code"
            }
        case "browsersRevoked":
            browserNotice = "All browsers were signed out."
            ActivityLog.shared.record("remote", "All browsers signed out")
        case "revoked":
            unpair()
        default:
            break
        }
    }

    /// Ask the relay for a one-time code that signs a browser in to this Mac.
    func requestBrowserCode() {
        guard status == .connected else {
            browserNotice = "Not connected to the relay"
            return
        }
        send(["type": "requestBrowserCode"])
    }

    func clearBrowserCode() {
        browserCodeTimer?.invalidate()
        browserCode = nil
        browserCodeExpires = nil
    }

    /// Invalidate every browser session for this Mac (e.g. a lost phone).
    func revokeBrowsers() {
        guard status == .connected else {
            browserNotice = "Not connected to the relay"
            return
        }
        clearBrowserCode()
        send(["type": "revokeBrowsers"])
    }

    func sendState() {
        guard status == .connected, let handler else { return }
        send(["type": "state", "state": handler.relayStateSnapshot()])
    }

    private func send(_ obj: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return }
        task.send(.string(s)) { _ in }
    }
}

extension RelayClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            guard webSocketTask === self.task else { return }
            if case .connecting = self.status { self.didOpen() }
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            guard webSocketTask === self.task else { return }
            if closeCode.rawValue == 4401 {
                // Relay rejected our token (device removed from the dashboard).
                self.unpair()
                self.pairingError = "This Mac was removed from the dashboard. Pair again."
                return
            }
            self.scheduleReconnect("closed \(closeCode.rawValue)")
        }
    }
}
