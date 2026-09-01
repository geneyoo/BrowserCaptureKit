import Foundation

/// Export-time redaction. Raw observations remain available in memory so a host
/// can apply its own local policy; model-facing and persistent exports should
/// normally use ``safeForModel``.
public struct BrowserRedactionPolicy: Equatable, Sendable {
    public var replacement: String
    public var sensitiveHeaderNames: Set<String>
    public var redactsBodies: Bool
    public var redactsRequestMetadata: Bool
    public var redactsCookieValues: Bool
    public var redactsStorageValues: Bool
    public var redactsConsoleMessages: Bool

    public init(
        replacement: String = "[REDACTED]",
        sensitiveHeaderNames: Set<String> = [
            "authorization", "cookie", "proxy-authorization", "set-cookie", "x-api-key",
        ],
        redactsBodies: Bool = true,
        redactsRequestMetadata: Bool = true,
        redactsCookieValues: Bool = true,
        redactsStorageValues: Bool = true,
        redactsConsoleMessages: Bool = true
    ) {
        self.replacement = replacement
        self.sensitiveHeaderNames = Set(sensitiveHeaderNames.map { $0.lowercased() })
        self.redactsBodies = redactsBodies
        self.redactsRequestMetadata = redactsRequestMetadata
        self.redactsCookieValues = redactsCookieValues
        self.redactsStorageValues = redactsStorageValues
        self.redactsConsoleMessages = redactsConsoleMessages
    }

    public static let safeForModel = BrowserRedactionPolicy()
    public static let none = BrowserRedactionPolicy(
        sensitiveHeaderNames: [],
        redactsBodies: false,
        redactsRequestMetadata: false,
        redactsCookieValues: false,
        redactsStorageValues: false,
        redactsConsoleMessages: false
    )

    func redacted(headers: [String: String]) -> [String: String] {
        headers.mapValues { $0 }.reduce(into: [:]) { result, entry in
            result[entry.key] =
                sensitiveHeaderNames.contains(entry.key.lowercased())
                ? replacement
                : entry.value
        }
    }
}

extension BrowserCaptureEvent {
    public func redacted(using policy: BrowserRedactionPolicy = .safeForModel) -> BrowserCaptureEvent {
        switch self {
        case .browserState(let snapshot):
            .browserState(snapshot.redacted(using: policy))
        case .response(let response):
            .response(response.redacted(using: policy))
        case .nativeNetwork(let event):
            .nativeNetwork(event.redacted(using: policy))
        case .console(let event) where policy.redactsConsoleMessages:
            .console(
                BrowserConsoleEvent(
                    id: event.id,
                    capturedAt: event.capturedAt,
                    level: event.level,
                    message: policy.replacement
                )
            )
        default:
            self
        }
    }
}

extension BrowserStateSnapshot {
    public func redacted(using policy: BrowserRedactionPolicy = .safeForModel) -> BrowserStateSnapshot {
        let redactedDocumentCookie = documentCookie.map {
            policy.redactsCookieValues ? policy.replacement : $0
        }
        return BrowserStateSnapshot(
            id: id,
            capturedAt: capturedAt,
            reason: reason,
            url: url,
            title: title,
            userAgent: userAgent,
            documentCookie: redactedDocumentCookie,
            localStorage: localStorage.mapValues {
                policy.redactsStorageValues ? policy.replacement : $0
            },
            sessionStorage: sessionStorage.mapValues {
                policy.redactsStorageValues ? policy.replacement : $0
            },
            cookies: cookies.map { cookie in
                BrowserCookieSnapshot(
                    id: cookie.id,
                    name: cookie.name,
                    value: policy.redactsCookieValues ? policy.replacement : cookie.value,
                    domain: cookie.domain,
                    path: cookie.path,
                    expiresDate: cookie.expiresDate,
                    isSessionOnly: cookie.isSessionOnly,
                    isSecure: cookie.isSecure,
                    isHTTPOnly: cookie.isHTTPOnly
                )
            },
            websiteDataRecords: websiteDataRecords,
            javaScriptError: javaScriptError
        )
    }
}

extension CapturedResponse {
    public func redacted(using policy: BrowserRedactionPolicy = .safeForModel) -> CapturedResponse {
        CapturedResponse(
            id: id,
            capturedAt: capturedAt,
            source: source,
            direction: direction,
            frame: frame,
            method: method,
            url: url,
            status: status,
            statusText: statusText,
            contentType: contentType,
            requestHeaders: policy.redacted(headers: requestHeaders),
            requestMetadata: requestMetadata.mapValues {
                policy.redactsRequestMetadata ? policy.replacement : $0
            },
            requestBodyPreview: requestBodyPreview.map {
                policy.redactsBodies ? policy.replacement : $0
            },
            responseHeaders: policy.redacted(headers: responseHeaders),
            responseBodyPreview: responseBodyPreview.map {
                policy.redactsBodies ? policy.replacement : $0
            },
            responseBodyTruncated: responseBodyTruncated,
            durationMilliseconds: durationMilliseconds,
            errorDescription: errorDescription
        )
    }
}

extension BrowserNativeNetworkEvent {
    public func redacted(using policy: BrowserRedactionPolicy = .safeForModel)
        -> BrowserNativeNetworkEvent
    {
        BrowserNativeNetworkEvent(
            id: id,
            capturedAt: capturedAt,
            phase: phase,
            url: url,
            mainDocumentURL: mainDocumentURL,
            method: method,
            status: status,
            mimeType: mimeType,
            expectedContentLength: expectedContentLength,
            headers: policy.redacted(headers: headers),
            isForMainFrame: isForMainFrame,
            navigationType: navigationType,
            canShowMIMEType: canShowMIMEType
        )
    }
}
