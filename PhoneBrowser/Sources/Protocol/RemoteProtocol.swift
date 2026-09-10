import BrowserCaptureKit
import Foundation

/// Wire contract between the phone host and the relay. JSON over one outbound
/// WebSocket the phone opens. Versioned separately from the package schema:
/// the package types stay browser-neutral; these add remote lifecycle fields.
enum PhoneBrowserProtocol {
    static let version = 1
}

// MARK: - Service → device

enum RelayInboundMessage: Equatable {
    case helloAck(HelloAck)
    case command(RemoteCommand)
    case cancel(commandID: String)
    /// A message type this host does not understand. Ignored after logging;
    /// never executed.
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case commandID = "commandId"
    }

    private enum Kind: String {
        case helloAck
        case command
        case cancel
    }
}

extension RelayInboundMessage: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: rawType) else {
            self = .unknown(type: rawType)
            return
        }
        switch kind {
        case .helloAck:
            self = .helloAck(try HelloAck(from: decoder))
        case .command:
            self = .command(try RemoteCommand(from: decoder))
        case .cancel:
            self = .cancel(commandID: try container.decode(String.self, forKey: .commandID))
        }
    }
}

struct HelloAck: Codable, Equatable {
    let serverTime: Date?
    /// Commands the service sent but holds no terminal result for. The device
    /// answers each from its journal before it accepts new mutation work.
    let unresolvedCommandIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case serverTime
        case unresolvedCommandIDs = "unresolvedCommandIds"
    }

    init(serverTime: Date? = nil, unresolvedCommandIDs: [String] = []) {
        self.serverTime = serverTime
        self.unresolvedCommandIDs = unresolvedCommandIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        serverTime = try container.decodeIfPresent(Date.self, forKey: .serverTime)
        unresolvedCommandIDs = try container.decodeIfPresent([String].self, forKey: .unresolvedCommandIDs) ?? []
    }
}

struct RemoteCommand: Codable, Equatable {
    let commandID: String
    let sessionID: String
    let controllerGeneration: Int
    let issuedAt: Date
    let deadline: Date
    let operation: RemoteOperation

    private enum CodingKeys: String, CodingKey {
        case commandID = "commandId"
        case sessionID = "sessionId"
        case controllerGeneration
        case issuedAt
        case deadline
        case operation
    }

    init(
        commandID: String,
        sessionID: String,
        controllerGeneration: Int,
        issuedAt: Date = Date(),
        deadline: Date,
        operation: RemoteOperation
    ) {
        self.commandID = commandID
        self.sessionID = sessionID
        self.controllerGeneration = controllerGeneration
        self.issuedAt = issuedAt
        self.deadline = deadline
        self.operation = operation
    }
}

/// Typed operations the host implements. Anything else decodes as
/// `.unsupported` so the command can still be rejected by ID.
enum RemoteOperation: Codable, Equatable {
    case observe(includeImage: Bool, maxElements: Int)
    case navigate(url: URL)
    case act(RemoteAct)
    case events(afterSequence: Int, limit: Int)
    case commandStatus(commandID: String)
    case unsupported(kind: String, detail: String)

    static let defaultMaxElements = 120
    static let maxElementsCeiling = 500
    static let defaultEventLimit = 100
    static let eventLimitCeiling = 500

