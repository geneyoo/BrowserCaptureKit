import Foundation

public struct BrowserAccessibilitySnapshot: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let schemaVersion: Int
    public let capturedAt: Date
    public let reason: String
    public let pageEpoch: Int
    public let url: URL?
    public let title: String?
    public let scrollX: Double?
    public let scrollY: Double?
    public let viewportOffsetX: Double?
    public let viewportOffsetY: Double?
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
        schemaVersion: Int = 1,
        capturedAt: Date = Date(),
        reason: String,
        pageEpoch: Int = 0,
        url: URL?,
        title: String?,
        scrollX: Double? = nil,
        scrollY: Double? = nil,
        viewportOffsetX: Double? = nil,
        viewportOffsetY: Double? = nil,
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
        self.schemaVersion = schemaVersion
        self.capturedAt = capturedAt
        self.reason = reason
        self.pageEpoch = pageEpoch
        self.url = url
        self.title = title
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.viewportOffsetX = viewportOffsetX
        self.viewportOffsetY = viewportOffsetY
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
    public let stableID: String?
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
    public let isEditable: Bool
    public let isObscuredAtCenter: Bool
    public let ariaHidden: Bool
    public let bounds: BrowserElementBounds
    public let path: String
    public let selectorFingerprint: String?
    public let supportedActions: [BrowserActionKind]

    public init(
        id: UUID = UUID(),
        stableID: String? = nil,
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
        isEditable: Bool = false,
        isObscuredAtCenter: Bool = false,
        ariaHidden: Bool,
        bounds: BrowserElementBounds,
        path: String,
        selectorFingerprint: String? = nil,
        supportedActions: [BrowserActionKind] = []
    ) {
        self.id = id
        self.stableID = stableID
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
        self.isEditable = isEditable
        self.isObscuredAtCenter = isObscuredAtCenter
        self.ariaHidden = ariaHidden
        self.bounds = bounds
        self.path = path
        self.selectorFingerprint = selectorFingerprint
        self.supportedActions = supportedActions
    }
}

public struct BrowserElementBounds: Codable, Equatable, Sendable {
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
