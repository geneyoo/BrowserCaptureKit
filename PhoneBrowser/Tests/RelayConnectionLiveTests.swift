import Foundation
import Network
import XCTest

@testable import PhoneBrowser

/// In-process WebSocket server (Network.framework) standing in for the relay,
/// so the connection's hello ordering, dispatch, outbound ordering, and
/// reconnect behavior are verified without a Node process.
@MainActor
private final class LoopbackRelayServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "loopback-relay")
    private(set) var connections: [NWConnection] = []
    private var messageWaiters: [(NWConnection, String) -> Bool] = []
    private var connectionWaiters: [(NWConnection) -> Bool] = []
    private var received: [(NWConnection, String)] = []
    private var handedOut = 0

    enum WaitError: Error {
        case timedOut(String)
    }

    /// Bounded wait so a missing frame fails the test instead of hanging it.
    private static func bounded<T>(_ what: String, seconds: Double = 15, _ operation: @escaping () async -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw WaitError.timedOut(what)
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    init() throws {
        let parameters = NWParameters.tcp
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.attach(connection)
            }
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [listener] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }

    /// Each accepted connection is handed out exactly once, in arrival order.
    func nextConnection() async throws -> NWConnection {
        try await Self.bounded("next connection") { [self] in
            if handedOut < connections.count {
                handedOut += 1
                return connections[handedOut - 1]
            }
            return await withCheckedContinuation { continuation in
                connectionWaiters.append { [self] connection in
                    handedOut += 1
                    continuation.resume(returning: connection)
                    return true
                }
            }
        }
    }

    /// Next text message on `connection` matching `predicate`, consumed once.
    func nextMessage(on connection: NWConnection, where predicate: @escaping (String) -> Bool = { _ in true }) async throws -> String {
        try await Self.bounded("next message") { [self] in
            if let index = received.firstIndex(where: { $0.0 === connection && predicate($0.1) }) {
                return received.remove(at: index).1
            }
            return await withCheckedContinuation { continuation in
                messageWaiters.append { candidate, text in
                    guard candidate === connection, predicate(text) else { return false }
                    continuation.resume(returning: text)
                    return true
                }
            }
        }
    }

    func send(_ text: String, on connection: NWConnection) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func attach(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { _ in }
        connection.start(queue: queue)
        receiveLoop(connection)
        if let index = connectionWaiters.firstIndex(where: { $0(connection) }) {
            connectionWaiters.remove(at: index)
        }
    }

    private func receiveLoop(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] content, _, _, error in
            guard error == nil, let content else { return }
            let text = String(decoding: content, as: UTF8.self)
            Task { @MainActor in
                guard let self else { return }
                if let index = self.messageWaiters.firstIndex(where: { $0(connection, text) }) {
                    self.messageWaiters.remove(at: index)
                } else {
                    self.received.append((connection, text))
                }
                self.receiveLoop(connection)
            }
        }
    }
}

@MainActor
final class RelayConnectionLiveTests: XCTestCase {
    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func makeHello(sessionID: String) -> DeviceHello {
        DeviceHello(
            protocolVersion: PhoneBrowserProtocol.version,
            deviceID: "dev_test",
            sessionID: sessionID,
            processInstanceID: "proc",
            appVersion: "0.1.0",
            osVersion: "17.0",
            libraryVersion: "0.1.4",
            controllerGeneration: 1,
            readiness: .ready,
            eventCursor: 0,
            capabilities: .current(configuration: .init())
        )
    }