    var kind: String {
        switch self {
        case .observe: "observe"
        case .navigate: "navigate"
        case .act: "act"
        case .events: "events"
        case .commandStatus: "commandStatus"
        case .unsupported(let kind, _): kind
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case includeImage
        case maxElements
        case url
        case action
        case afterSequence
        case limit
        case commandID = "commandId"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        do {
            switch kind {
            case "observe":
                let maxElements = try container.decodeIfPresent(Int.self, forKey: .maxElements)
                    ?? Self.defaultMaxElements
                self = .observe(
                    includeImage: try container.decodeIfPresent(Bool.self, forKey: .includeImage) ?? false,
                    maxElements: min(max(1, maxElements), Self.maxElementsCeiling)
                )
            case "navigate":
                self = .navigate(url: try container.decode(URL.self, forKey: .url))
            case "act":
                self = .act(try container.decode(RemoteAct.self, forKey: .action))
            case "events":
                let limit = try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultEventLimit
                self = .events(
                    afterSequence: try container.decodeIfPresent(Int.self, forKey: .afterSequence) ?? 0,
                    limit: min(max(1, limit), Self.eventLimitCeiling)
                )
            case "commandStatus":
                self = .commandStatus(commandID: try container.decode(String.self, forKey: .commandID))
            default:
                self = .unsupported(kind: kind, detail: "Unknown operation kind.")
            }
        } catch let error as DecodingError {
            self = .unsupported(kind: kind, detail: Self.describe(error))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .observe(let includeImage, let maxElements):
            try container.encode(includeImage, forKey: .includeImage)
            try container.encode(maxElements, forKey: .maxElements)
        case .navigate(let url):
            try container.encode(url, forKey: .url)
        case .act(let act):
            try container.encode(act, forKey: .action)
        case .events(let afterSequence, let limit):
            try container.encode(afterSequence, forKey: .afterSequence)
            try container.encode(limit, forKey: .limit)
        case .commandStatus(let commandID):
            try container.encode(commandID, forKey: .commandID)
        case .unsupported:
            break
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            "Missing field '\(key.stringValue)'."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            context.debugDescription
        @unknown default:
            "Malformed operation."
        }
    }
}

/// An element action bound to one prior observation. The element ID is the
/// observation's stable element identity; labels never act as a fallback.
struct RemoteAct: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case tap
        case fill
    }

    static let maxFillTextCharacters = 4_096

    let kind: Kind
    let observationID: String
    let elementID: String
    let text: String?

    private enum CodingKeys: String, CodingKey {
        case kind
        case observationID = "observationId"
        case elementID = "elementId"
        case text
    }

    init(kind: Kind, observationID: String, elementID: String, text: String? = nil) {
        self.kind = kind
        self.observationID = observationID
        self.elementID = elementID
        self.text = text
    }
}

// MARK: - Device → service

enum RelayOutboundMessage: Encodable, Equatable {
    case hello(DeviceHello)
    case receipt(CommandReceipt)
    case result(CommandResultMessage)
    case status(DeviceStatus)

    private enum CodingKeys: String, CodingKey {
        case type
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let hello):
            try container.encode("hello", forKey: .type)
            try hello.encode(to: encoder)
        case .receipt(let receipt):
            try container.encode("receipt", forKey: .type)
            try receipt.encode(to: encoder)
        case .result(let result):
            try container.encode("result", forKey: .type)
            try result.encode(to: encoder)
        case .status(let status):
            try container.encode("status", forKey: .type)
            try status.encode(to: encoder)
        }
    }
}

enum DeviceReadiness: String, Codable, Equatable {
    case disconnected
    case connecting
    case ready
    case executing
    case humanControl
    case foregroundRequired
    case recovering
}

struct DeviceCapabilities: Codable, Equatable {
    let protocolVersion: Int
    let operations: [String]
    let actions: [String]
    let imageScope: String
    let eventSources: [String]
    let requiresForeground: Bool
    let controlsOtherApps: Bool
    let humanInputRequiredFor: [String]

    static func current(configuration: BrowserCaptureConfiguration) -> DeviceCapabilities {
        let package = BrowserCaptureCapabilities(configuration: configuration)
        return DeviceCapabilities(
            protocolVersion: PhoneBrowserProtocol.version,
            operations: ["observe", "navigate", "act", "events", "commandStatus"],
            actions: RemoteAct.Kind.allCases.map(\.rawValue),
            imageScope: ObservationImage.scope,
            eventSources: ["page", "nativeNetwork", "action", "dialog", "lifecycle"]
                + package.captureSources.map(\.rawValue)
                + (configuration.capturesConsole ? ["console"] : []),
            requiresForeground: true,
            controlsOtherApps: false,
            humanInputRequiredFor: [
                "credentials", "mfa", "payment", "sensitiveFields", "userActivation", "nativePickers",
            ]
        )
    }
}

struct DeviceHello: Codable, Equatable {
    let protocolVersion: Int
    let deviceID: String
    let sessionID: String
    let processInstanceID: String
    let appVersion: String
    let osVersion: String
    let libraryVersion: String
    let controllerGeneration: Int
    let readiness: DeviceReadiness
    let eventCursor: Int
    let capabilities: DeviceCapabilities

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case deviceID = "deviceId"
        case sessionID = "sessionId"
        case processInstanceID = "processInstanceId"
        case appVersion
        case osVersion
        case libraryVersion
        case controllerGeneration
        case readiness
        case eventCursor
        case capabilities
    }
}

enum CommandState: String, Codable, Equatable {
    case accepted
    case dispatching
    case completed
    case rejected
    case cancelled
    case uncertain

    var isTerminal: Bool {
        switch self {
        case .completed, .rejected, .cancelled, .uncertain: true
        case .accepted, .dispatching: false
        }
    }
}

enum RejectionReason: String, Codable, Equatable {
    case unsupportedOperation
    case protocolMismatch
    case sessionMismatch
    case controllerGenerationMismatch
    case expired
    case humanControl
    case notReady
    case commandReused
    case unknownObservation
    case staleObservation
    case observationBeforeResume
    case unknownElement
    case unsupportedElementAction
    case oversizedInput
    case unsupportedURL
    case cancelled
    case unknownCommand
}

