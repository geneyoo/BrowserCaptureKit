import Foundation

enum BrowserActionScript {
    static func tapSource(target: BrowserElementTarget) -> String {
        actionSource(action: "tap", target: target)
    }

    static func fillSource(target: BrowserElementTarget, text: String, submit: Bool) -> String {
        actionSource(action: "fill", target: target, text: text, submit: submit)
    }

    static func clearSource(target: BrowserElementTarget) -> String {
        actionSource(action: "clear", target: target)
    }

    static func pressEnterSource(target: BrowserElementTarget?) -> String {
        actionSource(action: "pressEnter", target: target)
    }

    static func waitForElementSource(target: BrowserElementTarget) -> String {
        actionSource(action: "resolve", target: target)
    }

    static func clickElementSource(label: String, role: String?) -> String {
        tapSource(target: .label(label, role: role))
    }

    private static func actionSource(
        action: String,
        target: BrowserElementTarget?,
        text: String? = nil,
        submit: Bool = false
    ) -> String {
        let header = """
            (() => {
              const __walk = window.__bck.begin();
              const action = \(javaScriptStringLiteral(action));
              const target = \(javaScriptLiteral(target));
              const fillText = \(javaScriptNullableStringLiteral(text));
              const shouldSubmit = \(submit ? "true" : "false");
              const maxCandidates = 8;
            """
        return BrowserTraversalScript.shared + "\n" + header + "\n\n" + Self.actionProgramSource + "\n})();"
    }

    private static func javaScriptLiteral(_ value: BrowserElementTarget?) -> String {
        guard let value else {
            return "null"
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
            let text = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        return text
    }

    private static func javaScriptNullableStringLiteral(_ value: String?) -> String {
        guard let value else {
            return "null"
        }
        return javaScriptStringLiteral(value)
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let text = String(data: data, encoding: .utf8),
            text.hasPrefix("["),
            text.hasSuffix("]")
        else {
            return "\"\""
        }

        return String(text.dropFirst().dropLast())
    }
}
