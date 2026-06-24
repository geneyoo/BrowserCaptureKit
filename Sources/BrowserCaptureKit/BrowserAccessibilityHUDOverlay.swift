import SwiftUI

public struct BrowserAccessibilityHUDOverlay: View {
    private let snapshot: BrowserAccessibilitySnapshot?
    private let maxElements: Int

    public init(snapshot: BrowserAccessibilitySnapshot?, maxElements: Int = 260) {
        self.snapshot = snapshot
        self.maxElements = maxElements
    }

    private var overlayElements: [BrowserAccessibilityElementSnapshot] {
        guard let snapshot else {
            return []
        }

        return snapshot.elements
            .filter { element in
                element.label?.isEmpty == false || element.isInteractive
            }
            .prefix(maxElements)
            .map(\.self)
    }

    public var body: some View {
        GeometryReader { geometry in
            let viewportWidth = max(CGFloat(snapshot?.viewportWidth ?? Double(geometry.size.width)), 1)
            let scale = geometry.size.width / viewportWidth

            ZStack(alignment: .topLeading) {
                ForEach(overlayElements) { element in
                    BrowserAccessibilityElementOverlay(
                        element: element,
                        scale: scale,
                        containerSize: geometry.size
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}

private struct BrowserAccessibilityElementOverlay: View {
    let element: BrowserAccessibilityElementSnapshot
    let scale: CGFloat
    let containerSize: CGSize

    private var overlayText: String {
        let rawText = element.label ?? (element.isInteractive ? "missing label" : "")
        if rawText.count <= 260 {
            return rawText
        }
        return "\(rawText.prefix(257))..."
    }

    private var isMissingLabel: Bool {
        element.isInteractive && (element.label?.isEmpty ?? true)
    }

    private var borderColor: Color {
        isMissingLabel ? Color.red.opacity(0.9) : Color.cyan.opacity(0.85)
    }

    private var backgroundColor: Color {
        isMissingLabel ? Color.red.opacity(0.76) : Color.black.opacity(0.66)
    }

    private var preferredChipWidth: CGFloat {
        let estimated = CGFloat(overlayText.count) * 5.8 + 14
        return min(max(estimated, 86), 380)
    }

    private var scaledBounds: CGRect {
        CGRect(
            x: CGFloat(element.bounds.x) * scale,
            y: CGFloat(element.bounds.y) * scale,
            width: max(CGFloat(element.bounds.width) * scale, 18),
            height: max(CGFloat(element.bounds.height) * scale, 18)
        )
    }

    private var chipWidth: CGFloat {
        min(preferredChipWidth, max(containerSize.width - 8, 86))
    }

    private var estimatedChipHeight: CGFloat {
        let charactersPerLine = max(Int((chipWidth - 8) / 5.8), 8)
        let lineCount = min(max(Int(ceil(Double(overlayText.count) / Double(charactersPerLine))), 1), 6)
        return CGFloat(lineCount) * 13 + 8
    }

    private var chipOrigin: CGPoint {
        let bounds = scaledBounds
        let maxX = max(containerSize.width - chipWidth - 4, 4)
        let labelX = min(max(bounds.minX, 4), maxX)
        let preferredAboveY = bounds.minY - estimatedChipHeight - 2
        let preferredY = preferredAboveY >= 4 ? preferredAboveY : bounds.minY + 2
        let maxY = max(containerSize.height - estimatedChipHeight - 4, 4)
        let labelY = min(max(preferredY, 4), maxY)

        return CGPoint(x: labelX, y: labelY)
    }

    var body: some View {
        let bounds = scaledBounds
        let labelOrigin = chipOrigin

        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(borderColor, lineWidth: isMissingLabel ? 2 : 1)
                .frame(width: bounds.width, height: bounds.height, alignment: .topLeading)
                .offset(x: bounds.minX, y: bounds.minY)

            if !overlayText.isEmpty {
                Text(overlayText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(6)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(backgroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .frame(width: chipWidth, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: labelOrigin.x, y: labelOrigin.y)
            }
        }
        .frame(width: containerSize.width, height: containerSize.height, alignment: .topLeading)
    }
}