struct CommandReceipt: Codable, Equatable {
    let commandID: String
    let accepted: Bool
    let state: CommandState
    let reason: RejectionReason?
    let message: String?

    private enum CodingKeys: String, CodingKey {
        case commandID = "commandId"
        case accepted
        case state
        case reason
        case message
    }

    static func accepted(_ commandID: String, state: CommandState = .accepted) -> CommandReceipt {
        CommandReceipt(commandID: commandID, accepted: true, state: state, reason: nil, message: nil)
    }

    static func rejected(_ commandID: String, _ reason: RejectionReason, _ message: String) -> CommandReceipt {
        CommandReceipt(commandID: commandID, accepted: false, state: .rejected, reason: reason, message: message)
    }
}

/// Whether re-issuing the same operation under a new command ID is safe.
enum RetryClassification: String, Codable, Equatable {
    /// No browser side effect was started.
    case notStarted
    /// The operation is idempotent for the page (observe, events, a GET navigation).
    case safe
    /// A DOM action was dispatched; the website outcome must be re-observed first.
    case unsafe
}

struct CommandResultMessage: Codable, Equatable {
    let commandID: String
    let state: CommandState
    let startedAt: Date?
    let completedAt: Date?
    let retryClassification: RetryClassification
    let reason: RejectionReason?
    let message: String?
    let payload: CommandResultPayload?

    private enum CodingKeys: String, CodingKey {
        case commandID = "commandId"
        case state
        case startedAt
        case completedAt
        case retryClassification
        case reason
        case message
        case payload
    }
}

indirect enum CommandResultPayload: Codable, Equatable {
    case observation(ObservationBundle)
    case navigation(NavigationOutcome)
    case action(ActionOutcome)
    case events(EventPage)
    case commandStatus(JournalRecordSummary)

    private enum CodingKeys: String, CodingKey {
        case kind
        case observation
        case navigation
        case action
        case events
        case commandStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "observation":
            self = .observation(try container.decode(ObservationBundle.self, forKey: .observation))
        case "navigation":
            self = .navigation(try container.decode(NavigationOutcome.self, forKey: .navigation))
        case "action":
            self = .action(try container.decode(ActionOutcome.self, forKey: .action))
        case "events":
            self = .events(try container.decode(EventPage.self, forKey: .events))
        case "commandStatus":
            self = .commandStatus(try container.decode(JournalRecordSummary.self, forKey: .commandStatus))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: container, debugDescription: "Unknown payload kind '\(other)'.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .observation(let value):
            try container.encode("observation", forKey: .kind)
            try container.encode(value, forKey: .observation)
        case .navigation(let value):
            try container.encode("navigation", forKey: .kind)
            try container.encode(value, forKey: .navigation)
        case .action(let value):
            try container.encode("action", forKey: .kind)
            try container.encode(value, forKey: .action)
        case .events(let value):
            try container.encode("events", forKey: .kind)
            try container.encode(value, forKey: .events)
        case .commandStatus(let value):
            try container.encode("commandStatus", forKey: .kind)
            try container.encode(value, forKey: .commandStatus)
        }
    }
}

struct DeviceStatus: Codable, Equatable {
    let readiness: DeviceReadiness
    let sessionID: String
    let controllerGeneration: Int
    let humanControl: Bool
    let foreground: Bool
    let activeCommandID: String?
    let pageURL: String?
    let eventCursor: Int

    private enum CodingKeys: String, CodingKey {
        case readiness
        case sessionID = "sessionId"
        case controllerGeneration
        case humanControl
        case foreground
        case activeCommandID = "activeCommandId"
        case pageURL = "pageUrl"
        case eventCursor
    }
}

// MARK: - Result payloads

struct NavigationOutcome: Codable, Equatable {
    let status: String
    let message: String
    let urlBefore: String?
    let urlAfter: String?
    let pageEpoch: Int
    let networkEventCountDelta: Int
}

struct ActionOutcome: Codable, Equatable {
    let kind: String
    let status: String
    let message: String
    let observationID: String
    let elementID: String
    let matchedElementCount: Int
    let urlBefore: String?
    let urlAfter: String?
    let pageEpochAfter: Int
    let networkEventCountDelta: Int
    let warnings: [String]

    private enum CodingKeys: String, CodingKey {
        case kind
        case status
        case message
        case observationID = "observationId"
        case elementID = "elementId"
        case matchedElementCount
        case urlBefore
        case urlAfter
        case pageEpochAfter
        case networkEventCountDelta
        case warnings
    }
}

