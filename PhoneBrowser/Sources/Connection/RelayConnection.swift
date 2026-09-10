import Foundation
import OSLog

/// Outbound WebSocket the phone opens to the relay. Reconnects with bounded,
/// cancellable backoff and enforces an explicit heartbeat deadline. It never
/// evaluates commands itself; every inbound message is handed to the
/// coordinator on the main actor.
@MainActor
final class RelayConnection {
    enum State: Equatable {
        case disconnected(reason: String?)
        case connecting
        case connected
    }

    private(set) var state: State = .disconnected(reason: nil) {
        didSet {
            if state != oldValue {
                onStateChanged?(state)
            }
        }
    }

    var onStateChanged: ((State) -> Void)?
    var onInbound: ((RelayInboundMessage) -> Void)?
    var makeHello: (() -> DeviceHello)?

    static let heartbeatInterval: Duration = .seconds(15)
    static let heartbeatDeadline: Duration = .seconds(10)
    static let maximumBackoff: Double = 30

    private let url: URL
    private let token: String
    private let urlSession: URLSession
    private let log = Logger(subsystem: "com.geneyoo.phonebrowser", category: "relay")
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private var outbound: [String] = []
    private var sendTask: Task<Void, Never>?
    private var attempt = 0

    init(url: URL, token: String, urlSession: URLSession = .shared) {
        self.url = url
        self.token = token
        self.urlSession = urlSession
    }

    func start() {
        guard runTask == nil else { return }
        runTask = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        tearDownSocket(reason: "stopped")
    }

    /// Best effort and ordered. Results survive a disconnect in the journal
    /// and are re-sent during reconciliation, so a lost send is not fatal.
    func send(_ message: RelayOutboundMessage) {
        guard let data = try? encoder.encode(message), let text = String(data: data, encoding: .utf8) else {
            log.error("Could not encode an outbound message.")
            return
        }
        guard socket != nil else { return }
        outbound.append(text)
        drainOutbound()
    }

    // MARK: - Loop

    private func run() async {
        while !Task.isCancelled {
            state = .connecting
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("\(PhoneBrowserProtocol.version)", forHTTPHeaderField: "X-Phone-Browser-Protocol")
            let socket = urlSession.webSocketTask(with: request)
            self.socket = socket
            socket.resume()
            if let hello = makeHello?() {
                send(.hello(hello))
            }
            startHeartbeat(socket)

            let failure = await receiveLoop(socket)
            tearDownSocket(reason: failure)
            guard !Task.isCancelled else { return }

            attempt += 1
            let delay = min(Self.maximumBackoff, pow(2, Double(attempt - 1))) + Double.random(in: 0..<1)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async -> String {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                if state != .connected {
                    state = .connected
                }
                switch message {
                case .string(let text):
                    dispatch(text)
                case .data(let data):
                    dispatch(String(decoding: data, as: UTF8.self))
                @unknown default:
                    break
                }
            } catch {
                return error.localizedDescription
            }
        }
        return "cancelled"
    }

    private func dispatch(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        do {
            let message = try decoder.decode(RelayInboundMessage.self, from: data)
            if case .helloAck = message {
                attempt = 0
            }
            if case .unknown(let type) = message {
                log.warning("Ignoring unknown relay message type \(type, privacy: .public).")
                return
            }
            onInbound?(message)
        } catch {
            log.error("Dropping undecodable relay message: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startHeartbeat(_ socket: URLSessionWebSocketTask) {
        heartbeatTask?.cancel()
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.heartbeatInterval)
                } catch {
                    return
                }
                guard let self, self.socket === socket else { return }
                let alive = await Self.ping(socket, deadline: Self.heartbeatDeadline)
                if !alive {
                    self.log.warning("Heartbeat deadline missed; reconnecting.")
                    socket.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
    }

    private static func ping(_ socket: URLSessionWebSocketTask, deadline: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    socket.sendPing { error in
                        continuation.resume(returning: error == nil)
                    }
                }
            }
            group.addTask {
                (try? await Task.sleep(for: deadline)) == nil ? true : false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func drainOutbound() {
        guard sendTask == nil else { return }
        sendTask = Task { @MainActor [weak self] in
            while let self, let socket = self.socket, !self.outbound.isEmpty {
                let text = self.outbound.removeFirst()
                do {
                    try await socket.send(.string(text))
                } catch {
                    self.log.error("Send failed: \(error.localizedDescription, privacy: .public)")
                    break
                }
            }
            self?.sendTask = nil
        }
    }

    private func tearDownSocket(reason: String) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        outbound = []
        state = .disconnected(reason: reason)
    }
}
