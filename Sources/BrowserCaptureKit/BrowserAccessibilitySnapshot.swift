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
    /// Security origin of the child frame that owns this element; `nil` for
    /// main-frame elements. Child-frame elements in a merged snapshot carry the
    /// widget iframe's origin (e.g. "https://widget.lpsnmedia.net").
    public let frameOrigin: String?

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
        supportedActions: [BrowserActionKind] = [],
        frameOrigin: String? = nil
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
        self.frameOrigin = frameOrigin
    }
}

extension BrowserAccessibilityElementSnapshot {
    /// Copy used by the cross-frame snapshot merge: namespaces the stableID so
    /// element IDs stay unique across frames, stamps the owning frame's origin,
    /// and (best effort) offsets frame-local bounds by the owning `<iframe>`'s
    /// bounds in the parent so coordinates land in main-frame viewport space.
    ///
    /// The executable element ID the server round-trips (`elementId`) is
    /// `stableID ?? id.uuidString`, so every child-frame element gets a
    /// namespaced stableID — synthesized from the ephemeral UUID when the
    /// capture script provided none — guaranteeing the server-visible ID is
    /// namespaced (routable) and unique across frames (two frames can emit
    /// identical bare stableIDs).
    func inChildFrame(
        namespaceID: String,
        frameOrigin: String,
        boundsOffset: BrowserElementBounds?
    ) -> BrowserAccessibilityElementSnapshot {
        BrowserAccessibilityElementSnapshot(
            id: id,
            stableID: BrowserFrameNamespace.apply(namespaceID, to: stableID ?? id.uuidString),
            index: index,
            tagName: tagName,
            role: role,
            label: label,
            labelSource: labelSource,
            text: text,
            value: value,
            placeholder: placeholder,
            href: href,
            source: source,
            inputType: inputType,
            isVisible: isVisible,
            isInteractive: isInteractive,
            isDisabled: isDisabled,
            isEditable: isEditable,
            isObscuredAtCenter: isObscuredAtCenter,
            ariaHidden: ariaHidden,
            bounds: boundsOffset.map {
                BrowserElementBounds(
                    x: bounds.x + $0.x,
                    y: bounds.y + $0.y,
                    width: bounds.width,
                    height: bounds.height
                )
            } ?? bounds,
            path: path,
            selectorFingerprint: selectorFingerprint,
            supportedActions: supportedActions,
            frameOrigin: frameOrigin
        )
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
