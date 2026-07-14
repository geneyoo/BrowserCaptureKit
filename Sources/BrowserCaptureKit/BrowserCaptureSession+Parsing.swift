import Foundation
import WebKit

/// Payload-parsing helpers for the session's JavaScript results (element/AX
/// decode and JSON value coercion). Extracted from `BrowserCaptureSession.swift`
/// purely for file-length reasons; behavior is unchanged.
@MainActor
extension BrowserCaptureSession {
    func accessibilityElement(from payload: [String: Any]) -> BrowserAccessibilityElementSnapshot? {
        guard let index = int(payload["index"]),
            let tagName = string(payload["tagName"])
        else {
            return nil
        }

        let boundsPayload = payload["bounds"] as? [String: Any]
        let bounds = BrowserElementBounds(
            x: double(boundsPayload?["x"]) ?? 0,
            y: double(boundsPayload?["y"]) ?? 0,
            width: double(boundsPayload?["width"]) ?? 0,
            height: double(boundsPayload?["height"]) ?? 0
        )

        return BrowserAccessibilityElementSnapshot(
            stableID: string(payload["stableID"]),
            index: index,
            tagName: tagName,
            role: string(payload["role"]),
            label: string(payload["label"]),
            labelSource: string(payload["labelSource"]),
            text: string(payload["text"]),
            value: string(payload["value"]),
            placeholder: string(payload["placeholder"]),
            href: string(payload["href"]),
            source: string(payload["source"]),
            inputType: string(payload["inputType"]),
            isVisible: bool(payload["isVisible"]) ?? false,
            isInteractive: bool(payload["isInteractive"]) ?? false,
            isDisabled: bool(payload["isDisabled"]) ?? false,
            isEditable: bool(payload["isEditable"]) ?? false,
            isObscuredAtCenter: bool(payload["isObscuredAtCenter"]) ?? false,
            ariaHidden: bool(payload["ariaHidden"]) ?? false,
            bounds: bounds,
            path: string(payload["path"]) ?? "",
            selectorFingerprint: string(payload["selectorFingerprint"]),
            supportedActions: (payload["supportedActions"] as? [String] ?? [])
                .compactMap(BrowserActionKind.init(rawValue:))
        )
    }

    func resolvedElement(from value: Any?) -> BrowserResolvedElement? {
        guard let payload = value as? [String: Any] else {
            return nil
        }

        let bounds: BrowserElementBounds?
        if let boundsPayload = payload["bounds"] as? [String: Any] {
            bounds = BrowserElementBounds(
                x: double(boundsPayload["x"]) ?? 0,
                y: double(boundsPayload["y"]) ?? 0,
                width: double(boundsPayload["width"]) ?? 0,
                height: double(boundsPayload["height"]) ?? 0
            )
        } else {
            bounds = nil
        }

        return BrowserResolvedElement(
            score: double(payload["score"]) ?? 0,
            index: int(payload["index"]),
            tagName: string(payload["tagName"]),
            role: string(payload["role"]),
            label: string(payload["label"]),
            text: string(payload["text"]),
            path: string(payload["path"]),
            selectorFingerprint: string(payload["selectorFingerprint"]),
            bounds: bounds,
            isVisible: bool(payload["isVisible"]) ?? false,
            isInteractive: bool(payload["isInteractive"]) ?? false,
            isDisabled: bool(payload["isDisabled"]) ?? false,
            isEditable: bool(payload["isEditable"]) ?? false,
            isObscuredAtCenter: bool(payload["isObscuredAtCenter"]) ?? false
        )
    }

    func stringDictionary(from value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else {
            return [:]
        }

        return dictionary.reduce(into: [:]) { result, entry in
            guard !(entry.value is NSNull) else {
                return
            }
            if let value = entry.value as? String {
                result[entry.key] = value
            } else {
                result[entry.key] = String(describing: entry.value)
            }
        }
    }

    func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let value = value as? String {
            return value.isEmpty ? nil : value
        }
        return String(describing: value)
    }

    func int(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let value = value as? Int {
            return value
        }
        if let value = value as? Double {
            return Int(value)
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        return nil
    }

    func double(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        return nil
    }

    func bool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        return nil
    }
}
