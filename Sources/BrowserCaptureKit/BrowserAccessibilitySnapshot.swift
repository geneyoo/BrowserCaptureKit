import Foundation

public struct BrowserAccessibilitySnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    public let reason: String
    public let url: URL?
    public let title: String?
    public let viewportWidth: Double?
    public let viewportHeight: Double?
    public let elementCount: Int
    public let labeledElementCount: Int
    public let unlabeledInteractiveElementCount: Int
    public let elementsOmitted: Int
    public let elements: [BrowserAccessibilityElementSnapshot]
    public let javaScriptError: String?

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        reason: String,
        url: URL?,
        title: String?,
        viewportWidth: Double?,
        viewportHeight: Double?,
        elementCount: Int,
        labeledElementCount: Int,
        unlabeledInteractiveElementCount: Int,
        elementsOmitted: Int,
        elements: [BrowserAccessibilityElementSnapshot],
        javaScriptError: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.reason = reason
        self.url = url
        self.title = title
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.elementCount = elementCount
        self.labeledElementCount = labeledElementCount
        self.unlabeledInteractiveElementCount = unlabeledInteractiveElementCount
        self.elementsOmitted = elementsOmitted
        self.elements = elements
        self.javaScriptError = javaScriptError
    }
}

public struct BrowserAccessibilityElementSnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let index: Int
    public let tagName: String
    public let role: String?
    public let label: String?
    public let labelSource: String?
    public let text: String?
    public let value: String?
    public let placeholder: String?
    public let href: String?
    public let source: String?
    public let inputType: String?
    public let isVisible: Bool
    public let isInteractive: Bool
    public let isDisabled: Bool
    public let ariaHidden: Bool
    public let bounds: BrowserElementBounds
    public let path: String

    public init(
        id: UUID = UUID(),
        index: Int,
        tagName: String,
        role: String?,
        label: String?,
        labelSource: String?,
        text: String?,
        value: String?,
        placeholder: String?,
        href: String?,
        source: String?,
        inputType: String?,
        isVisible: Bool,
        isInteractive: Bool,
        isDisabled: Bool,
        ariaHidden: Bool,
        bounds: BrowserElementBounds,
        path: String
    ) {
        self.id = id
        self.index = index
        self.tagName = tagName
        self.role = role
        self.label = label
        self.labelSource = labelSource
        self.text = text
        self.value = value
        self.placeholder = placeholder
        self.href = href
        self.source = source
        self.inputType = inputType
        self.isVisible = isVisible
        self.isInteractive = isInteractive
        self.isDisabled = isDisabled
        self.ariaHidden = ariaHidden
        self.bounds = bounds
        self.path = path
    }
}

public struct BrowserElementBounds: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
