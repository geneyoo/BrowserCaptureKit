import Foundation
import WebKit

@MainActor
final class ScriptMessageBridge: NSObject, WKScriptMessageHandler {
    var onEvent: ((BrowserCaptureEvent) -> Void)?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else {
            onEvent?(.scriptError(BrowserScriptError(message: "Received non-object script message.")))
            return
        }

        let capturedAt = date(from: body["capturedAtEpochMS"])

        switch body["kind"] as? String {
        case "response":
            handleResponse(body: body, capturedAt: capturedAt)
        case "console":
            handleConsole(body: body, capturedAt: capturedAt)
        case "scriptError":
            handleScriptError(body: body, capturedAt: capturedAt)
        default:
            onEvent?(.scriptError(BrowserScriptError(capturedAt: capturedAt, message: "Received unknown script message kind.")))
        }
    }

    private func handleResponse(body: [String: Any], capturedAt: Date) {
        guard
            let rawSource = body["source"] as? String,
            let source = CapturedResponse.Source(rawValue: rawSource),
            let rawURL = body["url"] as? String,
            let url = URL(string: rawURL)
        else {
            onEvent?(.scriptError(BrowserScriptError(capturedAt: capturedAt, message: "Received malformed response event.")))
            return
        }

        let response = CapturedResponse(
            capturedAt: capturedAt,
            source: source,
            method: string(body["method"]) ?? "GET",
            url: url,
            status: int(body["status"]),
            statusText: string(body["statusText"]),
            contentType: string(body["contentType"]),
            requestBodyPreview: string(body["requestBodyPreview"]),
            responseBodyPreview: string(body["responseBodyPreview"]),
            responseBodyTruncated: bool(body["responseBodyTruncated"]) ?? false,
            durationMilliseconds: double(body["durationMilliseconds"]),
            errorDescription: string(body["errorDescription"])
        )
        onEvent?(.response(response))
    }

    private func handleConsole(body: [String: Any], capturedAt: Date) {
        let event = BrowserConsoleEvent(
            capturedAt: capturedAt,
            level: string(body["level"]) ?? "log",
            message: string(body["message"]) ?? ""
        )
        onEvent?(.console(event))
    }

    private func handleScriptError(body: [String: Any], capturedAt: Date) {
        let error = BrowserScriptError(
            capturedAt: capturedAt,
            message: string(body["message"]) ?? "Unknown capture script error.",
            url: string(body["url"]).flatMap(URL.init(string:))
        )
        onEvent?(.scriptError(error))
    }

    private func date(from value: Any?) -> Date {
        guard let milliseconds = double(value) else {
            return Date()
        }
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }

    private func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else {
            return nil
        }
        if let value = value as? String {
            return value
        }
        return String(describing: value)
    }

    private func int(_ value: Any?) -> Int? {
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

    private func double(_ value: Any?) -> Double? {
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

    private func bool(_ value: Any?) -> Bool? {
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
