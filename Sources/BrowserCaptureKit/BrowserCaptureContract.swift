import Foundation

/// Stable protocol metadata shared by snapshots, commands, events, and results.
public enum BrowserCaptureContract {
    public static let currentSchemaVersion = 1
    public static let libraryVersion = "0.1.1"
}

/// A transport-ready command envelope. The action remains browser-neutral while
/// the envelope binds it to one retained browser session.
public struct BrowserActionCommand: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let schemaVersion: Int
    public let browserSessionID: String
    public let issuedAt: Date
    public let action: BrowserActionRequest

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = BrowserCaptureContract.currentSchemaVersion,
        browserSessionID: String,
        issuedAt: Date = Date(),
        action: BrowserActionRequest
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.browserSessionID = browserSessionID
        self.issuedAt = issuedAt
        self.action = action
    }

    public func validate() throws {
        guard schemaVersion == BrowserCaptureContract.currentSchemaVersion else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard browserSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw ValidationError.emptyBrowserSessionID
        }
    }

    public enum ValidationError: Error, Equatable, LocalizedError, Sendable {
        case unsupportedSchemaVersion(Int)
        case emptyBrowserSessionID

        public var errorDescription: String? {
            switch self {
            case .unsupportedSchemaVersion(let version):
                "Unsupported browser command schema version: \(version)."
            case .emptyBrowserSessionID:
                "A browser command must identify its retained browser session."
            }
        }
    }
}

/// A compact declaration a host can give to a planner before it proposes work.
public struct BrowserCaptureCapabilities: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let libraryVersion: String
    public let supportedActions: [BrowserActionKind]
    public let captureSources: [CapturedResponse.Source]
    public let requiresVisibleBrowser: Bool
    public let controlsOtherApps: Bool

    public init(configuration: BrowserCaptureConfiguration) {
        schemaVersion = BrowserCaptureContract.currentSchemaVersion
        libraryVersion = BrowserCaptureContract.libraryVersion
        supportedActions = BrowserActionKind.allCases

        var sources: [CapturedResponse.Source] = []
        if configuration.capturesFetch { sources.append(.fetch) }
        if configuration.capturesXHR { sources.append(.xhr) }
        if configuration.capturesWebSocket {
            sources.append(contentsOf: [.websocket, .eventsource, .beacon])
        }
        captureSources = sources
        requiresVisibleBrowser = true
        controlsOtherApps = false
    }
}
