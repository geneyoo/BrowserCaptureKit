import Foundation

// swiftlint:disable function_body_length
enum BrowserActionScript {
    static func clickElementSource(label: String, role: String?) -> String {
        """
        (() => {
          const targetLabel = \(javaScriptStringLiteral(label));
          const targetRole = \(javaScriptNullableStringLiteral(role));

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
            if ((role === "button" || element.tagName.toLowerCase() === "input") && value) {
              return value;
            }

            return compact(element.innerText || element.textContent || "");
          }

          function isDisabled(element) {
            return Boolean(element.disabled || element.getAttribute("aria-disabled") === "true");
          }

          function isVisible(element) {
            const rect = element.getBoundingClientRect();
            if (rect.width <= 0 || rect.height <= 0) return false;
            const style = window.getComputedStyle(element);
            return style.display !== "none" &&
              style.visibility !== "hidden" &&
              style.visibility !== "collapse" &&
              Number(style.opacity || "1") > 0 &&
              rect.bottom >= 0 &&
              rect.right >= 0 &&
              rect.top <= (window.visualViewport?.height || window.innerHeight) &&
              rect.left <= (window.visualViewport?.width || window.innerWidth);
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

          const wantedLabel = normalized(targetLabel);
          const wantedRole = normalized(targetRole || "");
          const matches = Array.from(document.querySelectorAll("body *"))
            .filter((element) => isVisible(element) && !isDisabled(element))
            .map((element) => {
              const role = roleFor(element);
              const label = labelFor(element, role);
              const normalizedLabel = normalized(label);
              const normalizedRole = normalized(role || "");
              let score = 0;
              if (normalizedLabel === wantedLabel) score += 100;
              if (normalizedLabel.includes(wantedLabel)) score += 50;
              if (wantedRole && normalizedRole === wantedRole) score += 25;
              if (["button", "link", "tab", "menuitem"].includes(normalizedRole)) score += 10;
              const rect = element.getBoundingClientRect();
              const area = rect.width * rect.height;
              return { element, role, label, score, area, path: pathFor(element) };
            })
            .filter((candidate) => candidate.score >= 50)
            .sort((left, right) => {
              if (right.score !== left.score) return right.score - left.score;
              return left.area - right.area;
            });

          if (!matches.length) {
            return {
              succeeded: false,
              message: "No visible element matched label '" + targetLabel + "'.",
              matchedElementCount: 0,
              label: targetLabel,
              role: targetRole,
              path: null
            };
          }

          const match = matches[0];
          const element = match.element;
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
          element.dispatchEvent(new MouseEvent("click", common));

          if (typeof element.click === "function") {
            element.click();
          }

          return {
            succeeded: true,
            message: "Clicked '" + match.label + "'.",
            matchedElementCount: matches.length,
            label: match.label,
            role: match.role,
            path: match.path
          };
        })();
        """
    }

    private static func javaScriptNullableStringLiteral(_ value: String?) -> String {
        guard let value else {
            return "null"
        }
        return javaScriptStringLiteral(value)
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard JSONSerialization.isValidJSONObject([value]),
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let text = String(data: data, encoding: .utf8),
            text.hasPrefix("["),
            text.hasSuffix("]")
        else {
            return "\"\""
        }

        return String(text.dropFirst().dropLast())
    }
}
