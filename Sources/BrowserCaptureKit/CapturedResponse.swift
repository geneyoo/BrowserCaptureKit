import Foundation

/// Frame attribution for a captured event, derived from `WKScriptMessage.frameInfo`.
///
/// This lets a consumer tell traffic that originated in a cross-origin child
/// iframe (e.g. an embedded customer-service chat widget) apart from
/// main-page/analytics traffic.
public struct CapturedFrameInfo: Codable, Equatable, Sendable {
    public let isMainFrame: Bool
    /// `WKSecurityOrigin` rendered as `scheme://host[:port]`.
    public let securityOrigin: String?
    /// `WKFrameInfo.request.url` when available.
    public let requestURL: String?
    /// Deterministic CS-widget vendor for this frame, inferred from
    /// `securityOrigin` (falling back to the request URL host). `nil` = unknown
    /// origin — the frozen envelope's `vendorHint`.
    public let vendorHint: BrowserVendor?

    public init(
        isMainFrame: Bool,
        securityOrigin: String? = nil,
        requestURL: String? = nil,
        vendorHint: BrowserVendor? = nil
    ) {
        self.isMainFrame = isMainFrame
        self.securityOrigin = securityOrigin
        self.requestURL = requestURL
        self.vendorHint =
            vendorHint ?? BrowserVendor(origin: securityOrigin) ?? BrowserVendor(origin: requestURL)
    }
}

public struct CapturedResponse: Codable, Identifiable, Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        case fetch
        case xhr
        case websocket
        case eventsource
        case beacon
    }

    /// Direction of a streamed frame for socket-style sources. `nil` for
    /// request/response sources (fetch/xhr/beacon).
    public enum Direction: String, Codable, Equatable, Sendable {
        case outbound
        case inbound
        case open
        case close
        case error
    }

    public let id: UUID
    public let capturedAt: Date
    public let source: Source
    public let direction: Direction?
    public let frame: CapturedFrameInfo?
    public let method: String
    public let url: URL
    public let status: Int?
    public let statusText: String?
    public let contentType: String?
    public let requestHeaders: [String: String]
    public let requestMetadata: [String: String]
    public let requestBodyPreview: String?
    public let responseHeaders: [String: String]
    public let responseBodyPreview: String?
    public let responseBodyTruncated: Bool
    public let durationMilliseconds: Double?
    public let errorDescription: String?

    /// Resolved vendor for THIS event — the frozen envelope's `vendorHint`.
    /// Keys off the traffic **destination host first**: a widget socket is often
    /// opened from the brand's own main frame (real Delta opens the LivePerson
    /// socket from `delta.com`, not a `liveperson.net` iframe), so the frame
    /// origin alone misses it. Falls back to the frame origin's vendor.
    public var vendorHint: BrowserVendor? {
        BrowserVendor(origin: url.absoluteString) ?? frame?.vendorHint
    }

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        source: Source,
        direction: Direction? = nil,
        frame: CapturedFrameInfo? = nil,
        method: String,
        url: URL,
        status: Int? = nil,
        statusText: String? = nil,
        contentType: String? = nil,
        requestHeaders: [String: String] = [:],
        requestMetadata: [String: String] = [:],
        requestBodyPreview: String? = nil,
        responseHeaders: [String: String] = [:],
        responseBodyPreview: String? = nil,
        responseBodyTruncated: Bool = false,
        durationMilliseconds: Double? = nil,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.source = source
        self.direction = direction
        self.frame = frame
        self.method = method
        self.url = url
        self.status = status
        self.statusText = statusText
        self.contentType = contentType
        self.requestHeaders = requestHeaders
        self.requestMetadata = requestMetadata
        self.requestBodyPreview = requestBodyPreview
        self.responseHeaders = responseHeaders
        self.responseBodyPreview = responseBodyPreview
        self.responseBodyTruncated = responseBodyTruncated
        self.durationMilliseconds = durationMilliseconds
        self.errorDescription = errorDescription
    }
}
