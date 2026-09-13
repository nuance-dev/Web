import Foundation
import WebKit

/// Coordinates per-tab agent actions and bridge communication. M0 scaffold.
@MainActor
public final class PageAgent: NSObject {
    public enum Mode { case headed, headless }

    public private(set) var mode: Mode = .headed
    private weak var webView: WKWebView?
    private var lastActionAt: Date = .distantPast
    private let minimumActionInterval: TimeInterval = 0.4  // M2 rate limit: <= 2 actions/sec

    public init(webView: WKWebView?) {
        self.webView = webView
    }

    public func setMode(headless: Bool) {
        mode = headless ? .headless : .headed
    }

    public func navigate(_ url: URL, newTab: Bool) async {
        guard AgentPermissionManager.browserAutomationEnabled,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              !newTab, let webView else { return }
        await MainActor.run { webView.load(URLRequest(url: url)) }
    }

    public func requestElements(matching locator: LocatorInput) async -> [ElementSummary] {
        guard let webView else { return [] }
        // Ensure runtime is ready after navigations or WebContent restarts
        _ = await ensureRuntimeReady(timeoutMs: 2500)
        let encoder = JSONEncoder()
        guard let locatorData = try? encoder.encode(locator),
            let locatorJson = String(data: locatorData, encoding: .utf8)
        else { return [] }

        let escaped = Self.escapeForJavaScriptString(locatorJson)
        let script =
            "(() => JSON.stringify(window.__agent && window.__agent.findElements ? window.__agent.findElements(JSON.parse('\(escaped)')) : []))();"

        // Poll up to ~3s for dynamic content like Reddit posts
        let start = Date().timeIntervalSince1970
        let timeout: Double = 3.0
        while Date().timeIntervalSince1970 - start < timeout {
            if let jsonString = await Self.evaluateJSString(script, in: webView),
                let data = jsonString.data(using: .utf8)
            {
                let decoder = JSONDecoder()
                if let elements = try? decoder.decode([ElementSummary].self, from: data) {
                    if !elements.isEmpty { return elements }
                }
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        // One final attempt to return whatever is present (even empty)
        if let jsonString = await Self.evaluateJSString(script, in: webView),
            let data = jsonString.data(using: .utf8)
        {
            let decoder = JSONDecoder()
            if let elements = try? decoder.decode([ElementSummary].self, from: data) {
                return elements
            }
        }
        return []
    }

    public func execute(plan: [PageAction]) async -> [ActionResult] {
        var results: [ActionResult] = []
        // Ensure the injected runtime is ready before executing actions
        _ = await ensureRuntimeReady(timeoutMs: 2000)
        for step in plan {
            switch step.type {
            case .navigate:
                if let urlString = step.url, let url = URL(string: urlString) {
                    await navigate(url, newTab: step.newTab ?? false)
                    results.append(ActionResult(actionId: step.id, success: true))
                } else {
                    results.append(
                        ActionResult(actionId: step.id, success: false, message: "invalid url"))
                }
            case .findElements:
                if let locator = step.locator {
                    let items = await requestElements(matching: locator)
                    results.append(
                        ActionResult(
                            actionId: step.id, success: true,
                            message: "found \(items.count) elements"))
                } else {
                    results.append(
                        ActionResult(actionId: step.id, success: false, message: "missing locator"))
                }
            case .click:
                if let locator = step.locator {
                    let ok = await click(locator: locator)
                    results.append(ActionResult(actionId: step.id, success: ok))
                } else {
                    results.append(
                        ActionResult(actionId: step.id, success: false, message: "missing locator"))
                }
            case .typeText:
                if let locator = step.locator, let text = step.text {
                    let ok = await typeText(
                        locator: locator, text: text, submit: step.submit ?? false)
                    results.append(ActionResult(actionId: step.id, success: ok))
                } else {
                    results.append(
                        ActionResult(
                            actionId: step.id, success: false, message: "missing locator or text"))
                }
            case .select:
                if let locator = step.locator, let value = step.value {
                    let ok = await select(locator: locator, value: value)
                    results.append(ActionResult(actionId: step.id, success: ok))
                } else {
                    results.append(
                        ActionResult(
                            actionId: step.id, success: false, message: "missing locator or value"))
                }
            case .scroll:
                let ok = await scroll(
                    target: step.locator, direction: step.direction, amountPx: step.amountPx)
                results.append(ActionResult(actionId: step.id, success: ok))
            case .waitFor:
                let ok = await waitFor(predicate: step, timeoutMs: step.timeoutMs)
                results.append(ActionResult(actionId: step.id, success: ok))
            default:
                results.append(
                    ActionResult(actionId: step.id, success: false, message: "not implemented"))
            }
        }
        return results
    }

    // MARK: - Individual Actions

    public func click(locator: LocatorInput) async -> Bool {
        guard AgentPermissionManager.browserAutomationEnabled else { return false }
        await throttleIfNeeded()
        return await callAgentAction(name: "click", payload: locator)
    }

    public func typeText(locator: LocatorInput, text: String, submit: Bool) async -> Bool {
        guard AgentPermissionManager.browserAutomationEnabled else { return false }
        guard let webView else { return false }
        await throttleIfNeeded()
        let encoder = JSONEncoder()
        guard let locData = try? encoder.encode(locator),
            let locJson = String(data: locData, encoding: .utf8)
        else { return false }
        let escapedLoc = Self.escapeForJavaScriptString(locJson)
        let escapedText = Self.escapeForJavaScriptString(text)
        let script =
            "(() => JSON.stringify(window.__agent && window.__agent.typeText ? window.__agent.typeText(JSON.parse('\(escapedLoc)'), JSON.parse('\"\(escapedText)\"'), \(submit ? "true" : "false")) : { ok: false }))();"
        return await Self.parseOk(from: script, in: webView)
    }

    /// Returns a minimal summary of the currently focused element, if any
    public func getFocusedElementSummary() async -> ElementSummary? {
        guard let webView else { return nil }
        let js = """
            (function(){
                try {
                    var el = document.activeElement;
                    if (!el) return null;
                    var rect = el.getBoundingClientRect();
                    function isVisible(node){ try { var r=node.getBoundingClientRect(); var s=getComputedStyle(node); return r.width>0 && r.height>0 && s.visibility!=='hidden' && s.display!=='none'; } catch(e) { return false; } }
                    function roleFor(node){ try { var tag=(node.tagName||'').toLowerCase(); if (node.getAttribute && node.getAttribute('role')) return node.getAttribute('role'); if (tag==='a') return 'link'; if (tag==='button') return 'button'; if (tag==='input') return 'input'; if (tag==='select') return 'select'; if (tag==='textarea') return 'textbox'; return tag; } catch(e){ return ''; } }
                    function nameFor(node){ try { return (node.getAttribute && (node.getAttribute('aria-label') || node.getAttribute('name'))) || (node.innerText || node.textContent || '').trim(); } catch(e){ return ''; } }
                    var out = {
                        id: 'focused',
                        role: roleFor(el),
                        name: nameFor(el),
                        text: String((el.innerText || el.textContent || '')).slice(0,200),
                        isVisible: isVisible(el),
                        boundingBox: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
                        locatorHint: null
                    };
                    return JSON.stringify(out);
                } catch(e) { return null; }
            })();
            """
        if let json = await Self.evaluateJSString(js, in: webView),
            let data = json.data(using: .utf8)
        {
            return try? JSONDecoder().decode(ElementSummary.self, from: data)
        }
        return nil
    }

    public func select(locator: LocatorInput, value: String) async -> Bool {
        guard AgentPermissionManager.browserAutomationEnabled else { return false }
        guard let webView else { return false }
        await throttleIfNeeded()
        let encoder = JSONEncoder()
        guard let locData = try? encoder.encode(locator),
            let locJson = String(data: locData, encoding: .utf8)
        else { return false }
        let escapedLoc = Self.escapeForJavaScriptString(locJson)
        let escapedVal = Self.escapeForJavaScriptString(value)
        let script =
            "(() => JSON.stringify(window.__agent && window.__agent.select ? window.__agent.select(JSON.parse('\(escapedLoc)'), JSON.parse('\"\(escapedVal)\"')) : { ok: false }))();"
        return await Self.parseOk(from: script, in: webView)
    }

    /// Best-effort consent/banner dismiss
    public func dismissConsent() async -> Bool {
        guard AgentPermissionManager.browserAutomationEnabled else { return false }
        guard let webView else { return false }
        await throttleIfNeeded()
        let script =
            "(() => JSON.stringify(window.__agent && window.__agent.dismissConsent ? window.__agent.dismissConsent() : { ok: false }))();"
        return await Self.parseOk(from: script, in: webView)
    }

    public func scroll(target: LocatorInput?, direction: String?, amountPx: Int?) async -> Bool {
        guard let webView else { return false }
        await throttleIfNeeded()
        let encoder = JSONEncoder()
        let targetJson: String = {
            if let target = target, let data = try? encoder.encode(target),
                let s = String(data: data, encoding: .utf8)
            {
                return Self.escapeForJavaScriptString(s)
            } else {
                return "null"
            }
        }()
        let dir = direction ?? "down"
        let amt = amountPx ?? 600
        let dirEsc = Self.escapeForJavaScriptString(dir)
        let script =
            "(() => JSON.stringify(window.__agent && window.__agent.scroll ? window.__agent.scroll(\(target == nil ? "null" : "JSON.parse('" + targetJson + "')"), JSON.parse('\"\(dirEsc)\"'), \(amt)) : { ok: false }))();"
        return await Self.parseOk(from: script, in: webView)
    }

    // MARK: - M2: Safe Extraction
    /// Extracts text from the page respecting redaction rules.
    /// readMode: "selection" | "article" | "all"
    public func extract(readMode: String, selector: String?) async -> String {
        guard let webView else { return "" }
        let safeSelector = selector.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let mode = readMode.lowercased()
        let js: String
        if mode == "selection" {
            js =
                "(() => { try { return String(window.getSelection && window.getSelection().toString ? window.getSelection().toString() : ''); } catch(e) { return ''; } })();"
        } else if mode == "article" {
            // Prefer <article>, fallback to main content heuristics
            js =
                "(() => { try { const el = document.querySelector('article') || document.querySelector('main') || document.body; return (el.innerText || el.textContent || '').slice(0, 20000); } catch(e) { return ''; } })();"
        } else if let selector, !selector.isEmpty {
            js =
                "(() => { try { const el = document.querySelector(\(safeSelector)); return el ? (el.innerText || el.textContent || '').slice(0, 20000) : ''; } catch(e) { return ''; } })();"
        } else {
            js =
                "(() => { try { return (document.body && (document.body.innerText || document.body.textContent) || '').slice(0, 20000); } catch(e) { return ''; } })();"
        }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { result, _ in
                continuation.resume(returning: (result as? String) ?? "")
            }
        }
    }

    // MARK: - M3: Vision Snapshot
    /// Takes a snapshot of the page. If locator provided and cropToElement == true, crops to element bounds.
    public func takeSnapshotBase64(locator: LocatorInput?, cropToElement: Bool) async -> String? {
        guard let webView else { return nil }
        var cropRect: CGRect? = nil
        if cropToElement, let locator = locator {
            // Measure the element in viewport coordinates
            let encoder = JSONEncoder()
            if let locData = try? encoder.encode(locator),
                let locJson = String(data: locData, encoding: .utf8)
            {
                let escaped = Self.escapeForJavaScriptString(locJson)
                let measureJS =
                    "(() => { try { if (!window.__agent || !window.__agent.findElements) return null; const els = window.__agent.findElements(JSON.parse('\(escaped)')); if (!els || els.length === 0) return null; const hint = els[0].locatorHint; let el = null; if (hint) { el = document.querySelector(hint); } if (!el) { el = document.querySelector('[role]') } const r = el ? el.getBoundingClientRect() : null; return r ? {x:r.left, y:r.top, width:r.width, height:r.height} : null; } catch(e) { return null; } })();"
                if let rectDict = await Self.evaluateJSString(measureJS, in: webView).flatMap({
                    $0.data(using: .utf8)
                }).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
                    if let x = rectDict["x"] as? Double, let y = rectDict["y"] as? Double,
                        let w = rectDict["width"] as? Double, let h = rectDict["height"] as? Double
                    {
                        cropRect = CGRect(x: x, y: y, width: w, height: h)
                    }
                }
            }
        }

        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = true
        if let cropRect { config.rect = cropRect }

        return await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: config) { image, error in
                guard let image else {
                    continuation.resume(returning: nil)
                    return
                }
                guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                    let png = rep.representation(using: .png, properties: [:])
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: png.base64EncodedString())
            }
        }
    }

    /// Minimal waitFor supporting {readyState:"complete"} or {selector:"..."} or {delayMs:n}
    public func waitFor(predicate: PageAction, timeoutMs: Int?) async -> Bool {
        guard let webView else { return false }

        // Swift-side implementation to avoid Promise bridging issues in WKWebView
        let to = timeoutMs ?? 5000

        // Case 1: explicit delay
        if let delay = predicate.delayMs ?? predicate.amountPx, delay > 0 {
            let clamped = min(max(0, delay), to)
            try? await Task.sleep(nanoseconds: UInt64(clamped) * 1_000_000)
            return true
        }

        let deadline = Date().timeIntervalSince1970 + Double(to) / 1000.0

        // Helper: evaluate a boolean JS expression
        func evalBool(_ js: String) async -> Bool {
            await withCheckedContinuation { continuation in
                webView.evaluateJavaScript(js) { result, _ in
                    continuation.resume(returning: (result as? Bool) == true)
                }
            }
        }

        // Case 2: wait for readyState === 'complete' and brief network idle
        if predicate.direction == "ready" {
            while Date().timeIntervalSince1970 < deadline {
                let ready = await evalBool("document.readyState === 'complete'")
                if ready {
                    // opportunistic idle
                    _ = await evalBool(
                        "(function(){ try { return window.__agentNetIsIdle && window.__agentNetIsIdle(450); } catch(e){ return true; } })();"
                    )
                    return true
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            return false
        }

        // Case 3: wait for a visible selector (predicate.text used as CSS selector)
        if let selector = predicate.text, !selector.isEmpty {
            // Escape selector for safe JS embedding
            let safeSelector =
                selector
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\\'")
                .replacingOccurrences(of: "\n", with: " ")
            let js =
                "(() => { try { const el = document.querySelector('\(safeSelector)'); if (!el) return false; const r = el.getBoundingClientRect(); const s = window.getComputedStyle(el); return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none'; } catch (e) { return false; } })();"
            while Date().timeIntervalSince1970 < deadline {
                if await evalBool(js) {
                    _ = await evalBool(
                        "(function(){ try { return window.__agentNetIsIdle && window.__agentNetIsIdle(450); } catch(e){ return true; } })();"
                    )
                    return true
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            return false
        }

        // Case 4: generic network idle (no outstanding fetch/XHR for 600ms)
        while Date().timeIntervalSince1970 < deadline {
            let netIdle = await evalBool(
                "(function(){ try { return window.__agentNetIsIdle && window.__agentNetIsIdle(600); } catch(e){ return false; } })();"
            )
            if netIdle { return true }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        // Default: small stabilization wait
        let fallback = min(max(300, to), 8000)
        try? await Task.sleep(nanoseconds: UInt64(fallback) * 1_000_000)
        return true
    }

    // MARK: - JS Bridge Helpers

    private static func parseOk(from script: String, in webView: WKWebView) async -> Bool {
        if let jsonString = await evaluateJSString(script, in: webView),
            let data = jsonString.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let ok = dict["ok"] as? Bool
        {
            return ok
        }
        return false
    }

    private func callAgentAction<T: Encodable>(name: String, payload: T) async -> Bool {
        guard let webView else { return false }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload),
            let json = String(data: data, encoding: .utf8)
        else { return false }
        let escaped = Self.escapeForJavaScriptString(json)
        let script =
            "(() => JSON.stringify(window.__agent && window.__agent.\(name) ? window.__agent.\(name)(JSON.parse('\(escaped)')) : { ok: false }))();"
        return await Self.parseOk(from: script, in: webView)
    }

    private static func evaluateJSString(_ script: String, in webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let s = result as? String, error == nil {
                    continuation.resume(returning: s)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private static func escapeForJavaScriptString(_ raw: String) -> String {
        var s = raw
        s = s.replacingOccurrences(of: "\\", with: "\\\\")
        s = s.replacingOccurrences(of: "'", with: "\\\'")
        s = s.replacingOccurrences(of: "\n", with: "\\n")
        s = s.replacingOccurrences(of: "\r", with: "\\r")
        s = s.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        s = s.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return s
    }

    // MARK: - Rate limiting
    private func throttleIfNeeded() async {
        let now = Date()
        let delta = now.timeIntervalSince(lastActionAt)
        if delta < minimumActionInterval {
            let wait = minimumActionInterval - delta
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        lastActionAt = Date()
    }

    // MARK: - Runtime readiness
    private func ensureRuntimeReady(timeoutMs: Int) async -> Bool {
        guard let webView else { return false }
        let start = Date().timeIntervalSince1970
        let deadline = start + Double(timeoutMs) / 1000.0
        while Date().timeIntervalSince1970 < deadline {
            let script =
                "(() => { try { return !!(window.__agent && window.__agent.findElements && window.__agent.click && window.__agent.typeText); } catch(e) { return false; } })();"
            let ready = await withCheckedContinuation {
                (continuation: CheckedContinuation<Bool, Never>) in
                webView.evaluateJavaScript(script) { result, _ in
                    continuation.resume(returning: (result as? Bool) == true)
                }
            }
            if ready { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)  // 150ms
        }
        return false
    }
}
