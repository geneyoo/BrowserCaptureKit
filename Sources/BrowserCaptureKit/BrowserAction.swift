import Foundation

public enum BrowserActionKind: String, Equatable, Sendable {
    case click
    case scroll
}

public struct BrowserActionResult: Equatable, Sendable {
    public let kind: BrowserActionKind
    public let succeeded: Bool
    public let message: String
    public let matchedElementCount: Int
    public let label: String?
    public let role: String?
    public let path: String?

    public init(
        kind: BrowserActionKind,
        succeeded: Bool,
        message: String,
        matchedElementCount: Int = 0,
        label: String? = nil,
        role: String? = nil,
        path: String? = nil
    ) {
        self.kind = kind
        self.succeeded = succeeded
        self.message = message
        self.matchedElementCount = matchedElementCount
        self.label = label
        self.role = role
        self.path = path
    }
}
