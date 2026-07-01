import Foundation

public enum BrowserActionKind: String, Codable, Equatable, Sendable {
    case observe
    case tap
    case fill
    case clear
    case pressEnter
    case scroll
    case swipe
    case openURL
    case back
    case forward
    case reload
    case waitFor
}

public enum BrowserActionStatus: String, Codable, Equatable, Sendable {
    case succeeded
    case noWebView
    case noMatch
    case ambiguousMatch
    case notVisible
    case notEnabled
    case notEditable
    case obscured
    case timedOut
    case scriptError
    case userActivationRequired
    case humanInputRequired
    case staleSnapshot
    case unsupported
}

public enum BrowserSwipeDirection: String, Codable, Equatable, Sendable {
    case up
    case down
    case left
    case right
}

public struct BrowserElementTarget: Codable, Equatable, Sendable {
    public let snapshotID: UUID?
    public let pageEpoch: Int?
    public let snapshotElementID: String?
    public let path: String?
    public let selectorFingerprint: String?
    public let role: String?
    public let label: String?
    public let text: String?
    public let bounds: BrowserElementBounds?

    public init(
        snapshotID: UUID? = nil,
        pageEpoch: Int? = nil,
        snapshotElementID: String? = nil,
        path: String? = nil,
        selectorFingerprint: String? = nil,
        role: String? = nil,
        label: String? = nil,
        text: String? = nil,
        bounds: BrowserElementBounds? = nil
    ) {
        self.snapshotID = snapshotID
        self.pageEpoch = pageEpoch
        self.snapshotElementID = snapshotElementID
        self.path = path
        self.selectorFingerprint = selectorFingerprint
        self.role = role
        self.label = label
        self.text = text
        self.bounds = bounds
    }

    public static func label(_ label: String, role: String? = nil) -> BrowserElementTarget {
        BrowserElementTarget(role: role, label: label)
    }
}

public enum BrowserActionRequest: Codable, Equatable, Sendable {
    case observe(reason: String)
    case tap(target: BrowserElementTarget)
    case fill(target: BrowserElementTarget, text: String, submit: Bool)
    case clear(target: BrowserElementTarget)
    case pressEnter(target: BrowserElementTarget?)
    case scroll(deltaX: Double, deltaY: Double)
    case swipe(target: BrowserElementTarget?, direction: BrowserSwipeDirection)
    case openURL(URL)
    case back
    case forward
    case reload
    case waitFor(BrowserWaitCondition)

    public var kind: BrowserActionKind {
        switch self {
        case .observe:
            return .observe
        case .tap:
            return .tap
        case .fill:
            return .fill
        case .clear:
            return .clear
        case .pressEnter:
            return .pressEnter
        case .scroll:
            return .scroll
        case .swipe:
            return .swipe
        case .openURL:
            return .openURL
        case .back:
            return .back
        case .forward:
            return .forward
        case .reload:
            return .reload
        case .waitFor:
            return .waitFor
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case reason
        case target
        case text
        case submit
        case deltaX
        case deltaY
        case direction
        case url
        case condition
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(BrowserActionKind.self, forKey: .kind)
        switch kind {
        case .observe:
            self = .observe(reason: try container.decodeIfPresent(String.self, forKey: .reason) ?? "protocol")
        case .tap:
            self = .tap(target: try container.decode(BrowserElementTarget.self, forKey: .target))
        case .fill:
            self = .fill(
                target: try container.decode(BrowserElementTarget.self, forKey: .target),
                text: try container.decode(String.self, forKey: .text),
                submit: try container.decodeIfPresent(Bool.self, forKey: .submit) ?? false
            )
        case .clear:
            self = .clear(target: try container.decode(BrowserElementTarget.self, forKey: .target))
        case .pressEnter:
            self = .pressEnter(target: try container.decodeIfPresent(BrowserElementTarget.self, forKey: .target))
        case .scroll:
            self = .scroll(
                deltaX: try container.decodeIfPresent(Double.self, forKey: .deltaX) ?? 0,
                deltaY: try container.decodeIfPresent(Double.self, forKey: .deltaY) ?? 0
            )
        case .swipe:
            self = .swipe(
                target: try container.decodeIfPresent(BrowserElementTarget.self, forKey: .target),
                direction: try container.decode(BrowserSwipeDirection.self, forKey: .direction)
            )
        case .openURL:
            self = .openURL(try container.decode(URL.self, forKey: .url))
        case .back:
            self = .back
        case .forward:
            self = .forward
        case .reload:
            self = .reload
        case .waitFor:
            self = .waitFor(try container.decode(BrowserWaitCondition.self, forKey: .condition))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .observe(let reason):
            try container.encode(reason, forKey: .reason)
        case .tap(let target):
            try container.encode(target, forKey: .target)
        case .fill(let target, let text, let submit):
            try container.encode(target, forKey: .target)
            try container.encode(text, forKey: .text)
            try container.encode(submit, forKey: .submit)
        case .clear(let target):
            try container.encode(target, forKey: .target)
        case .pressEnter(let target):
            try container.encodeIfPresent(target, forKey: .target)
        case .scroll(let deltaX, let deltaY):
            try container.encode(deltaX, forKey: .deltaX)
            try container.encode(deltaY, forKey: .deltaY)
        case .swipe(let target, let direction):
            try container.encodeIfPresent(target, forKey: .target)
            try container.encode(direction, forKey: .direction)
        case .openURL(let url):
            try container.encode(url, forKey: .url)
        case .back, .forward, .reload:
            break
        case .waitFor(let condition):
            try container.encode(condition, forKey: .condition)
        }
    }
}

public enum BrowserWaitCondition: Codable, Equatable, Sendable {
    case urlContains(String)
    case element(BrowserElementTarget)
    case quiet(milliseconds: Int)

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case target
        case milliseconds
    }

