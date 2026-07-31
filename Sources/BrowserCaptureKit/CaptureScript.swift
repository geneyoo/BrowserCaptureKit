import Foundation

// swiftlint:disable function_body_length type_body_length
enum CaptureScript {
    static let privilegedWebSocketReplayFunctionName = "__browserCaptureKitPrivilegedWebSocketReplay"

    static func source(
        configuration: BrowserCaptureConfiguration,
        messageHandlerName: String,
        bridgeToken: String
    ) -> String {
        let options: [String: Any] = [
            "messageHandlerName": messageHandlerName,
            "bridgeToken": bridgeToken,
            "capturesFetch": configuration.capturesFetch,
            "capturesXHR": configuration.capturesXHR,
            "capturesWebSocket": configuration.capturesWebSocket,
            "capturesConsole": configuration.capturesConsole,
            "maxBodyPreviewCharacters": configuration.maxBodyPreviewCharacters,
            "privilegedWebSocketReplayFunctionName": privilegedWebSocketReplayFunctionName,
            "webSocketAcknowledgementTimeoutMilliseconds": configuration
                .webSocketAckTimeoutMilliseconds,
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
                  const bridgeToken = String(options.bridgeToken || "");
                  delete options.bridgeToken;
                  const installKey = "__browserCaptureKitInstalled";
                  if (window[installKey]) {
                    return;
                  }
                  window[installKey] = true;

                  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[options.messageHandlerName];
                  const nativePostMessage = handler && typeof handler.postMessage === "function"
                    ? handler.postMessage.bind(handler)
                    : null;
                  const eventTargetAddEventListener = window.EventTarget && window.EventTarget.prototype
                    ? window.EventTarget.prototype.addEventListener
                    : null;
                  const nativeAddEventListener = typeof eventTargetAddEventListener === "function"
                    ? Function.prototype.call.bind(eventTargetAddEventListener)
                    : null;
                  const eventTargetRemoveEventListener = window.EventTarget && window.EventTarget.prototype
                    ? window.EventTarget.prototype.removeEventListener
                    : null;
                  const nativeRemoveEventListener = typeof eventTargetRemoveEventListener === "function"
                    ? Function.prototype.call.bind(eventTargetRemoveEventListener)
                    : null;
                  const NativeURL = window.URL;
                  const NativeNumber = window.Number;
                  const NativeString = window.String;
                  const nativeDefineProperty = Object.defineProperty;
                  const nativeArrayIsArray = Array.isArray.bind(Array);
                  const nativeNumberIsInteger = Number.isInteger.bind(Number);
                  const nativeJSONParse = JSON.parse.bind(JSON);
                  const nativeJSONStringify = JSON.stringify.bind(JSON);
                  const nativeStringToLowerCase = Function.prototype.call.bind(String.prototype.toLowerCase);
                  const nativeSetTimeout = window.setTimeout.bind(window);
                  const nativeClearTimeout = window.clearTimeout.bind(window);
                  const maxChars = Math.max(0, Number(options.maxBodyPreviewCharacters || 0));
                  const webSocketAcknowledgementTimeoutMilliseconds = Math.max(
                    100,
                    Math.min(30000, Number(options.webSocketAcknowledgementTimeoutMilliseconds || 10000))
                  );

                  function post(payload) {
                    try {
                      if (!nativePostMessage || !bridgeToken || !payload || typeof payload !== "object") {
                        return;
                      }
                      // Keep authentication entirely inside this document-start
                      // closure. Page code can call the public handler name, but
                      // cannot manufacture a payload accepted by native code.
                      payload.capturedAtEpochMS = Date.now();
                      payload.bridgeToken = bridgeToken;
                      nativePostMessage(payload);
                      delete payload.bridgeToken;
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

                  function normalizeHeaderMap(headers) {
                    const output = {};
                    if (!headers) {
                      return output;
                    }

                    try {
                      if (typeof Headers !== "undefined" && headers instanceof Headers && typeof headers.forEach === "function") {
                        headers.forEach((value, name) => {
                          output[String(name)] = String(value);
                        });
                        return output;
                      }

                      if (Array.isArray(headers)) {
                        headers.forEach((entry) => {
                          if (!entry || entry.length < 2) {
                            return;
                          }
                          output[String(entry[0])] = String(entry[1]);
                        });
                        return output;
                      }

                      if (typeof headers.entries === "function") {
                        for (const entry of headers.entries()) {
                          if (!entry || entry.length < 2) {
                            continue;
                          }
                          output[String(entry[0])] = String(entry[1]);
                        }
                        return output;
                      }

                      if (typeof headers === "object") {
                        Object.keys(headers).forEach((name) => {
                          output[String(name)] = String(headers[name]);
                        });
                      }
                    } catch (error) {
                      output.__captureError = String(error && error.message ? error.message : error);
                    }
                    return output;
                  }

                  function parseRawHeaderBlock(rawHeaders) {
                    const output = {};
                    String(rawHeaders || "").split(/\\r?\\n/).forEach((line) => {
                      const separator = line.indexOf(":");
                      if (separator <= 0) {
                        return;
                      }
                      const name = line.slice(0, separator).trim();
                      const value = line.slice(separator + 1).trim();
                      if (!name) {
                        return;
                      }
                      output[name] = output[name] ? `${output[name]}, ${value}` : value;
                    });
                    return output;
                  }

                  function metadataValue(value) {
                    if (value === undefined || value === null || value === "") {
                      return null;
                    }
                    return String(value);
                  }

                  function fetchRequestDetails(input, init) {
                    const request = typeof Request !== "undefined" && input instanceof Request ? input : null;
                    const headers = Object.assign(
                      {},
                      normalizeHeaderMap(request && request.headers),
                      normalizeHeaderMap(init && init.headers)
                    );
                    const metadata = {};
                    [
                      ["credentials", init && init.credentials || request && request.credentials],
                      ["mode", init && init.mode || request && request.mode],
                      ["cache", init && init.cache || request && request.cache],
                      ["redirect", init && init.redirect || request && request.redirect],
                      ["referrer", init && init.referrer || request && request.referrer],
                      ["referrerPolicy", init && init.referrerPolicy || request && request.referrerPolicy],
                      ["integrity", init && init.integrity || request && request.integrity],
                      ["keepalive", init && init.keepalive !== undefined ? init.keepalive : request && request.keepalive],
                      ["destination", request && request.destination]
                    ].forEach(([key, value]) => {
                      const normalized = metadataValue(value);
                      if (normalized !== null) {
                        metadata[key] = normalized;
                      }
                    });
                    return { headers, metadata };
                  }

                  async function readResponsePreview(response) {
                    const contentType = headerValue(response.headers, "content-type");
                    const responseHeaders = normalizeHeaderMap(response.headers);
                    if (!isPreviewableContentType(contentType)) {
                      return { contentType, responseHeaders, bodyPreview: null, truncated: false };
                    }

                    const clone = response.clone();
                    if (maxChars <= 0) {
                      return { contentType, responseHeaders, bodyPreview: null, truncated: false };
                    }

                    if (!clone.body || typeof clone.body.getReader !== "function" || typeof TextDecoder === "undefined") {
                      const text = await clone.text();
                      return {
                        contentType,
                        responseHeaders,
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
                        responseHeaders,
                        bodyPreview: text.length > maxChars ? text.slice(0, maxChars) : text,
                        truncated: true,
                        previewError: String(error && error.message ? error.message : error)
                      };
                    }

                    return {
                      contentType,
                      responseHeaders,
                      bodyPreview: text.length > maxChars ? text.slice(0, maxChars) : text,
                      truncated: truncated || text.length > maxChars
                    };
                  }

                  async function captureFetchResponse(input, init, response, startedAt) {
                    try {
                      const request = fetchRequestDetails(input, init);
                      const preview = await readResponsePreview(response);
                      post({
                        kind: "response",
                        source: "fetch",
                        method: coerceMethod(input, init),
                        url: response.url || coerceURL(input),
                        status: response.status,
                        statusText: response.statusText || null,
                        contentType: preview.contentType || null,
                        requestHeaders: request.headers,
                        requestMetadata: request.metadata,
                        requestBodyPreview: previewValue(init && init.body),
                        responseHeaders: preview.responseHeaders || {},
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
                          requestHeaders: fetchRequestDetails(input, init).headers,
                          requestMetadata: fetchRequestDetails(input, init).metadata,
                          requestBodyPreview: previewValue(init && init.body),
                          responseHeaders: {},
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
                    const originalSetRequestHeader = OriginalXHR.prototype.setRequestHeader;
                    const originalSend = OriginalXHR.prototype.send;

                    OriginalXHR.prototype.open = function browserCaptureOpen(method, url, async, username) {
                      this.__browserCapture = {
                        method: String(method || "GET").toUpperCase(),
                        url: coerceURL(url),
                        startedAt: null,
                        requestBodyPreview: null,
                        requestHeaders: {},
                        requestMetadata: {
                          async: metadataValue(async === undefined ? true : async) || "true",
                          usernameProvided: metadataValue(username !== undefined)
                        }
                      };
                      return originalOpen.apply(this, arguments);
                    };

                    OriginalXHR.prototype.setRequestHeader = function browserCaptureSetRequestHeader(name, value) {
                      const capture = this.__browserCapture || {
                        method: "GET",
                        url: "",
                        startedAt: null,
                        requestBodyPreview: null,
                        requestHeaders: {},
                        requestMetadata: {}
                      };
                      const headerName = String(name || "");
                      const headerValue = String(value || "");
                      if (headerName) {
                        capture.requestHeaders[headerName] = capture.requestHeaders[headerName]
                          ? `${capture.requestHeaders[headerName]}, ${headerValue}`
                          : headerValue;
                      }
                      this.__browserCapture = capture;
                      return originalSetRequestHeader.apply(this, arguments);
                    };

                    OriginalXHR.prototype.send = function browserCaptureSend(body) {
                      const capture = this.__browserCapture || {
                        method: "GET",
                        url: "",
                        startedAt: null,
                        requestBodyPreview: null,
                        requestHeaders: {},
                        requestMetadata: {}
                      };
                      capture.startedAt = now();
                      capture.requestBodyPreview = previewValue(body);
                      capture.requestMetadata = Object.assign({}, capture.requestMetadata || {}, {
                        withCredentials: String(Boolean(this.withCredentials)),
                        responseType: String(this.responseType || "")
                      });
                      this.__browserCapture = capture;

                      this.addEventListener("loadend", () => {
                        try {
                          const contentType = this.getResponseHeader("content-type");
                          const responseHeaders = parseRawHeaderBlock(this.getAllResponseHeaders());
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
                            requestHeaders: capture.requestHeaders || {},
                            requestMetadata: capture.requestMetadata || {},
                            requestBodyPreview: capture.requestBodyPreview,
                            responseHeaders,
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

                  function socketPreview(value) {
                    try {
                      if (value == null) {
                        return null;
                      }
                      if (typeof value === "string") {
                        return value.length > maxChars ? value.slice(0, maxChars) : value;
                      }
                      if (typeof Blob !== "undefined" && value instanceof Blob) {
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

                  function installWebSocketCapture() {
                    if (!options.capturesWebSocket || typeof window.WebSocket !== "function") {
                      return;
                    }

                    const OriginalWebSocket = window.WebSocket;
                    const trackedWebSockets = [];
                    const trackedWebSocketSet = new WeakSet();
                    const trackedWebSocketBindings = new WeakMap();
                    const nativeWeakSetAdd = Function.prototype.call.bind(WeakSet.prototype.add);
                    const nativeWeakSetHas = Function.prototype.call.bind(WeakSet.prototype.has);
                    const nativeWeakMapSet = Function.prototype.call.bind(WeakMap.prototype.set);
                    const nativeWeakMapGet = Function.prototype.call.bind(WeakMap.prototype.get);
                    const readyStateDescriptor = Object.getOwnPropertyDescriptor(
                      OriginalWebSocket.prototype,
                      "readyState"
                    );
                    const urlDescriptor = Object.getOwnPropertyDescriptor(
                      OriginalWebSocket.prototype,
                      "url"
                    );
                    const nativeReadyStateGet = readyStateDescriptor && typeof readyStateDescriptor.get === "function"
                      ? Function.prototype.call.bind(readyStateDescriptor.get)
                      : null;
                    const nativeWebSocketURLGet = urlDescriptor && typeof urlDescriptor.get === "function"
                      ? Function.prototype.call.bind(urlDescriptor.get)
                      : null;
                    const nativeWebSocketSend = typeof OriginalWebSocket.prototype.send === "function"
                      ? Function.prototype.call.bind(OriginalWebSocket.prototype.send)
                      : null;

                    function nativeSocketBinding(socket) {
                      try {
                        if (!nativeWebSocketURLGet || !NativeURL) {
                          return null;
                        }
                        const resolvedURL = nativeWebSocketURLGet(socket);
                        const parsed = new NativeURL(resolvedURL);
                        const host = nativeStringToLowerCase(NativeString(parsed.hostname || ""));
                        const path = NativeString(parsed.pathname || "/");
                        const port = parsed.port ? NativeNumber(parsed.port) : 443;
                        if (
                          parsed.protocol !== "wss:" ||
                          !host ||
                          !nativeNumberIsInteger(port) ||
                          port < 1 ||
                          port > 65535 ||
                          parsed.username ||
                          parsed.password
                        ) {
                          return null;
                        }
                        return { url: NativeString(resolvedURL), host, port, path };
                      } catch (_) {
                        return null;
                      }
                    }

                    async function privilegedWebSocketReplay(
                      presentedToken,
                      serializedFrame,
                      requestID,
                      expectedHost,
                      expectedPort,
                      expectedPath,
                      requiresExactBinding,
                      stampsRequestID
                    ) {
                      if (
                        presentedToken !== bridgeToken ||
                        !nativeReadyStateGet ||
                        !nativeWebSocketSend ||
                        !nativeAddEventListener ||
                        !nativeRemoveEventListener
                      ) {
                        return "unauthorized";
                      }

                      let openSocketCount = 0;
                      let socket = null;
                      let binding = null;
                      for (let index = trackedWebSockets.length - 1; index >= 0; index -= 1) {
                        const candidate = trackedWebSockets[index];
                        try {
                          if (
                            !candidate ||
                            !nativeWeakSetHas(trackedWebSocketSet, candidate) ||
                            nativeReadyStateGet(candidate) !== 1
                          ) {
                            continue;
                          }
                          openSocketCount += 1;
                          const candidateBinding = nativeWeakMapGet(trackedWebSocketBindings, candidate);
                          if (!candidateBinding) {
                            continue;
                          }
                          if (
                            requiresExactBinding &&
                            (
                              candidateBinding.host !== expectedHost ||
                              candidateBinding.port !== expectedPort ||
                              candidateBinding.path !== expectedPath
                            )
                          ) {
                            continue;
                          }
                          socket = candidate;
                          binding = candidateBinding;
                          break;
                        } catch (_) {}
                      }

                      if (!socket) {
                        return openSocketCount === 0 ? "noSocket" : "noTrustedSocket";
                      }

                      let settleAcknowledgement = null;
                      try {
                        let wirePayload = NativeString(serializedFrame || "");
                        let acknowledgement = null;
                        if (stampsRequestID) {
                          const frame = nativeJSONParse(wirePayload);
                          if (!frame || typeof frame !== "object" || nativeArrayIsArray(frame)) {
                            return "error:Replay frame was not an object.";
                          }
                          frame.id = NativeString(requestID || "");
                          wirePayload = nativeJSONStringify(frame);

                          // Register before native send so an immediate vendor
                          // response cannot race past the waiter. Only a trusted
                          // socket event with this freshly stamped reqId counts.
                          acknowledgement = new Promise((resolve) => {
                            let settled = false;
                            let timeoutID = null;
                            const finish = (status) => {
                              if (settled) return;
                              settled = true;
                              if (timeoutID != null) nativeClearTimeout(timeoutID);
                              try { nativeRemoveEventListener(socket, "message", onMessage); } catch (_) {}
                              try { nativeRemoveEventListener(socket, "close", onClose); } catch (_) {}
                              try { nativeRemoveEventListener(socket, "error", onError); } catch (_) {}
                              resolve(status);
                            };
                            const onMessage = (event) => {
                              if (!event || event.isTrusted !== true || typeof event.data !== "string") {
                                return;
                              }
                              try {
                                const response = nativeJSONParse(event.data);
                                if (
                                  !response ||
                                  response.type !== "ms.PublishEventResponse" ||
                                  response.reqId !== requestID
                                ) {
                                  return;
                                }
                                const code = NativeNumber(response.code);
                                if (nativeNumberIsInteger(code) && code >= 200 && code < 300) {
                                  finish("acknowledged");
                                } else if (
                                  nativeNumberIsInteger(code) &&
                                  code >= 400 && code < 500 &&
                                  code !== 408 && code !== 409 && code !== 425 && code !== 429
                                ) {
                                  finish("rejected:" + (nativeNumberIsInteger(code) ? code : "unknown"));
                                } else {
                                  finish(
                                    "acknowledgementPending:serverResponse:" +
                                    (nativeNumberIsInteger(code) ? code : "unknown")
                                  );
                                }
                              } catch (_) {}
                            };
                            const onClose = () => finish("acknowledgementPending:socketClosed");
                            const onError = () => finish("acknowledgementPending:socketError");
                            settleAcknowledgement = finish;
                            nativeAddEventListener(socket, "message", onMessage);
                            nativeAddEventListener(socket, "close", onClose);
                            nativeAddEventListener(socket, "error", onError);
                            timeoutID = nativeSetTimeout(
                              () => finish("acknowledgementTimedOut"),
                              webSocketAcknowledgementTimeoutMilliseconds
                            );
                          });
                        }
                        nativeWebSocketSend(socket, wirePayload);
                        post({
                          kind: "socket",
                          source: "websocket",
                          direction: "outbound",
                          url: binding.url,
                          bodyPreview: socketPreview(wirePayload)
                        });
                        return acknowledgement ? await acknowledgement : "sent";
                      } catch (error) {
                        if (settleAcknowledgement) {
                          settleAcknowledgement("error:send failed");
                        }
                        return "error:" + (error && error.message ? error.message : "send failed");
                      }
                    }

                    // Native replay reaches this authenticated, non-replaceable
                    // closure. Socket identity, native URL binding, ready state,
                    // and native send are all retained lexically from document
                    // start; page-owned globals cannot forge a successful send.
                    try {
                      nativeDefineProperty(
                        window,
                        options.privilegedWebSocketReplayFunctionName,
                        {
                          value: privilegedWebSocketReplay,
                          writable: false,
                          configurable: false,
                          enumerable: false
                        }
                      );
                    } catch (_) {}

                    function CapturingWebSocket(url, protocols) {
                      const socket = protocols === undefined
                        ? new OriginalWebSocket(url)
                        : new OriginalWebSocket(url, protocols);
                      const binding = nativeSocketBinding(socket);
                      const resolvedURL = binding ? binding.url : coerceURL(url);

                      // The registry never crosses this document-start closure.
                      // Production replay validates native socket identity and
                      // the URL captured from WebSocket.prototype.url, not any
                      // mutable page property or constructor argument.
                      trackedWebSockets[trackedWebSockets.length] = socket;
                      nativeWeakSetAdd(trackedWebSocketSet, socket);
                      if (binding) {
                        nativeWeakMapSet(trackedWebSocketBindings, socket, binding);
                      }

                      post({
                        kind: "socket",
                        source: "websocket",
                        direction: "open",
                        url: resolvedURL,
                        metadata: {
                          protocols: protocols == null ? null : String(protocols)
                        }
                      });

                      if (!nativeAddEventListener) {
                        return socket;
                      }

                      nativeAddEventListener(socket, "message", (event) => {
                        if (!event || event.isTrusted !== true) {
                          return;
                        }
                        post({
                          kind: "socket",
                          source: "websocket",
                          direction: "inbound",
                          url: resolvedURL,
                          bodyPreview: socketPreview(event && event.data)
                        });
                      });

                      nativeAddEventListener(socket, "close", (event) => {
                        post({
                          kind: "socket",
                          source: "websocket",
                          direction: "close",
                          url: resolvedURL,
                          metadata: {
                            code: event && event.code != null ? String(event.code) : null,
                            reason: event && event.reason ? String(event.reason) : null,
                            wasClean: event ? String(Boolean(event.wasClean)) : null
                          }
                        });
                      });

                      nativeAddEventListener(socket, "error", () => {
                        post({
                          kind: "socket",
                          source: "websocket",
                          direction: "error",
                          url: resolvedURL
                        });
                      });

                      socket.send = function browserCaptureSocketSend(data) {
                        post({
                          kind: "socket",
                          source: "websocket",
                          direction: "outbound",
                          url: resolvedURL,
                          bodyPreview: socketPreview(data)
                        });
                        return nativeWebSocketSend(this, data);
                      };

                      return socket;
                    }

                    CapturingWebSocket.prototype = OriginalWebSocket.prototype;
                    ["CONNECTING", "OPEN", "CLOSING", "CLOSED"].forEach((key) => {
                      try {
                        CapturingWebSocket[key] = OriginalWebSocket[key];
                      } catch (_) {}
                    });

                    try {
                      window.WebSocket = CapturingWebSocket;
                    } catch (_) {}
                  }

                  function installEventSourceCapture() {
                    if (!options.capturesWebSocket || typeof window.EventSource !== "function") {
                      return;
                    }

                    const OriginalEventSource = window.EventSource;

                    function CapturingEventSource(url, config) {
                      const source = config === undefined
                        ? new OriginalEventSource(url)
                        : new OriginalEventSource(url, config);
                      const resolvedURL = coerceURL(url);

                      post({
                        kind: "socket",
                        source: "eventsource",
                        direction: "open",
                        url: resolvedURL,
                        metadata: {
                          withCredentials: config && config.withCredentials ? "true" : "false"
                        }
                      });

                      if (!nativeAddEventListener) {
                        return source;
                      }

                      nativeAddEventListener(source, "message", (event) => {
                        if (!event || event.isTrusted !== true) {
                          return;
                        }
                        post({
                          kind: "socket",
                          source: "eventsource",
                          direction: "inbound",
                          url: resolvedURL,
                          bodyPreview: socketPreview(event && event.data)
                        });
                      });

                      return source;
                    }

                    CapturingEventSource.prototype = OriginalEventSource.prototype;
                    ["CONNECTING", "OPEN", "CLOSED"].forEach((key) => {
                      try {
                        CapturingEventSource[key] = OriginalEventSource[key];
                      } catch (_) {}
                    });

                    try {
                      window.EventSource = CapturingEventSource;
                    } catch (_) {}
                  }

                  function installBeaconCapture() {
                    if (!options.capturesWebSocket || !window.navigator || typeof window.navigator.sendBeacon !== "function") {
                      return;
                    }

                    const originalSendBeacon = window.navigator.sendBeacon.bind(window.navigator);
                    window.navigator.sendBeacon = function browserCaptureSendBeacon(url, data) {
                      post({
                        kind: "socket",
                        source: "beacon",
                        direction: "outbound",
                        url: coerceURL(url),
                        bodyPreview: socketPreview(data)
                      });
                      return originalSendBeacon(url, data);
                    };
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
                    installWebSocketCapture();
                    installEventSourceCapture();
                    installBeaconCapture();
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
// swiftlint:enable function_body_length type_body_length
