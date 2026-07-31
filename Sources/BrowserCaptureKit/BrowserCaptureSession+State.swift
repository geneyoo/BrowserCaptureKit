import Foundation
import WebKit

/// Browser storage and document-state capture kept separate from action dispatch.
@MainActor
extension BrowserCaptureSession {
    func makeBrowserStateSnapshot(reason: String) async -> BrowserStateSnapshot {
        guard let webView else {
            return BrowserStateSnapshot(
                reason: reason,
                url: nil,
                title: nil,
                userAgent: nil,
                documentCookie: nil,
                localStorage: [:],
                sessionStorage: [:],
                cookies: [],
                websiteDataRecords: [],
                javaScriptError: "No WKWebView is attached."
            )
        }

        async let nativeCookies = cookies(from: webView.configuration.websiteDataStore.httpCookieStore)
        async let websiteRecords = websiteDataRecords(from: webView.configuration.websiteDataStore)
        async let javaScriptState = pageState(from: webView)
        let (cookies, records, state) = await (nativeCookies, websiteRecords, javaScriptState)

        return BrowserStateSnapshot(
            reason: reason,
            url: webView.url,
            title: webView.title,
            userAgent: state.userAgent,
            documentCookie: state.documentCookie,
            localStorage: state.localStorage,
            sessionStorage: state.sessionStorage,
            cookies: cookies,
            websiteDataRecords: records,
            javaScriptError: state.error
        )
    }

    private func cookies(from cookieStore: WKHTTPCookieStore) async -> [BrowserCookieSnapshot] {
        let cookies = await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }

        return
            cookies
            .sorted { lhs, rhs in
                if lhs.domain == rhs.domain {
                    return lhs.name < rhs.name
                }
                return lhs.domain < rhs.domain
            }
            .map { cookie in
                BrowserCookieSnapshot(
                    name: cookie.name,
                    value: cookie.value,
                    domain: cookie.domain,
                    path: cookie.path,
                    expiresDate: cookie.expiresDate,
                    isSessionOnly: cookie.isSessionOnly,
                    isSecure: cookie.isSecure,
                    isHTTPOnly: cookie.isHTTPOnly
                )
            }
    }

    private func websiteDataRecords(from dataStore: WKWebsiteDataStore) async -> [BrowserWebsiteDataRecordSnapshot] {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await withCheckedContinuation { continuation in
            dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
                continuation.resume(returning: records)
            }
        }

        return
            records
            .sorted { lhs, rhs in
                lhs.displayName < rhs.displayName
            }
            .map { record in
                BrowserWebsiteDataRecordSnapshot(
                    displayName: record.displayName,
                    dataTypes: Array(record.dataTypes).sorted()
                )
            }
    }

    private func pageState(from webView: WKWebView) async -> BrowserPageState {
        let script = """
            (() => {
              const readStorage = (storage) => {
                const values = {};
                if (!storage) {
                  return values;
                }
                for (let index = 0; index < storage.length; index += 1) {
                  const key = storage.key(index);
                  if (key !== null) {
                    values[key] = storage.getItem(key);
                  }
                }
                return values;
              };

              const safe = (read) => {
                try {
                  return { value: read(), error: null };
                } catch (error) {
                  return { value: null, error: String(error && error.message ? error.message : error) };
                }
              };

              const cookie = safe(() => document.cookie);
              const local = safe(() => readStorage(window.localStorage));
              const session = safe(() => readStorage(window.sessionStorage));
              return {
                url: window.location.href,
                title: document.title,
                userAgent: navigator.userAgent,
                documentCookie: cookie.value,
                localStorage: local.value || {},
                sessionStorage: session.value || {},
                errors: {
                  documentCookie: cookie.error,
                  localStorage: local.error,
                  sessionStorage: session.error
                }
              };
            })();
            """

        do {
            let result = try await webView.evaluateJavaScript(script)
            guard let payload = result as? [String: Any] else {
                return BrowserPageState(error: "Browser state script returned a non-object result.")
            }

            let errors = payload["errors"] as? [String: Any]
            let errorText = errors?
                .compactMap { key, value -> String? in
                    guard !(value is NSNull), let value = value as? String, !value.isEmpty else {
                        return nil
                    }
                    return "\(key): \(value)"
                }
                .sorted()
                .joined(separator: "; ")

            return BrowserPageState(
                userAgent: payload["userAgent"] as? String,
                documentCookie: payload["documentCookie"] as? String,
                localStorage: stringDictionary(from: payload["localStorage"]),
                sessionStorage: stringDictionary(from: payload["sessionStorage"]),
                error: errorText?.isEmpty == false ? errorText : nil
            )
        } catch {
            return BrowserPageState(error: error.localizedDescription)
        }
    }
}

private struct BrowserPageState {
    var userAgent: String?
    var documentCookie: String?
    var localStorage: [String: String] = [:]
    var sessionStorage: [String: String] = [:]
    var error: String?
}
