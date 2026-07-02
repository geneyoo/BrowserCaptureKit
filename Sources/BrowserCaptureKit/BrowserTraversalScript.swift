import Foundation

/// The single shared DOM-traversal module (`window.__bck`) that both the capture
/// (`BrowserAccessibilityScript`) and action (`BrowserActionScript`) scripts
/// prepend and delegate to for element identity.
///
/// `stableID` contract v1, defect #1: the two scripts previously walked the DOM
/// differently (capture: `body *` visible-ordinal; action: `document`+shadow raw
/// index), so the same element got different stableIDs and the +500 exact-match
/// never fired. Both now derive `stableID`/`index`/`fingerprint`/`path` from one
/// `__bck.begin().describe(el)`, so identity is reproducible by construction.
///
/// `begin()` builds the visible-ordinal map once (O(n)); `describe()` is O(1).
enum BrowserTraversalScript {
    static let shared = """
        window.__bck = window.__bck || (function () {
          "use strict";

          function compact(value) { return String(value == null ? "" : value).replace(/\\s+/g, " ").trim(); }
          function normalized(value) { return compact(value).toLocaleLowerCase(); }
          function nullable(value) { const t = compact(value); return t ? t : null; }

          function implicitRole(element) {
            const tag = element.tagName.toLowerCase();
            const type = String(element.getAttribute("type") || "").toLowerCase();
            if (tag === "a" && element.hasAttribute("href")) return "link";
            if (tag === "button") return "button";
            if (tag === "select") return "combobox";
            if (tag === "textarea") return "textbox";
            if (tag === "img") return "img";
            if (tag === "video") return "video";
            if (tag === "input") {
              if (type === "checkbox") return "checkbox";
              if (type === "radio") return "radio";
              if (type === "range") return "slider";
              if (type === "submit" || type === "button" || type === "reset") return "button";
              return "textbox";
            }
            if (/^h[1-6]$/.test(tag)) return "heading";
            if (tag === "nav") return "navigation";
            if (tag === "main") return "main";
            if (tag === "article") return "article";
            if (tag === "section") return "section";
            if (tag === "form") return "form";
            return nullable(element.getAttribute("role"));
          }

          function roleFor(element) { return nullable(element.getAttribute("role")) || implicitRole(element); }

          function labelFor(element, role) {
            const aria = compact(element.getAttribute("aria-label"));
            if (aria) return aria;
            if (element.tagName.toLowerCase() === "img") {
              const alt = compact(element.getAttribute("alt"));
              if (alt) return alt;
            }
            const title = compact(element.getAttribute("title"));
            if (title) return title;
            const placeholder = compact(element.getAttribute("placeholder"));
            if (placeholder) return placeholder;
            const value = compact(element.value);
            if ((role === "button" || element.tagName.toLowerCase() === "input") && value) return value;
            return compact(element.innerText || element.textContent || "");
          }

          function pathFor(element) {
            const parts = [];
            let node = element;
            while (node && node.nodeType === Node.ELEMENT_NODE && node !== document.body && parts.length < 8) {
              let part = node.tagName.toLowerCase();
              if (node.id) {
                part += "#" + CSS.escape(node.id);
                parts.unshift(part);
                break;
              }
              const parent = node.parentElement;
              if (parent) {
                const siblings = Array.from(parent.children).filter((child) => child.tagName === node.tagName);
                if (siblings.length > 1) {
                  part += ":nth-of-type(" + (siblings.indexOf(node) + 1) + ")";
                }
              }
              parts.unshift(part);
              node = parent;
            }
            return "body" + (parts.length ? " > " + parts.join(" > ") : "");
          }

          function currentViewport() {
            if (window.visualViewport) {
              return {
                offsetLeft: window.visualViewport.offsetLeft || 0,
                offsetTop: window.visualViewport.offsetTop || 0,
                width: window.visualViewport.width || window.innerWidth,
                height: window.visualViewport.height || window.innerHeight
              };
            }
            return { offsetLeft: 0, offsetTop: 0, width: window.innerWidth, height: window.innerHeight };
          }

          function rectFor(element, viewport) {
            const rect = element.getBoundingClientRect();
            return {
              width: rect.width,
              height: rect.height,
              top: rect.top - viewport.offsetTop,
              right: rect.right - viewport.offsetLeft,
              bottom: rect.bottom - viewport.offsetTop,
              left: rect.left - viewport.offsetLeft
            };
          }

          function visible(element, viewport) {
            const rect = rectFor(element, viewport);
            if (rect.width <= 0 || rect.height <= 0) return false;
            const style = window.getComputedStyle(element);
            return style.display !== "none" &&
              style.visibility !== "hidden" &&
              style.visibility !== "collapse" &&
              Number(style.opacity || "1") > 0 &&
              rect.bottom >= 0 &&
              rect.right >= 0 &&
              rect.top <= viewport.height &&
              rect.left <= viewport.width;
          }

          function fingerprintFor(element, viewport) {
            const role = roleFor(element);
            const label = labelFor(element, role);
            const rect = rectFor(element, viewport);
            return [
              element.tagName.toLowerCase(),
              role || "",
              normalized(label || ""),
              nullable(element.getAttribute("href")) || nullable(element.href) || "",
              pathFor(element) || "",
              Math.round(rect.width || 0) + "x" + Math.round(rect.height || 0)
            ].join("|");
          }

          function allElements() {
            const out = [];
            const visit = (root) => {
              for (const element of root.querySelectorAll("*")) {
                out.push(element);
                if (element.shadowRoot) { visit(element.shadowRoot); }
              }
            };
            visit(document);
            return out;
          }

          function begin() {
            const viewport = currentViewport();
            const order = allElements();
            const ordinal = new WeakMap();
            let counter = 0;
            for (const element of order) {
              if (visible(element, viewport)) {
                ordinal.set(element, counter);
                counter += 1;
              }
            }
            return {
              order: order,
              visibleCount: counter,
              describe(element) {
                const index = ordinal.has(element) ? ordinal.get(element) : -1;
                const fingerprint = fingerprintFor(element, viewport);
                return {
                  index: index,
                  fingerprint: fingerprint,
                  path: pathFor(element),
                  role: roleFor(element),
                  stableID: String(index) + ":" + fingerprint
                };
              }
            };
          }

          return { begin: begin, allElements: allElements, roleFor: roleFor, labelFor: labelFor, pathFor: pathFor, fingerprintFor: fingerprintFor };
        })();
        """
}
