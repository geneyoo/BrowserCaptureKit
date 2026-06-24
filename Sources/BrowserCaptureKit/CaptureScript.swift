import Foundation

// swiftlint:disable function_body_length
enum CaptureScript {
    static func source(configuration: BrowserCaptureConfiguration, messageHandlerName: String) -> String {
        let options: [String: Any] = [
            "messageHandlerName": messageHandlerName,
            "capturesFetch": configuration.capturesFetch,
            "capturesXHR": configuration.capturesXHR,
            "capturesConsole": configuration.capturesConsole,
            "maxBodyPreviewCharacters": configuration.maxBodyPreviewCharacters,
        ]

        let optionsJSON: String
        if JSONSerialization.isValidJSONObject(options),
            let optionsData = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]),
            let encodedOptions = String(data: optionsData, encoding: .utf8)
        {
            optionsJSON = encodedOptions
        } else {
            optionsJSON = "{}"
        }

        return """
                (() => {
                  "use strict";
                  const options = \(optionsJSON);
                  const installKey = "__browserCaptureKitInstalled";
                  if (window[installKey]) {
                    return;
                  }
                  window[installKey] = true;

                  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[options.messageHandlerName];
                  const maxChars = Math.max(0, Number(options.maxBodyPreviewCharacters || 0));

                  function post(payload) {
                    try {
                      if (!handler || typeof handler.postMessage !== "function") {
                        return;
                      }
                      handler.postMessage(Object.assign({ capturedAtEpochMS: Date.now() }, payload));
                    } catch (_) {}
                  }

                  function now() {
                    if (window.performance && typeof window.performance.now === "function") {
                      return window.performance.now();
                    }
                    return Date.now();
                  }

                  function coerceURL(input) {
                    try {
                      if (typeof input === "string") {
                        return input;
                      }
                      if (input && typeof input.url === "string") {
                        return input.url;
                      }
                      return String(input);
                    } catch (_) {
                      return "";
                    }
                  }

                  function coerceMethod(input, init) {
                    const method = (init && init.method) || (input && input.method) || "GET";
                    return String(method).toUpperCase();
                  }

                  function previewValue(value) {
                    try {
                      if (value == null) {
                        return null;
                      }
                      if (typeof value === "string") {
                        return value.length > maxChars ? value.slice(0, maxChars) : value;
                      }
                      if (value instanceof URLSearchParams) {
                        const text = value.toString();
                        return text.length > maxChars ? text.slice(0, maxChars) : text;
                      }
                      if (value instanceof FormData) {
                        return "[FormData]";
                      }
                      if (value instanceof Blob) {
                        return `[Blob type=${value.type || "unknown"} size=${value.size}]`;
                      }
                      if (value instanceof ArrayBuffer) {
                        return `[ArrayBuffer byteLength=${value.byteLength}]`;
                      }
                      if (ArrayBuffer.isView(value)) {
                        return `[TypedArray byteLength=${value.byteLength}]`;
                      }
                      const text = String(value);
                      return text.length > maxChars ? text.slice(0, maxChars) : text;
                    } catch (_) {
                      return "[unavailable]";
                    }
                  }

                  function isPreviewableContentType(contentType) {
                    const normalized = String(contentType || "").toLowerCase();
                    if (!normalized) {
                      return true;
                    }
                    return normalized.includes("json") ||
                      normalized.includes("graphql") ||
                      normalized.includes("text/") ||
                      normalized.includes("application/javascript") ||
                      normalized.includes("application/x-www-form-urlencoded") ||
                      normalized.includes("application/xml") ||
                      normalized.includes("application/problem");
                  }

                  function headerValue(headers, name) {
                    try {
                      return headers && typeof headers.get === "function" ? headers.get(name) : null;
                    } catch (_) {
                      return null;
                    }
                  }

                  async function readResponsePreview(response) {
                    const contentType = headerValue(response.headers, "content-type");
                    if (!isPreviewableContentType(contentType)) {
                      return { contentType, bodyPreview: null, truncated: false };
                    }

                    const clone = response.clone();
                    if (maxChars <= 0) {
                      return { contentType, bodyPreview: null, truncated: false };
                    }

                    if (!clone.body || typeof clone.body.getReader !== "function" || typeof TextDecoder === "undefined") {
                      const text = await clone.text();
                      return {
                        contentType,
                        bodyPreview: text.length > maxChars ? text.slice(0, maxChars) : text,
                        truncated: text.length > maxChars
                      };
                    }

                    const reader = clone.body.getReader();
                    const decoder = new TextDecoder();
                    let text = "";
                    let truncated = false;

                    try {
                      while (text.length < maxChars) {
                        const result = await reader.read();
                        if (result.done) {
                          break;
                        }
                        text += decoder.decode(result.value, { stream: true });
                        if (text.length >= maxChars) {
                          truncated = true;
                          try { await reader.cancel(); } catch (_) {}
                          break;
                        }
                      }
                      text += decoder.decode();
                    } catch (error) {
                      return {
                        contentType,
                        bodyPreview: text.length > maxChars ? text.slice(0, maxChars) : text,
                        truncated: true,
                        previewError: String(error && error.message ? error.message : error)
                      };
                    }

                    return {
                      contentType,
                      bodyPreview: text.length > maxChars ? text.slice(0, maxChars) : text,
                      truncated: truncated || text.length > maxChars
                    };
                  }

                  async function captureFetchResponse(input, init, response, startedAt) {
                    try {
                      const preview = await readResponsePreview(response);
                      post({
                        kind: "response",
                        source: "fetch",
                        method: coerceMethod(input, init),
                        url: response.url || coerceURL(input),
                        status: response.status,
                        statusText: response.statusText || null,
                        contentType: preview.contentType || null,
                        requestBodyPreview: previewValue(init && init.body),
                        responseBodyPreview: preview.bodyPreview,
                        responseBodyTruncated: Boolean(preview.truncated),
                        durationMilliseconds: now() - startedAt,
                        errorDescription: preview.previewError || null
                      });
                    } catch (error) {
                      post({
                        kind: "scriptError",
                        message: `fetch capture failed: ${String(error && error.message ? error.message : error)}`,
                        url: coerceURL(input)
                      });
                    }
                  }

                  function installFetchCapture() {
                    if (!options.capturesFetch || typeof window.fetch !== "function") {
                      return;
                    }

                    const originalFetch = window.fetch;
                    window.fetch = function browserCaptureFetch(input, init) {
                      const startedAt = now();
                      return originalFetch.apply(this, arguments).then((response) => {
                        captureFetchResponse(input, init, response.clone ? response : response, startedAt);
                        return response;
                      }, (error) => {
                        post({
                          kind: "response",
                          source: "fetch",
                          method: coerceMethod(input, init),
                          url: coerceURL(input),
                          requestBodyPreview: previewValue(init && init.body),
                          responseBodyTruncated: false,
                          durationMilliseconds: now() - startedAt,
                          errorDescription: String(error && error.message ? error.message : error)
                        });
                        throw error;
                      });
                    };
                  }

                  function installXHRCapture() {
                    if (!options.capturesXHR || typeof window.XMLHttpRequest !== "function") {
                      return;
                    }

                    const OriginalXHR = window.XMLHttpRequest;
                    const originalOpen = OriginalXHR.prototype.open;
                    const originalSend = OriginalXHR.prototype.send;

                    OriginalXHR.prototype.open = function browserCaptureOpen(method, url) {
                      this.__browserCapture = {
                        method: String(method || "GET").toUpperCase(),
                        url: coerceURL(url),
                        startedAt: null,
                        requestBodyPreview: null
                      };
                      return originalOpen.apply(this, arguments);
                    };

                    OriginalXHR.prototype.send = function browserCaptureSend(body) {
                      const capture = this.__browserCapture || {
                        method: "GET",
                        url: "",
                        startedAt: null,
                        requestBodyPreview: null
                      };
                      capture.startedAt = now();
                      capture.requestBodyPreview = previewValue(body);
                      this.__browserCapture = capture;

                      this.addEventListener("loadend", () => {
                        try {
                          const contentType = this.getResponseHeader("content-type");
                          let responseBodyPreview = null;
                          let responseBodyTruncated = false;

                          if (isPreviewableContentType(contentType) && (this.responseType === "" || this.responseType === "text")) {
                            const responseText = this.responseText || "";
                            responseBodyPreview = responseText.length > maxChars ? responseText.slice(0, maxChars) : responseText;
                            responseBodyTruncated = responseText.length > maxChars;
                          }

                          post({
                            kind: "response",
                            source: "xhr",
                            method: capture.method,
                            url: this.responseURL || capture.url,
                            status: this.status || null,
                            statusText: this.statusText || null,
                            contentType: contentType || null,
                            requestBodyPreview: capture.requestBodyPreview,
                            responseBodyPreview,
                            responseBodyTruncated,
                            durationMilliseconds: capture.startedAt == null ? null : now() - capture.startedAt,
                            errorDescription: null
                          });
                        } catch (error) {
                          post({
                            kind: "scriptError",
                            message: `XHR capture failed: ${String(error && error.message ? error.message : error)}`,
                            url: capture.url
                          });
                        }
                      });

                      return originalSend.apply(this, arguments);
                    };
                  }

                  function installConsoleCapture() {
                    if (!options.capturesConsole || !window.console) {
                      return;
                    }

                    ["log", "warn", "error"].forEach((level) => {
                      const original = window.console[level];
                      if (typeof original !== "function") {
                        return;
                      }
                      window.console[level] = function browserCaptureConsole() {
                        try {
                          const message = Array.from(arguments).map((item) => {
                            try {
                              if (typeof item === "string") {
                                return item;
                              }
                              return JSON.stringify(item);
                            } catch (_) {
                              return String(item);
                            }
                          }).join(" ");
                          post({ kind: "console", level, message });
                        } catch (_) {}
                        return original.apply(this, arguments);
                      };
                    });
                  }

                  function installViewportCapture() {
                    if (window !== window.top || typeof window.addEventListener !== "function") {
                      return;
                    }

                    let timeout = null;
                    const schedule = (reason) => {
                      if (timeout !== null) {
                        clearTimeout(timeout);
                      }
                      timeout = setTimeout(() => {
                        timeout = null;
                        post({
                          kind: "viewportChanged",
                          reason,
                          url: String(window.location && window.location.href || ""),
                          title: String(document.title || "")
                        });
                      }, 180);
                    };

                    window.addEventListener("scroll", () => schedule("scroll"), { passive: true });
                    window.addEventListener("resize", () => schedule("resize"));
                    if (window.visualViewport) {
                      window.visualViewport.addEventListener("scroll", () => schedule("visualViewportScroll"), { passive: true });
                      window.visualViewport.addEventListener("resize", () => schedule("visualViewportResize"));
                    }
                  }

                  try {
                    installFetchCapture();
                    installXHRCapture();
                    installConsoleCapture();
                    installViewportCapture();
                    post({ kind: "console", level: "debug", message: "BrowserCaptureKit installed" });
                  } catch (error) {
                    post({
                      kind: "scriptError",
                      message: `capture install failed: ${String(error && error.message ? error.message : error)}`,
                      url: String(window.location && window.location.href || "")
                    });
                  }
                })();
            """
    }
}
// swiftlint:enable function_body_length
