import Foundation

public struct BrowserCaptureConfiguration: Equatable, Sendable {
    public static let defaultInitialURL: URL = URL(string: "about:blank") ?? URL(fileURLWithPath: "/")

    public static let defaultPersistentStoreIdentifier = UUID(uuidString: "B2D41C04-19E7-4FA5-986A-F6D3B9115E5D") ?? UUID()

    public enum StorageMode: Equatable, Sendable {
        case nonPersistent
        case persistent(identifier: UUID)
    }

    public var initialURL: URL
    public var storageMode: StorageMode
    public var capturesFetch: Bool
    public var capturesXHR: Bool
    /// Hook `WebSocket`, `EventSource`, and `navigator.sendBeacon`. Streamed
    /// chat widgets (LivePerson/Zendesk/Amazon Connect) deliver the live
    /// conversation over a WebSocket, so this is required to read the transcript.
    public var capturesWebSocket: Bool
    public var capturesConsole: Bool
    public var maxBodyPreviewCharacters: Int
    /// Hard boundary for a transport replay to receive its vendor-correlated
    /// acknowledgement. Expiry is ambiguous and must enter recovery; it is
    /// never treated as proof that the merchant did not receive the send.
    public var webSocketAckTimeoutMilliseconds: Int
    /// Once the in-page POST begins, timeout/network loss cannot prove whether
    /// the merchant accepted it. Bound the wait, then report an uncertain
    /// outcome instead of treating the request as safely retryable.
    public var restReissueAckTimeoutMilliseconds: Int

    public init(
        initialURL: URL = BrowserCaptureConfiguration.defaultInitialURL,
        storageMode: StorageMode = .persistent(identifier: BrowserCaptureConfiguration.defaultPersistentStoreIdentifier),
        capturesFetch: Bool = true,
        capturesXHR: Bool = true,
        capturesWebSocket: Bool = true,
        capturesConsole: Bool = false,
        maxBodyPreviewCharacters: Int = 24_000,
        webSocketAckTimeoutMilliseconds: Int = 10_000,
        restReissueAckTimeoutMilliseconds: Int = 15_000
    ) {
        self.initialURL = initialURL
        self.storageMode = storageMode
        self.capturesFetch = capturesFetch
        self.capturesXHR = capturesXHR
        self.capturesWebSocket = capturesWebSocket
        self.capturesConsole = capturesConsole
        self.maxBodyPreviewCharacters = max(0, maxBodyPreviewCharacters)
        self.webSocketAckTimeoutMilliseconds = max(
            100,
            min(webSocketAckTimeoutMilliseconds, 30_000)
        )
        self.restReissueAckTimeoutMilliseconds = max(
            100,
            min(restReissueAckTimeoutMilliseconds, 30_000)
        )
    }
}
