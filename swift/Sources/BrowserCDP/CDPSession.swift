import BrowserAX
import CoreGraphics
import Foundation

/// Semantic access to Chrome through the DevTools protocol.
///
/// This is the same contract `BrowserAXSession` offers — roles, accessible
/// names, ids, an epoch — served from the renderer instead of from macOS
/// Accessibility, because Chrome no longer answers the Accessibility door. See
/// `BrowserBackend` for that story.
///
/// Reading the page is one `Runtime.evaluate` of the script below, which also
/// parks the matched nodes in `window.__nautilus` so an action can name one by
/// index. That array dies with the document, so a navigation invalidates every
/// handle by construction — and the epoch catches the rest.
@MainActor
public final class CDPSession: BrowserBackend {
    public nonisolated static let defaultPort = 9222

    public var backendName: String { "cdp" }
    public private(set) var epoch: UInt64 = 0

    private let port: Int
    private var connection: CDPConnection?
    private var targetID: String?
    private var elementCount = 0

    public init(port: Int = CDPSession.defaultPort) { self.port = port }

    public func pageChanged() { epoch &+= 1 }

    // MARK: Finding the tab

    /// Is a DevTools endpoint there at all? Used at startup to decide whether
    /// to offer the tools, so this must not throw or block for long.
    public static func isReachable(port: Int = CDPSession.defaultPort) async -> Bool {
        (try? await version(port: port)) != nil
    }

