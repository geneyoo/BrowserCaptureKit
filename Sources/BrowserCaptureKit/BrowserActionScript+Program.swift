extension BrowserActionScript {
    /// The invariant JavaScript program implementing every scripted browser
    /// action (`tap`, `fill`, `clear`, `pressEnter`, `resolve`).
    ///
    /// `actionSource(action:target:text:submit:)` in `BrowserActionScript.swift`
    /// prepends the per-invocation parameter constants and appends the closing
    /// `})();`, so this constant is pure, parameter-free JavaScript. It lives in
    /// its own file because its length is the embedded JS program, not Swift
    /// logic.
    static let actionProgramSource = """
          function compact(value) {
            return String(value || "").replace(/\\s+/g, " ").trim();
          }

          function normalized(value) {
            return compact(value).toLocaleLowerCase();
          }

          function nullable(value) {
            const text = compact(value);
            return text ? text : null;
          }

          function textFromIDREFS(value) {
            return compact(String(value || "").split(/\\s+/).map((id) => {
              try {
                return document.getElementById(id)?.textContent || "";
              } catch (_) {
                return "";
              }
            }).join(" "));
          }

          function labelForInput(element) {
            const labels = [];
            if (element.id) {
              document.querySelectorAll("label[for]").forEach((label) => {
                if (label.getAttribute("for") === element.id) {
                  labels.push(label.textContent || "");
                }
              });
            }
            const wrappingLabel = element.closest && element.closest("label");
            if (wrappingLabel) {
              labels.push(wrappingLabel.textContent || "");
            }
            return compact(labels.join(" "));
          }

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

          function roleFor(element) {
            return nullable(element.getAttribute("role")) || implicitRole(element);
          }

          function labelFor(element, role) {
            const ariaLabel = compact(element.getAttribute("aria-label"));
            if (ariaLabel) return ariaLabel;

            const labelledBy = textFromIDREFS(element.getAttribute("aria-labelledby"));
            if (labelledBy) return labelledBy;

            if (element.tagName.toLowerCase() === "img") {
              const alt = compact(element.getAttribute("alt"));
              if (alt) return alt;
            }

            const formLabel = labelForInput(element);
            if (formLabel) return formLabel;

            const title = compact(element.getAttribute("title"));
            if (title) return title;

            const placeholder = compact(element.getAttribute("placeholder"));
            if (placeholder) return placeholder;

            const value = compact(element.value);
            const tag = element.tagName.toLowerCase();
            const type = compact(element.getAttribute("type")).toLocaleLowerCase();
            if ((role === "button" || (tag === "input" && ["button", "submit", "reset"].includes(type))) && value) {
              return value;
            }

            return compact(element.innerText || element.textContent || "");
          }

          function isInteractive(element, role) {
            const tag = element.tagName.toLowerCase();
            return Boolean(
              tag === "button" ||
              tag === "select" ||
              tag === "textarea" ||
              tag === "input" ||
              (tag === "a" && element.hasAttribute("href")) ||
              element.hasAttribute("onclick") ||
              element.hasAttribute("contenteditable") ||
              element.tabIndex >= 0 ||
              ["button", "link", "menuitem", "tab", "checkbox", "radio", "switch", "slider", "textbox", "combobox"].includes(role)
            );
          }

          function isEditable(element, role) {
            const tag = element.tagName.toLowerCase();
            const type = String(element.getAttribute("type") || "").toLowerCase();
            if (element.isContentEditable || element.getAttribute("contenteditable") === "true") return true;
            if (tag === "textarea") return true;
            if (tag === "input" && !["button", "checkbox", "file", "hidden", "image", "radio", "range", "reset", "submit"].includes(type)) return true;
            return role === "textbox" && !isDisabled(element);
          }

          function isSensitiveField(element, summary) {
            const type = compact(element.getAttribute("type") || "").toLocaleLowerCase();
            if (type === "password" || type === "hidden") return true;

            const autocomplete = compact(element.getAttribute("autocomplete") || "").toLocaleLowerCase();
            if (/current-password|new-password|one-time-code|cc-|transaction-/.test(autocomplete)) return true;

            const description = compact([
              summary?.label || "",
              element.getAttribute("aria-label") || "",
              element.getAttribute("name") || "",
              element.getAttribute("id") || "",
              element.getAttribute("placeholder") || ""
            ].join(" ")).toLocaleLowerCase();
            return [
              "password", "passcode", "one time", "one-time", "otp",
              "verification code", "security code", "authentication code", "2fa", "mfa",
              "card number", "credit card", "debit card", "cardholder", "cvv", "cvc",
              "expiry", "expiration", "routing number", "bank account", "account number",
              "social security", "ssn", "username", "login id", "login email", "pin"
            ].some((term) => description.includes(term));
          }

          function isDisabled(element) {
            return Boolean(element.disabled || element.getAttribute("aria-disabled") === "true");
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
            return {
              offsetLeft: 0,
              offsetTop: 0,
              width: window.innerWidth,
              height: window.innerHeight
            };
          }

          function viewportRect(rect, viewport) {
            return {
              x: rect.x - viewport.offsetLeft,
              y: rect.y - viewport.offsetTop,
              width: rect.width,
              height: rect.height,
              top: rect.top - viewport.offsetTop,
              right: rect.right - viewport.offsetLeft,
              bottom: rect.bottom - viewport.offsetTop,
              left: rect.left - viewport.offsetLeft
            };
          }

          function visibleInViewport(element, viewport) {
            const rect = viewportRect(element.getBoundingClientRect(), viewport);
            if (rect.width <= 0 || rect.height <= 0) {
              return { visible: false, rect };
            }
            const style = window.getComputedStyle(element);
            const visible = style.display !== "none" &&
              style.visibility !== "hidden" &&
              style.visibility !== "collapse" &&
              Number(style.opacity || "1") > 0 &&
              rect.bottom >= 0 &&
              rect.right >= 0 &&
              rect.top <= viewport.height &&
              rect.left <= viewport.width;
            return { visible, rect };
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

          function selectorFingerprintFor(element, role, label, path, rect) {
            return [
              element.tagName.toLowerCase(),
              role || "",
              normalized(label || ""),
              "",
              path || "",
              Math.round(rect.width || 0) + "x" + Math.round(rect.height || 0)
            ].join("|");
          }

          function stableIDFor(index, fingerprint) {
            return String(index) + ":" + fingerprint;
          }

          function centerObscured(element, rect) {
            if (rect.width <= 0 || rect.height <= 0) return true;
            const x = Math.min(Math.max(rect.left + rect.width / 2, 0), window.innerWidth - 1);
            const y = Math.min(Math.max(rect.top + rect.height / 2, 0), window.innerHeight - 1);
            const top = document.elementFromPoint(x, y);
            return Boolean(top && top !== element && !element.contains(top));
          }

          function candidateSummary(element, index, score) {
            const viewport = currentViewport();
            const { visible, rect } = visibleInViewport(element, viewport);
            const role = roleFor(element);
            const label = nullable(labelFor(element, role));
            const text = nullable(element.innerText || element.textContent || "");
            const __d = __walk.describe(element);
            const path = __d.path;
            const fingerprint = __d.fingerprint;
            return {
              element,
              score,
              index: __d.index,
              tagName: element.tagName.toLowerCase(),
              role,
              label,
              text,
              path,
              selectorFingerprint: fingerprint,
              stableID: __d.stableID,
              bounds: {
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height
              },
              isVisible: visible,
              isInteractive: isInteractive(element, role),
              isDisabled: isDisabled(element),
              isEditable: isEditable(element, role),
              isObscuredAtCenter: centerObscured(element, rect)
            };
          }

          function serializable(summary) {
            if (!summary) return null;
            return {
              score: summary.score || 0,
              index: summary.index,
              tagName: summary.tagName,
              role: summary.role,
              label: summary.label,
              text: summary.text,
              path: summary.path,
              selectorFingerprint: summary.selectorFingerprint,
              bounds: summary.bounds,
              isVisible: Boolean(summary.isVisible),
              isInteractive: Boolean(summary.isInteractive),
              isDisabled: Boolean(summary.isDisabled),
              isEditable: Boolean(summary.isEditable),
              isObscuredAtCenter: Boolean(summary.isObscuredAtCenter)
            };
          }

          function allElements() {
            const values = [];
            const visit = (root) => {
              for (const element of root.querySelectorAll("*")) {
                values.push(element);
                if (element.shadowRoot) {
                  visit(element.shadowRoot);
                }
              }
            };
            visit(document);
            return values;
          }

          function scoreElement(element, index) {
            const summary = candidateSummary(element, index, 0);
            // Canonical stableID is the primary key (contract v1). Fall back to the
            // ephemeral snapshotElementID only for pre-canonical targets.
            const wantedStableID = compact(target?.stableID || target?.snapshotElementID || "");
            const wantedPath = compact(target?.path || "");
            const wantedFingerprint = compact(target?.selectorFingerprint || "");
            const wantedRole = normalized(target?.role || "");
            const wantedLabel = normalized(target?.label || "");
            const wantedText = normalized(target?.text || "");
            let score = 0;

            if (wantedStableID && summary.stableID === wantedStableID) score += 500;
            if (wantedFingerprint && summary.selectorFingerprint === wantedFingerprint) score += 350;
            if (wantedPath && summary.path === wantedPath) score += 275;

            const role = normalized(summary.role || "");
            const label = normalized(summary.label || "");
            const text = normalized(summary.text || "");

            if (wantedRole && role === wantedRole) score += 50;
            if (wantedLabel && label === wantedLabel) score += 180;
            if (wantedLabel && label.includes(wantedLabel)) score += 90;
            if (wantedText && text === wantedText) score += 120;
            if (wantedText && text.includes(wantedText)) score += 60;
            if (!wantedLabel && !wantedText && wantedRole && role === wantedRole) score += 10;
            if (summary.isInteractive) score += 8;
            if (summary.isVisible) score += 6;
            if (summary.isDisabled) score -= 100;

            summary.score = score;
            return summary;
          }

          function resolveTarget() {
            if (!target && action !== "pressEnter") {
              return [];
            }
            if (!target && action === "pressEnter") {
              const active = document.activeElement;
              return active ? [candidateSummary(active, 0, 100)] : [];
            }
            return allElements()
              .map(scoreElement)
              .filter((summary) => summary.score >= 50)
              .sort((left, right) => {
                if (right.score !== left.score) return right.score - left.score;
                const leftArea = (left.bounds.width || 0) * (left.bounds.height || 0);
                const rightArea = (right.bounds.width || 0) * (right.bounds.height || 0);
                return leftArea - rightArea;
              });
          }

          function baseResult(status, message, matches, selected, warnings = []) {
            return {
              status,
              succeeded: status === "succeeded",
              message,
              matchedElementCount: matches.length,
              selectedElement: serializable(selected),
              candidates: matches.slice(0, maxCandidates).map(serializable),
              warnings
            };
          }

          function failIfUnactionable(matches, selected, requiresEditable) {
            if (!matches.length || !selected) {
              return baseResult("noMatch", "No element matched the requested target.", matches, selected);
            }
            if (matches.length > 1 && matches[0].score === matches[1].score && matches[0].score >= 180) {
              return baseResult("ambiguousMatch", "Multiple elements matched the requested target.", matches, selected);
            }
            if (!selected.isVisible) {
              return baseResult("notVisible", "Matched element is not visible.", matches, selected);
            }
            if (selected.isDisabled) {
              return baseResult("notEnabled", "Matched element is disabled.", matches, selected);
            }
            if (requiresEditable && !selected.isEditable) {
              return baseResult("notEditable", "Matched element is not editable.", matches, selected);
            }
            if (action === "tap" && selected.isObscuredAtCenter) {
              return baseResult("obscured", "Matched element is obscured at its center point.", matches, selected);
            }
            return null;
          }

          function dispatchTap(element, summary) {
            element.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
            const rect = element.getBoundingClientRect();
            const x = rect.left + rect.width / 2;
            const y = rect.top + rect.height / 2;

            try {
              element.focus({ preventScroll: true });
            } catch (_) {}

            const common = {
              bubbles: true,
              cancelable: true,
              composed: true,
              clientX: x,
              clientY: y,
              screenX: x,
              screenY: y,
              view: window
            };

            if (window.PointerEvent) {
              element.dispatchEvent(new PointerEvent("pointerover", { ...common, pointerId: 1, pointerType: "touch", isPrimary: true }));
              element.dispatchEvent(new PointerEvent("pointermove", { ...common, pointerId: 1, pointerType: "touch", isPrimary: true }));
              element.dispatchEvent(new PointerEvent("pointerdown", { ...common, pointerId: 1, pointerType: "touch", isPrimary: true }));
            }
            element.dispatchEvent(new MouseEvent("mouseover", common));
            element.dispatchEvent(new MouseEvent("mousemove", common));
            element.dispatchEvent(new MouseEvent("mousedown", common));

            if (window.PointerEvent) {
              element.dispatchEvent(new PointerEvent("pointerup", { ...common, pointerId: 1, pointerType: "touch", isPrimary: true }));
            }
            element.dispatchEvent(new MouseEvent("mouseup", common));
            if (typeof element.click === "function") {
              element.click();
            } else {
              element.dispatchEvent(new MouseEvent("click", common));
            }

            return baseResult("succeeded", "Tapped '" + (summary.label || summary.text || summary.path || "element") + "'.", [summary], summary);
          }

          function setNativeValue(element, value) {
            const prototype = element.tagName.toLowerCase() === "textarea"
              ? window.HTMLTextAreaElement.prototype
              : window.HTMLInputElement.prototype;
            const descriptor = Object.getOwnPropertyDescriptor(prototype, "value");
            if (descriptor && descriptor.set) {
              descriptor.set.call(element, value);
            } else {
              element.value = value;
            }
          }

          function dispatchFill(element, summary, value) {
            element.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
            element.focus();
            if (element.isContentEditable || element.getAttribute("contenteditable") === "true") {
              element.textContent = value;
            } else {
              setNativeValue(element, value);
            }
            element.dispatchEvent(new InputEvent("beforeinput", { bubbles: true, cancelable: true, inputType: "insertText", data: value }));
            element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: value }));
            element.dispatchEvent(new Event("change", { bubbles: true }));

            if (shouldSubmit) {
              const form = element.closest && element.closest("form");
              if (form && typeof form.requestSubmit === "function") {
                form.requestSubmit();
              } else {
                dispatchEnter(element);
              }
            }

            return baseResult("succeeded", "Filled '" + (summary.label || summary.path || "field") + "'.", [summary], summary);
          }

          function dispatchEnter(element) {
            const common = { bubbles: true, cancelable: true, key: "Enter", code: "Enter", which: 13, keyCode: 13 };
            element.dispatchEvent(new KeyboardEvent("keydown", common));
            element.dispatchEvent(new KeyboardEvent("keypress", common));
            element.dispatchEvent(new KeyboardEvent("keyup", common));
          }

          const matches = resolveTarget();
          const selected = matches[0] || null;

          if (action === "resolve") {
            return matches.length
              ? baseResult("succeeded", "Matched element.", matches, selected)
              : baseResult("noMatch", "No element matched the requested target.", matches, selected);
          }

          const selectedElement = selected?.element || document.activeElement;
          if (action === "tap") {
            const failure = failIfUnactionable(matches, selected, false);
            if (failure) return failure;
            return dispatchTap(selected.element, selected);
          }

          if (action === "fill") {
            const failure = failIfUnactionable(matches, selected, true);
            if (failure) return failure;
            if (isSensitiveField(selected.element, selected)) {
              return baseResult(
                "humanInputRequired",
                "This credential, verification, or payment field must be completed by the user.",
                matches,
                selected,
                ["Sensitive fields are never filled by BrowserCaptureKit."]
              );
            }
            return dispatchFill(selected.element, selected, fillText || "");
          }

          if (action === "clear") {
            const failure = failIfUnactionable(matches, selected, true);
            if (failure) return failure;
            return dispatchFill(selected.element, selected, "");
          }

          if (action === "pressEnter") {
            if (!selectedElement) {
              return baseResult("noMatch", "No focused or matched element for Enter.", matches, selected);
            }
            dispatchEnter(selectedElement);
            return baseResult("succeeded", "Pressed Enter.", matches, selected || candidateSummary(selectedElement, 0, 100));
          }

          return baseResult("unsupported", "Unsupported action '" + action + "'.", matches, selected);
        """
}
