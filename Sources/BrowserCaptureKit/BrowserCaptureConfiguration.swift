import Foundation

public struct BrowserCaptureConfiguration: Equatable, Sendable {
    public static let defaultInitialURL: URL = {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.instagram.com"
        return components.url ?? URL(fileURLWithPath: "/")
    }()

    public static let defaultPersistentStoreIdentifier = UUID(uuidString: "B2D41C04-19E7-4FA5-986A-F6D3B9115E5D") ?? UUID()

    public enum StorageMode: Equatable, Sendable {
        case nonPersistent
        case persistent(identifier: UUID)
    }

    public var initialURL: URL
    public var storageMode: StorageMode
    public var capturesFetch: Bool
    public var capturesXHR: Bool
    public var capturesConsole: Bool
    public var maxBodyPreviewCharacters: Int

    public init(
        initialURL: URL = BrowserCaptureConfiguration.defaultInitialURL,
        storageMode: StorageMode = .persistent(identifier: BrowserCaptureConfiguration.defaultPersistentStoreIdentifier),
        capturesFetch: Bool = true,
        capturesXHR: Bool = true,
        capturesConsole: Bool = false,
        maxBodyPreviewCharacters: Int = 24_000
    ) {
        self.initialURL = initialURL
        self.storageMode = storageMode
        self.capturesFetch = capturesFetch
        self.capturesXHR = capturesXHR
        self.capturesConsole = capturesConsole
        self.maxBodyPreviewCharacters = max(0, maxBodyPreviewCharacters)
    }
}
