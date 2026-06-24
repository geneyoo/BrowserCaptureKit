import Foundation

enum BrowserAccessibilityScript {
    static let source = """
        (() => {
          const maxElements = 1200;
          const maxTextLength = 280;

          function compact(value) {
            return String(value || "").replace(/\\s+/g, " ").trim();
          }

          function truncate(value) {
            const text = compact(value);
            return text.length > maxTextLength ? text.slice(0, maxTextLength) : text;
          }

          function nullable(value) {
            const text = truncate(value);
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
            return null;
          }

          function roleFor(element) {
            return nullable(element.getAttribute("role")) || implicitRole(element);
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

          function canNameFromContent(element, role) {
            const tag = element.tagName.toLowerCase();
            return Boolean(
              ["button", "link", "menuitem", "tab", "checkbox", "radio", "switch", "heading"].includes(role) ||
              ["button", "a", "label", "summary"].includes(tag)
            );
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

          function hasVisibleTextChild(element, viewport) {
            return Array.from(element.children || []).some((child) => {
              const text = compact(child.innerText || child.textContent || "");
              if (!text) {
                return false;
              }
              return visibleInViewport(child, viewport).visible;
            });
          }

          function labelFor(element, role, textLeaf) {
            const ariaLabel = compact(element.getAttribute("aria-label"));
            if (ariaLabel) return { label: truncate(ariaLabel), source: "aria-label" };

            const labelledBy = textFromIDREFS(element.getAttribute("aria-labelledby"));
            if (labelledBy) return { label: truncate(labelledBy), source: "aria-labelledby" };

            if (element.tagName.toLowerCase() === "img") {
              const alt = compact(element.getAttribute("alt"));
              if (alt) return { label: truncate(alt), source: "alt" };
            }

            const formLabel = labelForInput(element);
            if (formLabel) return { label: truncate(formLabel), source: "label" };

            const title = compact(element.getAttribute("title"));
            if (title) return { label: truncate(title), source: "title" };

            const placeholder = compact(element.getAttribute("placeholder"));
            if (placeholder) return { label: truncate(placeholder), source: "placeholder" };

            const value = compact(element.value);
            if ((role === "button" || element.tagName.toLowerCase() === "input") && value) {
              return { label: truncate(value), source: "value" };
            }

            const text = compact(element.innerText || element.textContent || "");
            if (text && (canNameFromContent(element, role) || textLeaf)) {
              return { label: truncate(text), source: "text" };
            }

            return { label: null, source: null };
          }

          function pathFor(element) {
            const parts = [];
            let node = element;
            while (node && node.nodeType === Node.ELEMENT_NODE && node !== document.body && parts.length < 8) {
              let part = node.tagName.toLowerCase();
              if (node.id) {
                part += "#" + node.id;
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

          const candidates = Array.from(document.querySelectorAll("body *"));
          const elements = [];
          const viewport = currentViewport();
          let seenVisible = 0;
          let labeledVisible = 0;
          let unlabeledInteractive = 0;

          for (const element of candidates) {
            const { visible, rect } = visibleInViewport(element, viewport);
            if (!visible) {
              continue;
            }
            seenVisible += 1;

            const role = roleFor(element);
            const tagName = element.tagName.toLowerCase();
            const interactive = isInteractive(element, role);
            const rawText = compact(element.innerText || element.textContent || "");
            const textLeaf = Boolean(rawText && !hasVisibleTextChild(element, viewport));
            const label = labelFor(element, role, textLeaf);
            const text = nullable(rawText);
            const ariaHidden = element.closest("[aria-hidden='true']") !== null || element.getAttribute("aria-hidden") === "true";
            const landmarkRoles = ["article", "form", "main", "navigation", "section"];
            const roleIsMeaningful = Boolean(role && (!landmarkRoles.includes(role) || label.label));
            const semantic = Boolean(
              roleIsMeaningful ||
              label.label ||
              interactive ||
              textLeaf ||
              ["img", "video", "svg", "canvas"].includes(tagName)
            );

            if (label.label) {
              labeledVisible += 1;
            }
            if (interactive && !label.label) {
              unlabeledInteractive += 1;
            }
            if (!semantic || elements.length >= maxElements) {
              continue;
            }

            elements.push({
              index: seenVisible - 1,
              tagName,
              role,
              label: label.label,
              labelSource: label.source,
              text,
              value: nullable(element.value),
              placeholder: nullable(element.getAttribute("placeholder")),
              href: nullable(element.href || element.getAttribute("href")),
              source: nullable(element.currentSrc || element.src || element.getAttribute("src")),
              inputType: nullable(element.getAttribute("type")),
              isVisible: true,
              isInteractive: interactive,
              isDisabled: isDisabled(element),
              ariaHidden,
              bounds: {
                x: rect.x,
                y: rect.y,
                width: rect.width,
                height: rect.height
              },
              path: pathFor(element)
            });
          }

          return {
            url: window.location.href,
            title: document.title,
            viewportWidth: viewport.width,
            viewportHeight: viewport.height,
            elementCount: seenVisible,
            labeledElementCount: labeledVisible,
            unlabeledInteractiveElementCount: unlabeledInteractive,
            elementsOmitted: Math.max(0, seenVisible - elements.length),
            elements
          };
        })();
        """
}
