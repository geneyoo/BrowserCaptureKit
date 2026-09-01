import Foundation

public enum BrowserCaptureEvent: Codable, Identifiable, Equatable, Sendable {
    case page(BrowserPageEvent)
    case response(CapturedResponse)
    case nativeNetwork(BrowserNativeNetworkEvent)
    case browserState(BrowserStateSnapshot)
    case accessibility(BrowserAccessibilitySnapshot)
    case action(BrowserActionResult)
    case console(BrowserConsoleEvent)
    case scriptError(BrowserScriptError)

    public var id: UUID {
        switch self {
        case .page(let event):
            event.id
        case .response(let response):
            response.id
        case .nativeNetwork(let event):
            event.id
        case .browserState(let snapshot):
            snapshot.id
        case .accessibility(let snapshot):
            snapshot.id
        case .action(let result):
            result.id
        case .console(let event):
            event.id
        case .scriptError(let error):
            error.id
        }
    }

    public var capturedAt: Date {
        switch self {
        case .page(let event):
            event.capturedAt
        case .response(let response):
            response.capturedAt
        case .nativeNetwork(let event):
            event.capturedAt
        case .browserState(let snapshot):
            snapshot.capturedAt
        case .accessibility(let snapshot):
            snapshot.capturedAt
        case .action(let result):
            result.capturedAt
        case .console(let event):
            event.capturedAt
        case .scriptError(let error):
            error.capturedAt
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case payload
    }

    private enum Kind: String, Codable {
        case page
        case response
        case nativeNetwork
        case browserState
        case accessibility
        case action
        case console
        case scriptError
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .page:
            self = .page(try container.decode(BrowserPageEvent.self, forKey: .payload))
        case .response:
            self = .response(try container.decode(CapturedResponse.self, forKey: .payload))
        case .nativeNetwork:
            self = .nativeNetwork(
                try container.decode(BrowserNativeNetworkEvent.self, forKey: .payload)
            )
        case .browserState:
            self = .browserState(
                try container.decode(BrowserStateSnapshot.self, forKey: .payload)
            )
        case .accessibility:
            self = .accessibility(
                try container.decode(BrowserAccessibilitySnapshot.self, forKey: .payload)
            )
        case .action:
            self = .action(try container.decode(BrowserActionResult.self, forKey: .payload))
        case .console:
            self = .console(try container.decode(BrowserConsoleEvent.self, forKey: .payload))
        case .scriptError:
            self = .scriptError(try container.decode(BrowserScriptError.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .page(let value):
            try container.encode(Kind.page, forKey: .kind)
            try container.encode(value, forKey: .payload)
        case .response(let value):
            try container.encode(Kind.response, forKey: .kind)
            try container.encode(value, forKey: .payload)
        case .nativeNetwork(let value):
            try container.encode(Kind.nativeNetwork, forKey: .kind)
            try container.encode(value, forKey: .payload)
        case .browserState(let value):
            try container.encode(Kind.browserState, forKey: .kind)
            try container.encode(value, forKey: .payload)
        case .accessibility(let value):
            try container.encode(Kind.accessibility, forKey: .kind)
            try container.encode(value, forKey: .payload)
        case .action(let value):
            try container.encode(Kind.action, forKey: .kind)
            try container.encode(value, forKey: .payload)
        case .console(let value):
            try container.encode(Kind.console, forKey: .kind)
            try container.encode(value, forKey: .payload)
        case .scriptError(let value):
            try container.encode(Kind.scriptError, forKey: .kind)
            try container.encode(value, forKey: .payload)
        }
    }
}

public struct BrowserStateSnapshot: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let reason: String
    public let url: URL?
    public let title: String?
    public let userAgent: String?
    public let documentCookie: String?
    public let localStorage: [String: String]
    public let sessionStorage: [String: String]
    public let cookies: [BrowserCookieSnapshot]
    public let websiteDataRecords: [BrowserWebsiteDataRecordSnapshot]
    public let javaScriptError: String?

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        reason: String,
        url: URL?,
        title: String?,
        userAgent: String?,
        documentCookie: String?,
        localStorage: [String: String],
        sessionStorage: [String: String],
        cookies: [BrowserCookieSnapshot],
        websiteDataRecords: [BrowserWebsiteDataRecordSnapshot] = [],
        javaScriptError: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.reason = reason
        self.url = url
        self.title = title
        self.userAgent = userAgent
        self.documentCookie = documentCookie
        self.localStorage = localStorage
        self.sessionStorage = sessionStorage
        self.cookies = cookies
        self.websiteDataRecords = websiteDataRecords
        self.javaScriptError = javaScriptError
    }
}

public struct BrowserCookieSnapshot: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expiresDate: Date?
    public let isSessionOnly: Bool
    public let isSecure: Bool
    public let isHTTPOnly: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        value: String,
        domain: String,
        path: String,
        expiresDate: Date?,
        isSessionOnly: Bool,
        isSecure: Bool,
        isHTTPOnly: Bool
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresDate = expiresDate
        self.isSessionOnly = isSessionOnly
        self.isSecure = isSecure
        self.isHTTPOnly = isHTTPOnly
    }
}

public struct BrowserWebsiteDataRecordSnapshot: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let displayName: String
    public let dataTypes: [String]

    public init(
        id: UUID = UUID(),
        displayName: String,
        dataTypes: [String]
    ) {
        self.id = id
        self.displayName = displayName
        self.dataTypes = dataTypes
    }
}

public struct BrowserNativeNetworkEvent: Codable, Identifiable, Equatable, Sendable {
    public enum Phase: String, Codable, Equatable, Sendable {
        case navigationAction
        case navigationResponse
    }

    public let id: UUID
    public let capturedAt: Date
    public let phase: Phase
    public let url: URL?
    public let mainDocumentURL: URL?
    public let method: String?
    public let status: Int?
    public let mimeType: String?
    public let expectedContentLength: Int64?
    public let headers: [String: String]
    public let isForMainFrame: Bool?
    public let navigationType: String?
    public let canShowMIMEType: Bool?

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        phase: Phase,
        url: URL?,
        mainDocumentURL: URL? = nil,
        method: String? = nil,
        status: Int? = nil,
        mimeType: String? = nil,
        expectedContentLength: Int64? = nil,
        headers: [String: String] = [:],
        isForMainFrame: Bool? = nil,
        navigationType: String? = nil,
        canShowMIMEType: Bool? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.phase = phase
        self.url = url
        self.mainDocumentURL = mainDocumentURL
        self.method = method
        self.status = status
        self.mimeType = mimeType
        self.expectedContentLength = expectedContentLength
        self.headers = headers
        self.isForMainFrame = isForMainFrame
        self.navigationType = navigationType
        self.canShowMIMEType = canShowMIMEType
    }
}

public struct BrowserPageEvent: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case navigationStarted
        case navigationFinished
        case navigationFailed
        case titleChanged
    }

    public let id: UUID
    public let capturedAt: Date
    public let kind: Kind
    public let url: URL?
    public let title: String?
    public let message: String?

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        kind: Kind,
        url: URL?,
        title: String? = nil,
        message: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.kind = kind
        self.url = url
        self.title = title
        self.message = message
    }
}

public struct BrowserConsoleEvent: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let level: String
    public let message: String

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        level: String,
        message: String
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.level = level
        self.message = message
    }
}

public struct BrowserScriptError: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let message: String
    public let url: URL?

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        message: String,
        url: URL? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.message = message
        self.url = url
    }
}