    private enum Kind: String, Codable {
        case urlContains
        case element
        case quiet
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .urlContains:
            self = .urlContains(try container.decode(String.self, forKey: .text))
        case .element:
            self = .element(try container.decode(BrowserElementTarget.self, forKey: .target))
        case .quiet:
            self = .quiet(milliseconds: try container.decode(Int.self, forKey: .milliseconds))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .urlContains(let text):
            try container.encode(Kind.urlContains, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .element(let target):
            try container.encode(Kind.element, forKey: .kind)
            try container.encode(target, forKey: .target)
        case .quiet(let milliseconds):
            try container.encode(Kind.quiet, forKey: .kind)
            try container.encode(milliseconds, forKey: .milliseconds)
        }
    }
}

public struct BrowserResolvedElement: Codable, Equatable, Sendable {
    public let score: Double
    public let index: Int?
    public let tagName: String?
    public let role: String?
    public let label: String?
    public let text: String?
    public let path: String?
    public let selectorFingerprint: String?
    public let bounds: BrowserElementBounds?
    public let isVisible: Bool
    public let isInteractive: Bool
    public let isDisabled: Bool
    public let isEditable: Bool
    public let isObscuredAtCenter: Bool

    public init(
        score: Double,
        index: Int?,
        tagName: String?,
        role: String?,
        label: String?,
        text: String?,
        path: String?,
        selectorFingerprint: String?,
        bounds: BrowserElementBounds?,
        isVisible: Bool,
        isInteractive: Bool,
        isDisabled: Bool,
        isEditable: Bool,
        isObscuredAtCenter: Bool
    ) {
        self.score = score
        self.index = index
        self.tagName = tagName
        self.role = role
        self.label = label
        self.text = text
        self.path = path
        self.selectorFingerprint = selectorFingerprint
        self.bounds = bounds
        self.isVisible = isVisible
        self.isInteractive = isInteractive
        self.isDisabled = isDisabled
        self.isEditable = isEditable
        self.isObscuredAtCenter = isObscuredAtCenter
    }
}

public struct BrowserActionResult: Codable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let requestID: UUID
    public let schemaVersion: Int
    public let kind: BrowserActionKind
    public let status: BrowserActionStatus
    public let message: String
    public let matchedElementCount: Int
    public let selectedElement: BrowserResolvedElement?
    public let candidateSummaries: [BrowserResolvedElement]
    public let beforeSnapshotID: UUID?
    public let afterSnapshotID: UUID?
    public let urlBefore: URL?
    public let urlAfter: URL?
    public let networkEventCountDelta: Int
    public let warnings: [String]

    public var succeeded: Bool {
        status == .succeeded
    }

    public let label: String?

    public let role: String?

    public let path: String?

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        requestID: UUID = UUID(),
        schemaVersion: Int = 1,
        kind: BrowserActionKind,
        status: BrowserActionStatus,
        message: String,
        matchedElementCount: Int = 0,
        selectedElement: BrowserResolvedElement? = nil,
        candidateSummaries: [BrowserResolvedElement] = [],
        beforeSnapshotID: UUID? = nil,
        afterSnapshotID: UUID? = nil,
        urlBefore: URL? = nil,
        urlAfter: URL? = nil,
        networkEventCountDelta: Int = 0,
        warnings: [String] = [],
        label: String? = nil,
        role: String? = nil,
        path: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.requestID = requestID
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.status = status
        self.message = message
        self.matchedElementCount = matchedElementCount
        self.selectedElement = selectedElement
        self.candidateSummaries = candidateSummaries
        self.beforeSnapshotID = beforeSnapshotID
        self.afterSnapshotID = afterSnapshotID
        self.urlBefore = urlBefore
        self.urlAfter = urlAfter
        self.networkEventCountDelta = networkEventCountDelta
        self.warnings = warnings
        self.label = label
        self.role = role
        self.path = path
    }

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        requestID: UUID = UUID(),
        schemaVersion: Int = 1,
        kind: BrowserActionKind,
        succeeded: Bool,
        message: String,
        matchedElementCount: Int = 0,
        label: String? = nil,
        role: String? = nil,
        path: String? = nil
    ) {
        let selectedElement = BrowserResolvedElement(
            score: 0,
            index: nil,
            tagName: nil,
            role: role,
            label: label,
            text: nil,
            path: path,
            selectorFingerprint: nil,
            bounds: nil,
            isVisible: false,
            isInteractive: false,
            isDisabled: false,
            isEditable: false,
            isObscuredAtCenter: false
        )
        self.init(
            id: id,
            capturedAt: capturedAt,
            requestID: requestID,
            schemaVersion: schemaVersion,
            kind: kind,
            status: succeeded ? .succeeded : .scriptError,
            message: message,
            matchedElementCount: matchedElementCount,
            selectedElement: label == nil && role == nil && path == nil ? nil : selectedElement,
            candidateSummaries: [],
            warnings: [],
            label: label,
            role: role,
            path: path
        )
    }
}
