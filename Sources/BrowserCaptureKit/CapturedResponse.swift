import Foundation

public struct CapturedResponse: Identifiable, Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case fetch
        case xhr
    }

    public let id: UUID
    public let capturedAt: Date
    public let source: Source
    public let method: String
    public let url: URL
    public let status: Int?
    public let statusText: String?
    public let contentType: String?
    public let requestHeaders: [String: String]
    public let requestMetadata: [String: String]
    public let requestBodyPreview: String?
    public let responseHeaders: [String: String]
    public let responseBodyPreview: String?
    public let responseBodyTruncated: Bool
    public let durationMilliseconds: Double?
    public let errorDescription: String?

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        source: Source,
        method: String,
        url: URL,
        status: Int? = nil,
        statusText: String? = nil,
        contentType: String? = nil,
        requestHeaders: [String: String] = [:],
        requestMetadata: [String: String] = [:],
        requestBodyPreview: String? = nil,
        responseHeaders: [String: String] = [:],
        responseBodyPreview: String? = nil,
        responseBodyTruncated: Bool = false,
        durationMilliseconds: Double? = nil,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.source = source
        self.method = method
        self.url = url
        self.status = status
        self.statusText = statusText
        self.contentType = contentType
        self.requestHeaders = requestHeaders
        self.requestMetadata = requestMetadata
        self.requestBodyPreview = requestBodyPreview
        self.responseHeaders = responseHeaders
        self.responseBodyPreview = responseBodyPreview
        self.responseBodyTruncated = responseBodyTruncated
        self.durationMilliseconds = durationMilliseconds
        self.errorDescription = errorDescription
    }
}