struct JournalRecordSummary: Codable, Equatable {
    let commandID: String
    let sessionID: String
    let state: CommandState
    let acceptedAt: Date
    let dispatchingAt: Date?
    let completedAt: Date?
    let retryClassification: RetryClassification?
    let result: CommandResultMessage?

    private enum CodingKeys: String, CodingKey {
        case commandID = "commandId"
        case sessionID = "sessionId"
        case state
        case acceptedAt
        case dispatchingAt
        case completedAt
        case retryClassification
        case result
    }
}

// MARK: - Observation bundle

struct ObservationBundle: Codable, Equatable {
    let observationID: String
    let sessionID: String
    let controllerGeneration: Int
    let pageEpoch: Int
    let url: String?
    let title: String?
    let capture: CaptureInterval
    /// `WKWebView.isLoading` at capture end. A committed navigation bumps the
    /// page epoch before the new document exists, so a capture taken while
    /// loading may describe the outgoing document; re-observe when true.
    let documentLoading: Bool
    let viewport: ViewportInfo
    let elements: [ObservedElement]
    let elementCount: Int
    let elementsOmitted: Int
    let image: ObservationImage?
    let imageOmittedReason: String?
    let eventCursor: Int
    let coverage: ObservationCoverage

    private enum CodingKeys: String, CodingKey {
        case observationID = "observationId"
        case sessionID = "sessionId"
        case controllerGeneration
        case pageEpoch
        case url
        case title
        case capture
        case documentLoading
        case viewport
        case elements
        case elementCount
        case elementsOmitted
        case image
        case imageOmittedReason
        case eventCursor
        case coverage
    }
}

/// DOM capture and the image are separate asynchronous operations. The
/// interval records both boundaries and whether the document changed between
/// them instead of claiming an atomic capture.
struct CaptureInterval: Codable, Equatable {
    let startedAt: Date
    let endedAt: Date
    let pageEpochAtStart: Int
    let pageEpochAtEnd: Int
    let changedDuringCapture: Bool
}

struct ViewportInfo: Codable, Equatable {
    /// CSS visual viewport, in CSS pixels.
    let width: Double?
    let height: Double?
    let scrollX: Double?
    let scrollY: Double?
    /// The hosting `WKWebView` bounds in points. Element bounds are CSS viewport
    /// coordinates relative to the web view's origin.
    let webViewPointWidth: Double
    let webViewPointHeight: Double
}

struct ObservedElement: Codable, Equatable {
    let id: String
    let index: Int
    let tagName: String
    let role: String?
    let label: String?
    let text: String?
    /// Editable values are user data: the package never reads them and they
    /// never leave the phone. Only static control values (buttons, selects)
    /// are reported.
    let value: String?
    let placeholder: String?
    let inputType: String?
    let href: String?
    let isVisible: Bool
    let isInteractive: Bool
    let isDisabled: Bool
    let isEditable: Bool
    let isObscuredAtCenter: Bool
    let isSensitive: Bool
    let bounds: BrowserElementBounds
    let frameOrigin: String?
    let supportedActions: [String]
}

struct ObservationImage: Codable, Equatable {
    static let scope = "webViewViewport"
    static let format = "jpeg"

    let format: String
    let scope: String
    let base64: String
    let pixelWidth: Int
    let pixelHeight: Int
    let pointWidth: Double
    let pointHeight: Double
    let capturedAt: Date
}

struct ObservationCoverage: Codable, Equatable {
    let javaScriptError: String?
    let childFrameOrigins: [String]
    let elementsWithoutStableIdentity: Int
    let notes: [String]
}

// MARK: - Exported events

struct EventPage: Codable, Equatable {
    let events: [ExportedEvent]
    let fromSequence: Int
    let toSequence: Int
    let latestSequence: Int
    /// Sequences before `droppedThrough` were discarded from the bounded buffer.
    let droppedThrough: Int?
    let truncated: Bool
}

/// Sanitized, bounded evidence item. Built by the evidence collector at
/// export time; carries event-time provenance (sequence, page epoch).
struct ExportedEvent: Codable, Equatable {
    let sequence: Int
    let capturedAt: Date
    let pageEpoch: Int
    let kind: String
    let source: String?
    let direction: String?
    let method: String?
    let url: String?
    let status: Int?
    let contentType: String?
    let frameOrigin: String?
    let isForMainFrame: Bool?
    let durationMilliseconds: Double?
    let message: String?
    let actionKind: String?
    let actionStatus: String?
    let urlAfter: String?
    let bodiesOmitted: Bool
    let truncated: Bool
}