    public static func version(port: Int) async throws -> [String: Any] {
        let url = URL(string: "http://127.0.0.1:\(port)/json/version")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CDPError.notReachable(port: port) }
        return object
    }

    private func pageTargets() async throws -> [[String: Any]] {
        let url = URL(string: "http://127.0.0.1:\(port)/json/list")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request),
            let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { throw CDPError.notReachable(port: port) }
        return list.filter {
            ($0["type"] as? String) == "page"
                && !(($0["url"] as? String) ?? "").hasPrefix("devtools://")
        }
    }

    /// Connect to the tab the user is actually looking at.
    ///
    /// `/json/list` has no "this is the front tab" flag and its order is not a
    /// promise, so the tab is identified by asking the pages themselves:
    /// `document.visibilityState` is `visible` only for the active tab of a
    /// window. The chosen target is cached and re-checked, because with nine
    /// tabs open a scan on every call would mean nine websocket handshakes.
    private func activeConnection() async throws -> CDPConnection {
        if let connection, let targetID {
            if let state = try? await connection.evaluate("document.visibilityState") as? String,
                state == "visible",
                try await pageTargets().contains(where: { ($0["id"] as? String) == targetID })
            {
                return connection
            }
            connection.close()
            self.connection = nil
            self.targetID = nil
        }

        let targets = try await pageTargets()
        guard !targets.isEmpty else { throw CDPError.noPage(port: port) }

        var fallback: (CDPConnection, String)?
        for target in targets {
            guard let id = target["id"] as? String,
                let socket = target["webSocketDebuggerUrl"] as? String,
                let url = URL(string: socket)
            else { continue }
            let candidate = CDPConnection(url: url)
            let state = try? await candidate.evaluate("document.visibilityState") as? String
            if state == "visible" {
                fallback?.0.close()
                connection = candidate
                targetID = id
                return candidate
            }
            // Keep the first that answered at all: a single minimized window
            // has no visible tab, and driving it beats refusing to work.
            if fallback == nil, state != nil {
                fallback = (candidate, id)
            } else {
                candidate.close()
            }
        }
        guard let fallback else { throw CDPError.noPage(port: port) }
        connection = fallback.0
        targetID = fallback.1
        return fallback.0
    }

    /// Wait until the document is worth reading.
    ///
    /// `activate` returns as soon as the click is delivered, so the next call
    /// can land while the browser is between documents — `document.body` is
    /// null for that moment. Reading then reports an empty page, which is
    /// indistinguishable to a caller from a page that really has nothing on it:
    /// measured here, a click through to iana.org observed as `count: 0` and
    /// advised falling back to OCR on a perfectly ordinary HTML page.
    ///
    /// This is the same hazard the Accessibility backend has with Safari's
    /// lazily-built tree, and gets the same answer: wait a moment and look
    /// again rather than believe the first thin result.
    private func waitForDocument(_ connection: CDPConnection) async {
        for _ in 0..<15 {
            let state = try? await connection.evaluate(
                "document.readyState + '|' + (document.body ? '1' : '0')") as? String
            if let state, state.hasSuffix("|1"), !state.hasPrefix("loading") { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    // MARK: Reading

    public func observe(
        preferred: String? = nil, limit: Int = 250, interactiveOnly: Bool = false
    ) async throws -> BrowserSnapshot {
        let connection = try await activeConnection()
        await waitForDocument(connection)
        let raw = try await connection.evaluate(
            Self.observeScript(limit: limit, interactiveOnly: interactiveOnly))
        guard let text = raw as? String,
            let payload = try JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any]
        else { throw CDPError.evaluation("the page reader returned nothing usable") }

        let rows = (payload["elements"] as? [[String: Any]]) ?? []
        elementCount = rows.count
        let elements = rows.enumerated().map { index, row -> BrowserElement in
            var frame: CGRect?
            if let rect = row["rect"] as? [String: Any],
                let x = rect["x"] as? Double, let y = rect["y"] as? Double,
                let w = rect["w"] as? Double, let h = rect["h"] as? Double
            {
                frame = CGRect(x: x, y: y, width: w, height: h)
            }
            return BrowserElement(
                id: "e\(index + 1)",
                role: (row["role"] as? String) ?? "text",
                name: (row["name"] as? String) ?? "",
                value: row["value"] as? String,
                enabled: (row["enabled"] as? Bool) ?? true,
                focused: (row["focused"] as? Bool) ?? false,
                frame: frame,
                source: "cdp")
        }

        return BrowserSnapshot(
            app: "Chrome",
            title: (payload["title"] as? String) ?? "",
            url: payload["url"] as? String,
            epoch: epoch,
            elements: elements,
            truncated: (payload["truncated"] as? Bool) ?? false)
    }

    // MARK: Acting

    /// Turn `e17` into the index the page script parked the node at, refusing
    /// anything observed under an older epoch.
    private func index(_ id: String, observedEpoch: UInt64) throws -> Int {
        guard observedEpoch == epoch else {
            throw CDPError.staleElement(
                id: id, observedEpoch: observedEpoch, currentEpoch: epoch)
        }
        guard id.hasPrefix("e"), let number = Int(id.dropFirst()),
            number >= 1, number <= elementCount
        else { throw CDPError.noSuchElement(id: id, known: elementCount) }
        return number - 1
    }

    public func activate(_ id: String, observedEpoch: UInt64) async throws {
        let slot = try index(id, observedEpoch: observedEpoch)
        let connection = try await activeConnection()
        let outcome =
            try await connection.evaluate(
                #"""
                (() => {
                  const el = (window.__nautilus || [])[\#(slot)];
                  if (!el) return 'missing';
                  if (!el.isConnected) return 'detached';
                  el.scrollIntoView({ block: 'center', inline: 'center' });
                  el.click();
                  return 'ok';
                })()
                """#) as? String
        switch outcome {
        case "ok":
            // A click that navigates needs a moment before the next read; the
            // observe side waits too, but only once the document has begun to
            // change. Without this the old document can still be current.
            try? await Task.sleep(nanoseconds: 150_000_000)
            pageChanged()
        case "detached": throw CDPError.detached(id: id)
        default: throw CDPError.noSuchElement(id: id, known: elementCount)
        }
    }

    public func setValue(_ id: String, to text: String, observedEpoch: UInt64) async throws {
        let slot = try index(id, observedEpoch: observedEpoch)
        let connection = try await activeConnection()
        let encoded =
            String(
                data: try JSONSerialization.data(withJSONObject: [text]), encoding: .utf8) ?? "[\"\"]"
        let outcome =
            try await connection.evaluate(
                #"""
                (() => {
                  const el = (window.__nautilus || [])[\#(slot)];
                  if (!el) return 'missing';
                  if (!el.isConnected) return 'detached';
                  const value = \#(encoded)[0];
                  el.focus();
                  // React and friends install their own value setter and only
                  // notice a write that goes through the prototype's.
                  const proto = el instanceof HTMLTextAreaElement
                    ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                  const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
                  if (setter && (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement)) {
                    setter.call(el, value);
                  } else if ('value' in el) {
                    el.value = value;
                  } else {
                    el.textContent = value;
                  }
                  el.dispatchEvent(new Event('input', { bubbles: true }));
                  el.dispatchEvent(new Event('change', { bubbles: true }));
                  return 'ok';
                })()
                """#) as? String
        switch outcome {
        case "ok": pageChanged()
        case "detached": throw CDPError.detached(id: id)
        default: throw CDPError.noSuchElement(id: id, known: elementCount)
        }
    }

    /// Scroll the page.
    ///
    /// Unlike the Accessibility backend this needs no wheel events and no
    /// frontmost window: the page scrolls itself. Nothing is raised, so nothing
    /// steals the user's focus.
    @discardableResult
    public func scroll(
        _ direction: BrowserScrollDirection, pages: Double = 1, preferred: String? = nil
    ) async throws -> String {
        let connection = try await activeConnection()
        await waitForDocument(connection)
        let amount = max(0.1, pages)
        let expression: String
        switch direction {
        case .down, .up:
            let sign = direction == .down ? 1.0 : -1.0
            expression = """
                (() => { const d = window.innerHeight * 0.85 * \(amount) * \(sign); \
                window.scrollBy({ top: d, behavior: 'instant' }); \
                return Math.round(window.scrollY); })()
                """
        case .top:
            expression =
                "(() => { window.scrollTo({ top: 0, behavior: 'instant' }); return 0; })()"
        case .bottom:
            expression = """
                (() => { const d = document.scrollingElement || document.documentElement; \
                window.scrollTo({ top: d ? d.scrollHeight : 0, behavior: 'instant' }); \
                return Math.round(window.scrollY); })()
                """
        }
        let position = try await connection.evaluate(expression)
        pageChanged()
        let offset = (position as? Double).map { Int($0) } ?? 0
        switch direction {
        case .top, .bottom:
            return "Jumped to the \(direction.rawValue) of the page (now at y \(offset))."
        case .down, .up:
            return "Scrolled \(direction.rawValue) \(amount) viewport(s), now at y \(offset)."
        }
    }

    /// Go back in history.
    ///
    /// `history.back()` rather than ⌘[ — no keystroke means no need to raise
    /// the window, which is the whole reason the Accessibility backend has to
    /// fail loudly when it cannot come to the front.
    @discardableResult
    public func goBack(steps: Int = 1, preferred: String? = nil) async throws -> String {
        let connection = try await activeConnection()
        let count = max(1, min(steps, 20))
        _ = try? await connection.evaluate("history.go(\(-count))")
        // The navigation is asynchronous, so wait for the new document rather
        // than guessing at a delay.
        try? await Task.sleep(nanoseconds: 150_000_000)
        await waitForDocument(connection)
        pageChanged()
        return "Went back \(count) step(s) in Chrome."
    }

    // MARK: The page reader

    /// The script that turns a document into a list of addressable things.
    ///
    /// It mirrors what the Accessibility backend reports — role, accessible
    /// name, value, enabled, focused, screen rectangle — deriving each from the
    /// DOM the way the accessible name computation does: `aria-label`, then
    /// `aria-labelledby`, then the element's own text, then the attributes that
    /// stand in for a label on a bare control.
    ///
    /// Only elements that can be acted on, headings, and anything carrying an
    /// explicit `role` are collected. A document has thousands of layout nodes
    /// and a listing dominated by them buries the handful that matter — the
    /// same reason the AX walk keeps a role allow-list.
    static func observeScript(limit: Int, interactiveOnly: Bool) -> String {
        #"""
        (() => {
          const LIMIT = \#(limit), INTERACTIVE_ONLY = \#(interactiveOnly ? "true" : "false");
          const store = (window.__nautilus = []);
          const tidy = (s) => (s || '').replace(/\u00a0/g, ' ').split(/\s+/).filter(Boolean).join(' ');

          const explicitRoles = {
            button: 'button', link: 'link', textbox: 'textbox', searchbox: 'textbox',
            checkbox: 'checkbox', radio: 'radio', combobox: 'combobox', listbox: 'combobox',
            menuitem: 'button', tab: 'button', switch: 'checkbox', heading: 'heading',
            img: 'image', option: 'text',
          };

          const roleOf = (el) => {
            const explicit = (el.getAttribute('role') || '').trim().toLowerCase();
            if (explicitRoles[explicit]) return explicitRoles[explicit];
            const tag = el.tagName.toLowerCase();
            if (tag === 'a') return el.hasAttribute('href') ? 'link' : null;
            if (tag === 'button' || tag === 'summary') return 'button';
            if (tag === 'select') return 'combobox';
            if (tag === 'textarea') return 'textbox';
            if (tag === 'img') return 'image';
            if (/^h[1-6]$/.test(tag)) return 'heading';
            if (tag === 'p' || tag === 'li') return 'text';
            if (tag === 'input') {
              const t = (el.getAttribute('type') || 'text').toLowerCase();
              if (t === 'checkbox') return 'checkbox';
              if (t === 'radio') return 'radio';
              if (t === 'hidden') return null;
              if (['button', 'submit', 'reset', 'image'].includes(t)) return 'button';
              return 'textbox';
            }
            return null;
          };

          const nameOf = (el, role) => {
            const aria = el.getAttribute('aria-label');
            if (tidy(aria)) return tidy(aria);
            const labelledBy = el.getAttribute('aria-labelledby');
            if (labelledBy) {
              const joined = labelledBy.split(/\s+/)
                .map((id) => document.getElementById(id))
                .filter(Boolean).map((n) => n.innerText || n.textContent).join(' ');
              if (tidy(joined)) return tidy(joined);
            }
            if (role === 'image') return tidy(el.getAttribute('alt') || el.getAttribute('title'));
            if (['textbox', 'checkbox', 'radio', 'combobox'].includes(role)) {
              const label = el.labels && el.labels[0];
              if (label && tidy(label.innerText)) return tidy(label.innerText);
              const named = el.getAttribute('placeholder') || el.getAttribute('title')
                || el.getAttribute('name') || el.getAttribute('aria-placeholder');
              if (tidy(named)) return tidy(named);
            }
            const text = tidy(el.innerText || el.textContent);
            if (text) return text.slice(0, 200);
            return tidy(el.getAttribute('title') || el.getAttribute('alt'));
          };

          // Off-screen and hidden nodes are not addressable and pad the list.
          const shown = (el) => {
            const r = el.getBoundingClientRect();
            if (r.width === 0 && r.height === 0) return false;
            const style = window.getComputedStyle(el);
            return style.visibility !== 'hidden' && style.display !== 'none'
              && style.opacity !== '0';
          };

          // Screen coordinates, to match what the AX backend reports: the page
          // rect offset by where the viewport sits on the desktop.
          const chromeHeight = window.outerHeight - window.innerHeight;
          const toScreen = (r) => ({
            x: Math.round(r.left + window.screenX),
            y: Math.round(r.top + window.screenY + chromeHeight),
            w: Math.round(r.width), h: Math.round(r.height),
          });

          const selector = 'a,button,input,select,textarea,summary,h1,h2,h3,h4,h5,h6,[role]'
            + (INTERACTIVE_ONLY ? '' : ',p,li');
          const elements = [];
          let truncated = false;

          for (const el of document.querySelectorAll(selector)) {
            if (elements.length >= LIMIT) { truncated = true; break; }
            const role = roleOf(el);
            if (!role) continue;
            const interactive = !['text', 'heading', 'image'].includes(role);
            if (INTERACTIVE_ONLY && !interactive) continue;
            if (!shown(el)) continue;
            // A nested <li> wrapping only a link would report the link's text
            // twice; keep the inner, addressable one.
            if (role === 'text' && el.querySelector('a,button,input,select,textarea')) continue;
            const name = nameOf(el, role);
            // A checkbox's `value` is the string it submits — "on" unless the
            // markup says otherwise — and stays "on" whether or not it is
            // ticked. The state is what a caller is asking about, so report
            // that instead; AX does the same through AXValue.
            let value;
            if (role === 'checkbox' || role === 'radio') {
              value = el.checked ? 'checked' : 'unchecked';
            } else if (el.value !== undefined && typeof el.value === 'string') {
              value = el.value;
            }
            if (!name && !value) continue;
            store.push(el);
            elements.push({
              role, name,
              value: value || undefined,
              enabled: !el.disabled && el.getAttribute('aria-disabled') !== 'true',
              focused: el === document.activeElement,
              rect: toScreen(el.getBoundingClientRect()),
            });
          }

          return JSON.stringify({
            title: document.title, url: location.href, truncated, elements,
          });
        })()
        """#
    }
}