    func testHandshakeOrderingDispatchAndReconnectAfterServerDrop() async throws {
        let server = try LoopbackRelayServer()
        let port = try await server.start()
        defer { server.stop() }

        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/v1/device"))
        let connection = RelayConnection(url: url, token: "device-token")
        defer { connection.stop() }
        var inbound: [RelayInboundMessage] = []
        var states: [RelayConnection.State] = []
        connection.onInbound = { inbound.append($0) }
        connection.onStateChanged = { states.append($0) }
        var helloSession = "session-A"
        connection.makeHello = { [self] in makeHello(sessionID: helloSession) }
        connection.start()

        // Hello is the first frame on the socket. (The bearer header itself is
        // verified by the Node relay's authenticated upgrade in the e2e gate.)
        let first = try await server.nextConnection()
        let hello = try json(try await server.nextMessage(on: first))
        XCTAssertEqual(hello["type"] as? String, "hello")
        XCTAssertEqual(hello["sessionId"] as? String, "session-A")

        // Inbound messages are decoded and handed over; unknown ones are dropped.
        server.send(#"{"type":"helloAck","unresolvedCommandIds":["c-old"]}"#, on: first)
        server.send(#"{"type":"reboot"}"#, on: first)
        server.send(
            #"{"type":"command","commandId":"c1","sessionId":"session-A","controllerGeneration":1,"issuedAt":"2026-09-10T00:00:00Z","deadline":"2099-01-01T00:00:00Z","operation":{"kind":"observe"}}"#,
            on: first
        )
        server.send(#"{"type":"cancel","commandId":"c1"}"#, on: first)
        let dispatched = expectation(description: "three inbound messages")
        dispatched.expectedFulfillmentCount = 3
        connection.onInbound = { message in
            inbound.append(message)
            dispatched.fulfill()
        }
        await fulfillment(of: [dispatched], timeout: 5)
        XCTAssertEqual(inbound[0], .helloAck(HelloAck(unresolvedCommandIDs: ["c-old"])))
        guard case .command(let command) = inbound[1] else {
            return XCTFail("Expected a command, got \(inbound[1])")
        }
        XCTAssertEqual(command.commandID, "c1")
        XCTAssertEqual(command.operation, .observe(includeImage: false, maxElements: RemoteOperation.defaultMaxElements))
        XCTAssertEqual(inbound[2], .cancel(commandID: "c1"))
        XCTAssertEqual(states.last, .connected)

        // Outbound frames keep their order.
        connection.send(.receipt(.accepted("c1")))
        connection.send(.status(DeviceStatus(
            readiness: .executing, sessionID: "session-A", controllerGeneration: 1, humanControl: false,
            foreground: true, activeCommandID: "c1", pageURL: nil, eventCursor: 0
        )))
        let receipt = try json(try await server.nextMessage(on: first))
        XCTAssertEqual(receipt["type"] as? String, "receipt")
        XCTAssertEqual(receipt["commandId"] as? String, "c1")
        let status = try json(try await server.nextMessage(on: first))
        XCTAssertEqual(status["type"] as? String, "status")
        XCTAssertEqual(status["readiness"] as? String, "executing")

        // The relay drops the socket: the phone reconnects on its own with a fresh hello.
        helloSession = "session-B"
        first.cancel()
        let second = try await server.nextConnection()
        XCTAssertFalse(second === first)
        let secondHello = try json(try await server.nextMessage(on: second))
        XCTAssertEqual(secondHello["type"] as? String, "hello")
        XCTAssertEqual(secondHello["sessionId"] as? String, "session-B")
        XCTAssertTrue(states.contains { if case .disconnected = $0 { return true } else { return false } })
    }

    func testStopEndsReconnection() async throws {
        let server = try LoopbackRelayServer()
        let port = try await server.start()
        defer { server.stop() }
        let connection = RelayConnection(url: try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/v1/device")), token: "t")
        connection.makeHello = { [self] in makeHello(sessionID: "s") }
        connection.start()
        let first = try await server.nextConnection()
        _ = try await server.nextMessage(on: first)
        connection.stop()
        XCTAssertEqual(connection.state, .disconnected(reason: "stopped"))
        // A stopped connection must not come back after the server-side close.
        let closed = expectation(description: "socket closed")
        first.stateUpdateHandler = { state in
            if case .cancelled = state { closed.fulfill() }
            if case .failed = state { closed.fulfill() }
        }
        first.cancel()
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertEqual(server.connections.count, 1)
    }
}
