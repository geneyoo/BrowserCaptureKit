import Foundation

/// Export boundary helpers. Everything leaving the phone passes through here
/// so the relay only ever receives export-approved values.
enum ExportSanitizer {
    static let maxMessageCharacters = 240

    /// Keeps scheme, host, port, and path. Drops user info, query, and
    /// fragment, which routinely carry tokens and personal data.
    static func url(_ url: URL?) -> String? {
        guard let url else {
            return nil
        }
        if url.scheme == "about" {
            return url.absoluteString
        }
        if url.scheme == "data" || url.scheme == "blob" {
            return "\(url.scheme ?? "data"):"
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.scheme.map { "\($0):" }
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string
    }

    static func url(_ string: String?) -> String? {
        guard let string else {
            return nil
        }
        return url(URL(string: string)) ?? URL(string: string)?.scheme.map { "\($0):" }
    }

    /// Bounds free text that originated in page content or error descriptions.
    static func bounded(_ text: String?, limit: Int = maxMessageCharacters) -> (text: String?, truncated: Bool) {
        guard let text else {
            return (nil, false)
        }
        let compact = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compact.count > limit else {
            return (compact.isEmpty ? nil : compact, false)
        }
        return (String(compact.prefix(limit)), true)
    }
}
