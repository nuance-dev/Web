import AppKit
import Combine
import Foundation
import SwiftUI
import WebKit

extension NSColor {
    convenience init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64
        switch hex.count {
        case 3:  // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }

        self.init(
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            alpha: Double(a) / 255
        )
    }
}

extension NSImage {
    var isValid: Bool {
        return self.size.width > 0 && self.size.height > 0 && self.representations.count > 0
    }
}

struct WebView: NSViewRepresentable {
    @Binding var url: URL?
    @Binding var canGoBack: Bool
    @Binding var canGoForward: Bool
    @Binding var isLoading: Bool
    @Binding var estimatedProgress: Double
    @Binding var title: String?
    @Binding var favicon: NSImage?
    @Binding var hoveredLink: String?
    @Binding var mixedContentStatus: MixedContentManager.MixedContentStatus?

    let tab: Tab?
    let onNavigationAction: ((WKNavigationAction) -> WKNavigationActionPolicy)?
    let onDownloadRequest: ((URL, String?) -> Void)?

    func makeNSView(context: Context) -> NativePageContainer {
        NativePageContainer(webView: configuredWebView(coordinator: context.coordinator))
    }

    static func preload(_ tab: Tab) {
        guard let url = tab.url, NavigationResolver.isWebURL(url), !tab.isHibernated else { return }
        let view = WebView(tab: tab, hoveredLink: .constant(nil))
        let coordinator = view.makeCoordinator()
        let webView = view.configuredWebView(coordinator: coordinator)
        view.loadInitialURL(in: webView, coordinator: coordinator)
    }

    func configuredWebView(coordinator: Coordinator) -> WKWebView {
        if let existing = tab?.webView as? CustomWebView {
            coordinator.parent = self
            coordinator.webView = existing
            return existing
        }
        // Use shared WebKitManager for optimized memory usage and shared process pool
        let isIncognito = tab?.isIncognito ?? false

        // OAUTH FIX: Detect if this is for OAuth flows and configure accordingly
        let isOAuthFlow = detectOAuthFlow()
        let config = WebKitManager.shared.createConfiguration(
            isIncognito: isIncognito, isOAuthFlow: isOAuthFlow)

        // Enhanced privacy settings specific to this app (unless OAuth flow)
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        if !isOAuthFlow {
            config.preferences.javaScriptCanOpenWindowsAutomatically = false
        }

        // Developer tools are enabled via isInspectable on the WKWebView below.
        // Removed private KVC preference toggles to avoid private API usage.

        // Configure enhanced tracking prevention
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        // User agent customization - Use standard Safari user agent to prevent Google's embedded browser detection
        config.applicationNameForUserAgent = ""

        // SECURITY: Use CSP-protected script injection for all JavaScript
        if let linkHoverScript = CSPManager.shared.secureScriptInjection(
            script: linkHoverJavaScript,
            type: .linkHover,
            webView: createTemporaryWebView(with: config)
        ) {
            config.userContentController.addUserScript(linkHoverScript)
        }
        config.userContentController.add(coordinator, name: "linkHover")
        config.userContentController.add(coordinator, name: "linkContextMenu")

        // SECURITY: Inject Agent Bridge runtime (M2)
        if let agentBridgeScript = CSPManager.shared.secureScriptInjection(
            script: agentBridgeJavaScript,
            type: .agentBridge,
            webView: createTemporaryWebView(with: config)
        ) {
            config.userContentController.addUserScript(agentBridgeScript)
        }
        config.userContentController.add(coordinator, name: "agentBridge")

        // Create WebView using WebKitManager for optimal memory usage
        let safeFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let webView = CustomWebView(
            frame: safeFrame, configuration: config, coordinator: coordinator)
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator

        // CRITICAL FIX: Enable automatic resizing for window resize support
        webView.autoresizingMask = [.width, .height]
        webView.translatesAutoresizingMaskIntoConstraints = true

        // Apply standard Safari user agent to prevent Google's embedded browser detection
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        if #available(macOS 13.3, *) {
            webView.isInspectable = UserDefaults.standard.bool(forKey: "enableDeveloperTools")
        }
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        if let zoom = tab?.zoomScale, zoom.isFinite {
            webView.magnification = min(3, max(0.5, zoom))
        }

        // Configure security services after webview creation
        AdBlockService.shared.configureWebView(webView)

        // Configure incognito-specific settings if needed
        if let tab = tab, tab.isIncognito {
            IncognitoSession.shared.configureWebViewForIncognito(webView)
            // Do NOT configure autofill for incognito tabs to maintain privacy
        }

        // Configure for optimal web content including WebGL
        // Note: WebGL is enabled by default in WKWebView on macOS
        // These settings optimize the viewing experience
        webView.configuration.preferences.isElementFullscreenEnabled = true

        // Enable modern web features (JavaScript is enabled by default)
        // WebGL support is built into WebKit and doesn't require special configuration

        // Set up observers with error handling
        coordinator.setupObservers(for: webView)

        // SECURITY: Set up mixed content monitoring if tab exists
        if let tab = tab {
            // Wire up MixedContentManager (installs KVO and enforces policy)
            MixedContentManager.shared.setupMixedContentMonitoring(for: webView, tabID: tab.id)
            // Subscribe coordinator to status change notifications for UI updates
            coordinator.setupMixedContentMonitoring(for: webView, tabID: tab.id)
        }

        // Store webView reference for coordinator and tab with ownership validation
        coordinator.webView = webView
        coordinator.pageAgent = PageAgent(webView: webView)
        if let tab = tab {
            // CRITICAL: Ensure exclusive WebView ownership per tab
            if let existingWebView = tab.webView, existingWebView !== webView {
                if AppLog.isVerboseEnabled {
                    print(
                        "⚠️ WARNING: Tab \(tab.id) already has a different WebView instance. This could cause content bleeding."
                    )
                }
            }
            tab.webView = webView
        }

        return webView
    }

    func updateNSView(_ container: NativePageContainer, context: Context) {
        context.coordinator.parent = self
        loadInitialURL(in: container.webView, coordinator: context.coordinator)
    }

    private func loadInitialURL(in webView: WKWebView, coordinator: Coordinator) {
        guard let requestedURL = url,
              NavigationResolver.isWebURL(requestedURL),
              webView.url == nil, !webView.isLoading,
              coordinator.lastLoadedURL != requestedURL else { return }
        coordinator.lastLoadedURL = requestedURL
        coordinator.lastLoadTime = Date()
        webView.load(URLRequest(url: requestedURL))
    }

    func makeCoordinator() -> Coordinator {
        if let existing = (tab?.webView as? CustomWebView)?.coordinator {
            existing.parent = self
            return existing
        }
        return Coordinator(self)
    }

    // SECURITY: Helper function to create temporary WebView for CSP script injection
    private func createTemporaryWebView(with config: WKWebViewConfiguration) -> WKWebView {
        return WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: config)
    }

    // JavaScript for link hover detection and right-click context menu
    private var linkHoverJavaScript: String {
        """
        (function() {
            let statusTimeout;
            let currentContextLink = null;
            
            // Add event listeners for link hover
            document.addEventListener('mouseover', function(e) {
                if (e.target.tagName === 'A' && e.target.href) {
                    clearTimeout(statusTimeout);
                    window.webkit.messageHandlers.linkHover.postMessage({
                        type: 'hover',
                        url: e.target.href
                    });
                }
            });
            
            document.addEventListener('mouseout', function(e) {
                if (e.target.tagName === 'A' && e.target.href) {
                    statusTimeout = setTimeout(() => {
                        window.webkit.messageHandlers.linkHover.postMessage({
                            type: 'clear'
                        });
                    }, 100);
                }
            });
            
            // Handle right-click context menu on links
            document.addEventListener('contextmenu', function(e) {
                // Find if the clicked element or any parent is a link
                let target = e.target;
                let linkElement = null;
                
                // Traverse up the DOM to find a link element
                while (target && target !== document) {
                    if (target.tagName === 'A' && target.href) {
                        linkElement = target;
                        break;
                    }
                    target = target.parentElement;
                }
                
                if (linkElement) {
                    // Store current context link for potential actions
                    currentContextLink = linkElement.href;
                    
                    // Send link context to native code
                    window.webkit.messageHandlers.linkContextMenu.postMessage({
                        type: 'rightClick',
                        url: linkElement.href,
                        text: linkElement.textContent || linkElement.innerText || '',
                        x: e.clientX,
                        y: e.clientY
                    });
                } else {
                    // Clear context if not right-clicking on a link
                    currentContextLink = null;
                }
            });
            
            // Clear status bar when clicking on links
            document.addEventListener('click', function(e) {
                if (e.target.tagName === 'A' && e.target.href) {
                    clearTimeout(statusTimeout);
                    window.webkit.messageHandlers.linkHover.postMessage({
                        type: 'clear'
                    });
                }
            });
            
            // Also clear status bar on navigation start
            document.addEventListener('beforeunload', function() {
                try {
                  window.webkit.messageHandlers.linkHover.postMessage({ type: 'clear' });
                } catch (e) {}
                // Reset agent runtime markers to handle WebContent restarts
                try { window.__agentNetInstalled = false; } catch (e) {}
            });
            
            // Expose function for native code to get current context link
            window.getCurrentContextLink = function() {
                return currentContextLink;
            };
            
            // PERFORMANCE: Pause/resume expensive operations based on page visibility
            document.addEventListener('visibilitychange', function() {
                if (document.hidden) {
                    // Page is hidden - pause expensive operations
                    console.log('Page hidden - pausing expensive operations');
                } else {
                    // Page is visible - resume operations
                    console.log('Page visible - resuming operations');
                }
            });
        })();
        """
    }

    // JavaScript for Agent Bridge runtime (M2 safety additions)
    private var agentBridgeJavaScript: String {
        """
        (function() {
          'use strict';
          const CHANNEL = 'agentBridge';
          if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers[CHANNEL]) {
            console.warn('[AgentScript] agentBridge handler not available');
            return;
          }
          // Utilities
          function isVisible(el) {
            if (!el) return false;
            const rect = el.getBoundingClientRect();
            const style = window.getComputedStyle(el);
            return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
          }
          function roleFor(el) {
            const tag = (el.tagName || '').toLowerCase();
            if (el.getAttribute && el.getAttribute('role')) return el.getAttribute('role');
            if (tag === 'a') return 'link';
            if (tag === 'button') return 'button';
            if (tag === 'input') return 'input';
            if (tag === 'select') return 'select';
            if (tag === 'textarea') return 'textbox';
            return tag;
          }
          function nameFor(el) {
            return (el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('name'))) || (el.innerText || el.textContent || '').trim();
          }
          function isSensitiveInput(el) {
            try {
              const type = (el.type || '').toLowerCase();
              const name = (el.name || '').toLowerCase();
              const id = (el.id || '').toLowerCase();
              const sensitive = ['password','passcode','totp','otp','ssn','social','credit','card','cvv'];
              if (type === 'password') return true;
              return sensitive.some(k => name.includes(k) || id.includes(k));
            } catch { return false; }
          }
          function toSummary(el, idx, hint) {
            const rect = el.getBoundingClientRect();
            return {
              id: String(idx),
              role: roleFor(el),
              name: nameFor(el),
              text: (el.innerText || el.textContent || '').slice(0, 200),
              isVisible: isVisible(el),
              boundingBox: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
              locatorHint: hint || null,
            };
          }
          // Minimal overlay utilities
          let __overlayBox = null;
          function ensureOverlay() {
            if (!__overlayBox) {
              const box = document.createElement('div');
              box.style.position = 'fixed';
              box.style.zIndex = '2147483647';
              box.style.pointerEvents = 'none';
              box.style.border = '2px solid rgba(59,130,246,0.9)';
              box.style.borderRadius = '8px';
              box.style.boxShadow = '0 0 0 2px rgba(59,130,246,0.2), 0 0 12px rgba(59,130,246,0.5)';
              box.style.transition = 'all 120ms ease-out';
              box.style.opacity = '0';
              document.documentElement.appendChild(box);
              __overlayBox = box;
            }
            return __overlayBox;
          }
          function showHighlightFor(el, durationMs = 600) {
            try {
              const box = ensureOverlay();
              const r = el.getBoundingClientRect();
              box.style.left = `${Math.max(0, r.left - 4)}px`;
              box.style.top = `${Math.max(0, r.top - 4)}px`;
              box.style.width = `${Math.max(0, r.width + 8)}px`;
              box.style.height = `${Math.max(0, r.height + 8)}px`;
              box.style.opacity = '1';
              clearTimeout(box.__hideTimer);
              box.__hideTimer = setTimeout(() => { box.style.opacity = '0'; }, durationMs);
            } catch {}
          }
          function ensureBanner() {
            if (window.__agentBanner) return window.__agentBanner;
            const bar = document.createElement('div');
            bar.style.position = 'fixed';
            bar.style.left = '12px';
            bar.style.top = '12px';
            bar.style.padding = '8px 10px';
            bar.style.font = '12px -apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif';
            bar.style.color = '#0B1220';
            bar.style.background = 'rgba(191,219,254,0.9)';
            bar.style.border = '1px solid rgba(59,130,246,0.35)';
            bar.style.borderRadius = '10px';
            bar.style.boxShadow = '0 6px 24px rgba(2,6,23,0.15)';
            bar.style.zIndex = '2147483647';
            bar.style.pointerEvents = 'none';
            bar.style.opacity = '0';
            bar.style.transition = 'opacity 140ms ease-out';
            document.documentElement.appendChild(bar);
            window.__agentBanner = bar;
            return bar;
          }
          function rippleAt(x, y) {
            try {
              const dot = document.createElement('div');
              const size = 16;
              dot.style.position = 'fixed';
              dot.style.left = `${x - size/2}px`;
              dot.style.top = `${y - size/2}px`;
              dot.style.width = `${size}px`;
              dot.style.height = `${size}px`;
              dot.style.borderRadius = '999px';
              dot.style.background = 'rgba(59,130,246,0.9)';
              dot.style.zIndex = '2147483647';
              dot.style.pointerEvents = 'none';
              dot.style.opacity = '0.9';
              dot.style.transform = 'scale(0.6)';
              dot.style.transition = 'transform 250ms ease-out, opacity 300ms ease-out';
              document.documentElement.appendChild(dot);
              requestAnimationFrame(() => {
                dot.style.transform = 'scale(2.8)';
                dot.style.opacity = '0';
              });
              setTimeout(() => { dot.remove(); }, 400);
            } catch {}
          }
          // Install generic network activity tracker for idle waits (agnostic)
          (function installNetworkTracker(){
            try {
              if (window.__agentNetInstalled) return; window.__agentNetInstalled = true;
              window.__agentNet = { active: 0, lastChangeTs: Date.now() };
              const origFetch = window.fetch;
              if (typeof origFetch === 'function') {
                window.fetch = async function() {
                  try { window.__agentNet.active++; window.__agentNet.lastChangeTs = Date.now(); } catch {}
                  try { return await origFetch.apply(this, arguments); }
                  finally { try { window.__agentNet.active = Math.max(0, window.__agentNet.active - 1); window.__agentNet.lastChangeTs = Date.now(); } catch {} }
                };
              }
              const OrigXHR = window.XMLHttpRequest;
              if (OrigXHR) {
                const Wrapped = function() {
                  const xhr = new OrigXHR();
                  const dec = () => { try { window.__agentNet.active = Math.max(0, window.__agentNet.active - 1); window.__agentNet.lastChangeTs = Date.now(); } catch {};
                    xhr.removeEventListener('loadend', dec); xhr.removeEventListener('error', dec); xhr.removeEventListener('abort', dec);
                  };
                  xhr.addEventListener('loadstart', () => { try { window.__agentNet.active++; window.__agentNet.lastChangeTs = Date.now(); } catch {} });
                  xhr.addEventListener('loadend', dec);
                  xhr.addEventListener('error', dec);
                  xhr.addEventListener('abort', dec);
                  return xhr;
                };
                window.XMLHttpRequest = Wrapped;
              }
              window.__agentNetIsIdle = function(idleMs){
                try {
                  const idle = typeof idleMs === 'number' ? idleMs : 500;
                  const n = (window.__agentNet && window.__agentNet.active) || 0;
                  const last = (window.__agentNet && window.__agentNet.lastChangeTs) || 0;
                  return n === 0 && (Date.now() - last) >= idle;
                } catch { return false; }
              };
            } catch {}
          })();
          function findByLocator(locator) {
            if (!locator) return [];
            let nodes = [];
            let hint = '';
            try {
              // 1) CSS wins for determinism
              if (locator.css) {
                nodes = Array.from(document.querySelectorAll(locator.css));
                hint = locator.css;
                // No site-specific fallbacks to remain page-agnostic
              } else {
                const role = (locator.role || '').toLowerCase();
                const hasNeedle = Boolean(locator.text || locator.name);
                const needle = (locator.text || locator.name || '').toLowerCase();

                // Candidate set by role (accessible-friendly)
                let selector = 'a,button,input,select,textarea,[role],[contenteditable="true"]';
                if (role === 'textbox' || role === 'input' || role === 'searchbox') {
                  selector = 'input, textarea, [contenteditable="true"], [role="textbox"]';
                } else if (role === 'button') {
                  selector = 'button, [role="button"]';
                } else if (role === 'link') {
                  selector = 'a, [role="link"]';
                } else if (role === 'select') {
                  selector = 'select';
                } else if (role === 'article' || role === 'post') {
                  // Generic article-like containers with common readable contexts (still agnostic)
                  selector = 'article, [role="article"], main';
                }

                const candidates = Array.from(document.querySelectorAll(selector));

                function accessibleName(el) {
                  try {
                    const direct = (el.getAttribute('aria-label') || el.getAttribute('name') || el.getAttribute('title') || '').trim();
                    const placeholder = (el.getAttribute('placeholder') || '').trim();
                    // aria-labelledby support (best-effort)
                    const labelledById = el.getAttribute('aria-labelledby');
                    let labelledText = '';
                    if (labelledById) {
                      const labelEl = document.getElementById(labelledById);
                      if (labelEl) labelledText = (labelEl.innerText || labelEl.textContent || '').trim();
                    }
                    return [direct, placeholder, labelledText].filter(Boolean).join(' ').toLowerCase();
                  } catch { return ''; }
                }

                // Filter by role and needle
                nodes = candidates.filter(el => {
                  if (!isVisible(el)) return false;
                  if (role) {
                    const r = roleFor(el).toLowerCase();
                    if (role === 'textbox' && !(r === 'textbox' || r === 'input')) return false;
                    if (role === 'article' || role === 'post') {
                      const articleLike = r === 'article' || (el.matches && el.matches('[role="article"], article'));
                      if (!articleLike) return false;
                    } else if (role !== 'textbox' && r !== role) {
                      return false;
                    }
                  }
                  if (!hasNeedle) return true;
                  const inner = ((el.innerText || el.textContent || '')).toLowerCase();
                  const name = accessibleName(el);
                  return inner.includes(needle) || name.includes(needle);
                });

                // Heuristic: if role requests a textbox with no explicit needle, pick obvious search inputs first
                if (nodes.length === 0 && (role === 'textbox' || role === 'searchbox' || (!role && !hasNeedle))) {
                  const prefer = Array.from(document.querySelectorAll('input[name="q"], input[type="search"], input[type="text"]'))
                    .filter(isVisible);
                  if (prefer.length) nodes = prefer;
                }

                hint = locator.css || locator.text || locator.name || role || '';
              }

              if (typeof locator.nth === 'number' && nodes[locator.nth]) {
                return [nodes[locator.nth]];
              }
              return nodes;
            } catch (e) {
              return [];
            }
          }
          // Public API
          window.__agent = window.__agent || {};
          window.__agent.ping = function() {
            try { window.webkit.messageHandlers[CHANNEL].postMessage({ type: 'ping', ts: Date.now() }); } catch (e) {}
          };
          // Find elements by simple locator
          window.__agent.findElements = function(locator) {
            try {
              let nodes = findByLocator(locator);
              let hint = locator && (locator.css || locator.text || locator.name) || '';
              const out = nodes.slice(0, 50).map((el, i) => toSummary(el, i, hint));
              return out;
            } catch (e) {
              return [];
            }
          };
          // Best-effort cookie/consent dismiss helper (page-agnostic)
          window.__agent.dismissConsent = function() {
            try {
              const selectors = [
                'button[aria-label*="accept" i]', 'button:has([aria-label*="accept" i])',
                'button:contains("accept")', 'button:contains("agree")',
                '[role="button"][aria-label*="accept" i]'
              ];
              for (const sel of selectors) {
                const btns = Array.from(document.querySelectorAll('button,[role="button"]'));
                for (const b of btns) {
                  const text = (b.innerText || b.textContent || '').toLowerCase();
                  const name = (b.getAttribute('aria-label') || '').toLowerCase();
                  if (/accept|agree|consent/.test(text) || /accept|agree|consent/.test(name)) {
                    if (isVisible(b)) { b.click(); return { ok: true }; }
                  }
                }
              }
            } catch {}
            return { ok: false };
          };
          // Click the first matching element
          window.__agent.click = function(locator) {
            try {
              const el = (findByLocator(locator) || []).find(isVisible) || null;
              let target = el;
              const isClickable = (node) => {
                if (!node) return false;
                const tag = (node.tagName || '').toLowerCase();
                if (tag === 'a' || tag === 'button' || tag === 'input' || tag === 'summary') return true;
                const role = (node.getAttribute && node.getAttribute('role')) || '';
                if (role === 'button' || role === 'link') return true;
                return typeof node.onclick === 'function' || node.hasAttribute && node.hasAttribute('onclick');
              };
              if (target && !isClickable(target)) {
                // Prefer primary body link patterns used on content sites
                target = target.querySelector('a[data-click-id="body"], a[href], h3 a, h2 a, .title a, a[role="link"]');
                if (target && !isVisible(target)) target = null;
              }
              if (target && isVisible(target)) {
                try { target.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' }); } catch {}
                showHighlightFor(target);
                target.click();
                const r = target.getBoundingClientRect();
                rippleAt(r.left + r.width/2, r.top + r.height/2);
                return { ok: true };
              }
              return { ok: false };
            } catch (e) {
              return { ok: false };
            }
          };
          // Type into an input/textarea and optionally submit
          window.__agent.typeText = function(locator, text, submit) {
            try {
              const el = (findByLocator(locator) || []).find(isVisible) || null;
              if (!el || !isVisible(el)) return { ok: false };
              if (el.tagName && el.tagName.toLowerCase() === 'input' || el.tagName && el.tagName.toLowerCase() === 'textarea' || el.isContentEditable) {
                // Safety: never type into sensitive fields by default
                if (isSensitiveInput(el)) { return { ok: false }; }
                showHighlightFor(el, 800);
                el.focus();
                if (el.value !== undefined) {
                  el.value = text;
                  el.dispatchEvent(new Event('input', { bubbles: true }));
                  el.dispatchEvent(new Event('change', { bubbles: true }));
                } else if (el.isContentEditable) {
                  el.textContent = text;
                  el.dispatchEvent(new Event('input', { bubbles: true }));
                }
                if (submit) {
                  // Try to submit closest form
                  const form = el.form || el.closest('form');
                  if (form) form.requestSubmit ? form.requestSubmit() : form.submit();
                }
                return { ok: true };
              }
              return { ok: false };
            } catch (e) { return { ok: false }; }
          };
          // Select value in a <select>
          window.__agent.select = function(locator, value) {
            try {
              const el = (findByLocator(locator) || []).find(isVisible) || null;
              if (!el || el.tagName.toLowerCase() !== 'select') return { ok: false };
              showHighlightFor(el, 800);
              el.value = value;
              el.dispatchEvent(new Event('input', { bubbles: true }));
              el.dispatchEvent(new Event('change', { bubbles: true }));
              return { ok: true };
            } catch (e) { return { ok: false }; }
          };
          // Scroll behavior: to target or window by direction/amount
          window.__agent.scroll = function(locator, direction, amountPx) {
            try {
              const amt = typeof amountPx === 'number' ? amountPx : 600;
              const dir = (direction || 'down').toLowerCase();
              const el = locator ? (findByLocator(locator) || [])[0] : null;
              const target = el || window;
              const dx = 0;
              const dy = dir === 'down' ? amt : dir === 'up' ? -amt : amt;
              if (target === window) {
                window.scrollBy({ left: dx, top: dy, behavior: 'smooth' });
              } else {
                target.scrollBy({ left: dx, top: dy, behavior: 'smooth' });
              }
              return { ok: true };
            } catch (e) { return { ok: false }; }
          };
          // Wait for predicate: readyState complete, selector presence, or delay
          // Then additionally wait for short network-idle window if tracker is installed
          window.__agent.waitFor = async function(predicate, timeoutMs) {
            const start = Date.now();
            const timeout = typeof timeoutMs === 'number' ? timeoutMs : 5000;
            const sleep = (ms) => new Promise(r => setTimeout(r, ms));
            const waitIdle = async () => {
              try {
                const idleBudget = Math.min(1500, Math.max(300, timeout));
                const deadline = Date.now() + idleBudget;
                while (Date.now() < deadline) {
                  if (window.__agentNetIsIdle && window.__agentNetIsIdle(450)) return true;
                  await sleep(50);
                }
              } catch {}
              return true;
            };
            try {
              if (predicate && predicate.readyState === 'complete') {
                while (document.readyState !== 'complete') {
                  if (Date.now() - start > timeout) return { ok: false };
                  await sleep(100);
                }
                await waitIdle();
                return { ok: true };
              }
              if (predicate && predicate.selector) {
                while (true) {
                  const node = document.querySelector(predicate.selector);
                  if (node && isVisible(node)) { await waitIdle(); return { ok: true }; }
                  if (Date.now() - start > timeout) return { ok: false };
                  await sleep(100);
                }
              }
              if (predicate && typeof predicate.delayMs === 'number') {
                await sleep(Math.min(predicate.delayMs, timeout));
                await waitIdle();
                return { ok: true };
              }
            } catch (e) { /* fallthrough */ }
            return { ok: false };
          };
          // Overlay helpers exposed to native
          window.__agent.overlayHighlight = function(locator, durationMs) {
            try {
              const el = (findByLocator(locator) || []).find(isVisible) || null;
              if (el) { showHighlightFor(el, durationMs || 800); return { ok: true }; }
            } catch {}
            return { ok: false };
          };
          window.__agent.overlayHighlightByCss = function(css, durationMs) {
            try {
              const el = document.querySelector(css);
              if (el && isVisible(el)) { showHighlightFor(el, durationMs || 800); return { ok: true }; }
            } catch {}
            return { ok: false };
          };
          window.__agent.overlayClear = function() {
            try { if (__overlayBox) { __overlayBox.style.opacity = '0'; } return { ok: true }; } catch { return { ok: false }; }
          };
          window.__agent.banner = function(text, durationMs) {
            try {
              const bar = ensureBanner();
              bar.textContent = String(text || '');
              bar.style.opacity = '1';
              clearTimeout(bar.__hideTimer);
              bar.__hideTimer = setTimeout(() => { bar.style.opacity = '0'; }, Math.min(Math.max(durationMs || 1200, 600), 4000));
              return { ok: true };
            } catch { return { ok: false }; }
          };
          try { window.webkit.messageHandlers[CHANNEL].postMessage({ type: 'runtime_ready', version: 'm2' }); } catch (e) {}
        })();
        """
    }

    // MARK: - OAuth Detection

    /// Detects if the current URL or intended navigation is for OAuth flows
    /// - Returns: true if this WebView is being used for OAuth authentication
    private func detectOAuthFlow() -> Bool {
        // Check current URL first
        if let currentURL = url {
            if isOAuthURL(currentURL) {
                if AppLog.isVerboseEnabled {
                    AppLog.debug("OAuth flow (current URL): \(currentURL.host ?? "unknown")")
                }
                return true
            }
        }

        // Check tab's URL if available
        if let tabURL = tab?.url {
            if isOAuthURL(tabURL) {
                if AppLog.isVerboseEnabled {
                    AppLog.debug("OAuth flow (tab URL): \(tabURL.host ?? "unknown")")
                }
                return true
            }
        }

        return false
    }

    /// Checks if a URL is from a known OAuth provider or contains OAuth-related paths
    /// - Parameter url: URL to check
    /// - Returns: true if the URL is OAuth-related
    private func isOAuthURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()

        // Known OAuth provider domains
        let oauthDomains = [
            "accounts.google.com",
            "oauth2.googleapis.com",
            "github.com",
            "login.microsoftonline.com",
            "login.live.com",
            "www.facebook.com",
            "api.twitter.com",
            "discord.com",
            "slack.com",
            "appleid.apple.com",
        ]

        // Check exact domain matches
        if oauthDomains.contains(host) {
            return true
        }

        // Check subdomain matches (e.g., subdomain.accounts.google.com)
        for domain in oauthDomains {
            if host.hasSuffix(".\(domain)") {
                return true
            }
        }

        // Check OAuth-related paths on any domain
        let oauthPaths = [
            "/oauth",
            "/auth",
            "/login/oauth",
            "/oauth2",
            "/connect/oauth",
            "/api/oauth",
            "/_oauth",
            "/sso",
            "/saml",
        ]

        for oauthPath in oauthPaths {
            if path.contains(oauthPath) {
                return true
            }
        }

        // Check query parameters for OAuth indicators
        if let query = url.query?.lowercased() {
            let oauthParams = [
                "client_id", "redirect_uri", "response_type", "oauth_token", "code_challenge",
            ]
            for param in oauthParams {
                if query.contains(param) {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Custom WKWebView for Context Menu Support
    class CustomWebView: WKWebView {
        weak var coordinator: Coordinator?

        init(frame: CGRect, configuration: WKWebViewConfiguration, coordinator: Coordinator?) {
            self.coordinator = coordinator
            super.init(frame: frame, configuration: configuration)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private struct LinkMenuTarget {
            let url: URL
            let sourceURL: URL
            let sourceTabID: UUID
            let documentRevision: UInt64
        }

        override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
            super.willOpenMenu(menu, with: event)
            QuoteAction.addMenuItem(to: menu, for: self, documentRevision: { [weak coordinator] in
                coordinator?.documentRevision
            })
            guard let sourceURL = url, NavigationResolver.isWebURL(sourceURL),
                  let coordinator, let sourceTabID = coordinator.parent.tab?.id else { return }
            let revision = coordinator.documentRevision
            let localPoint = convert(event.locationInWindow, from: nil)
            let scale = max(magnification, 0.01)
            let x = localPoint.x / scale
            let y = (isFlipped ? localPoint.y : bounds.height - localPoint.y) / scale
            guard x.isFinite, y.isFinite else { return }
            let script = """
                (() => {
                    const element = document.elementFromPoint(\(x), \(y));
                    const link = element?.closest('a[href]');
                    return link?.href ?? null;
                })()
                """
            // Read the actual clicked anchor, not a prior page message or hover target.
            evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self, weak menu] result in
                guard let self, let menu,
                      self.url == sourceURL,
                      self.coordinator?.documentRevision == revision,
                      self.coordinator?.parent.tab?.id == sourceTabID,
                      case .success(let value) = result,
                      let address = value as? String,
                      let linkURL = URL(string: address), NavigationResolver.isWebURL(linkURL)
                else { return }
                let target = LinkMenuTarget(url: linkURL, sourceURL: sourceURL,
                                           sourceTabID: sourceTabID, documentRevision: revision)
                let insertIndex = menu.items.firstIndex {
                    $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink"
                }.map { $0 + 1 } ?? 0
                let glance = NSMenuItem(title: "Open in Glance", action: #selector(self.openInGlance(_:)), keyEquivalent: "")
                glance.target = self
                glance.identifier = NSUserInterfaceItemIdentifier("WebOpenLinkInGlance")
                glance.representedObject = target
                let newTab = NSMenuItem(title: "Open in New Tab", action: #selector(self.openInNewTab(_:)), keyEquivalent: "")
                newTab.target = self
                newTab.identifier = NSUserInterfaceItemIdentifier("WebOpenLinkInNewTab")
                newTab.representedObject = target
                for identifier in [glance.identifier, newTab.identifier] {
                    if let oldItem = menu.items.first(where: { $0.identifier == identifier }) {
                        menu.removeItem(oldItem)
                    }
                }
                let position = min(insertIndex, menu.numberOfItems)
                menu.insertItem(glance, at: position)
                menu.insertItem(newTab, at: position + 1)
                menu.update()
            }
        }

        private func linkTarget(_ sender: NSMenuItem) -> LinkMenuTarget? {
            guard let target = sender.representedObject as? LinkMenuTarget,
                  NavigationResolver.isWebURL(target.url),
                  url == target.sourceURL,
                  coordinator?.documentRevision == target.documentRevision,
                  coordinator?.parent.tab?.id == target.sourceTabID else { return nil }
            return target
        }

        @objc private func openInGlance(_ sender: NSMenuItem) {
            guard let target = linkTarget(sender), let window,
                  let sourceTab = coordinator?.parent.tab else { return }
            PeekController.shared.open(target.url, from: window, isPrivate: sourceTab.isIncognito)
        }

        @objc private func openInNewTab(_ sender: NSMenuItem) {
            guard let target = linkTarget(sender), let sourceTab = coordinator?.parent.tab else { return }
            NotificationCenter.default.post(
                name: .newTabInBackgroundRequested,
                object: nil,
                userInfo: ["url": target.url, "sourceTabID": target.sourceTabID,
                           "isIncognito": sourceTab.isIncognito]
            )
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var parent: WebView
        weak var webView: WKWebView?
        private var progressObserver: NSKeyValueObservation?
        private var titleObserver: NSKeyValueObservation?
        private var magnificationObserver: NSKeyValueObservation?
        private var urlObserver: NSKeyValueObservation?
        private var mixedContentObserver: NSKeyValueObservation?
        var lastLoadedURL: URL?
        var lastLoadTime: Date?

        // Changes on every provisional navigation, including same-URL reloads.
        var documentRevision: UInt64 = 0

        // Context menu state
        var rightClickedLinkURL: String?

        // Agent runtime state
        var agentRuntimeReady: Bool = false
        var pageAgent: PageAgent?

        // Mixed content monitoring state
        private var mixedContentNotificationObserver: AnyCancellable?

        // Certificate validation state
        private var pendingChallenges: [URLAuthenticationChallenge] = []
        private var certificateNotificationObserver: AnyCancellable?

        // Network error handling and circuit breaker
        private let circuitBreaker = NetworkConnectivityMonitor.CircuitBreakerState()
        private var currentNetworkError: Error?
        private var isShowingNoInternetPage = false

        // Static shared cache to prevent duplicate downloads across all tabs
        private static var faviconCache: [String: NSImage] = [:]
        private static var faviconDownloadTasks: Set<String> = []
        private static let cacheQueue = DispatchQueue(
            label: "favicon.cache", attributes: .concurrent)
        private static let maxCacheSize = 50  // Reduced cache size to prevent memory issues
        private static var cacheAccessOrder: [String] = []  // LRU tracking

        init(_ parent: WebView) {
            self.parent = parent
            super.init()
            setupCertificateNotificationObservers()
            // AI RESPONSIVENESS FIX: Initialize responsiveness protection
            protectWebViewResponsiveness()
        }

        private func setupCertificateNotificationObservers() {
            // Handle user responses to certificate security warnings
            certificateNotificationObserver = NotificationCenter.default.publisher(
                for: .userGrantedCertificateException
            )
            .sink { [weak self] notification in
                self?.handleCertificateExceptionGranted(notification)
            }
        }

        private func handleCertificateExceptionGranted(_ notification: Notification) {
            guard
                let challenge = notification.userInfo?["challenge"] as? URLAuthenticationChallenge,
                let host = notification.userInfo?["host"] as? String,
                let port = notification.userInfo?["port"] as? Int
            else {
                return
            }

            // Remove from pending challenges and retry with exception
            if let index = pendingChallenges.firstIndex(where: {
                $0.protectionSpace.host == host && $0.protectionSpace.port == port
            }) {
                let pendingChallenge = pendingChallenges.remove(at: index)

                // Retry validation with exception now granted
                let (disposition, credential) = CertificateManager.shared.validateChallenge(
                    pendingChallenge)

                // This should now succeed because the exception was granted
                // Note: In practice, we'd need to store the completion handler and call it here
                // For now, we'll trigger a reload to retry the navigation
                DispatchQueue.main.async { [weak self] in
                    self?.webView?.reload()
                }
            }
        }

        func setupObservers(for webView: WKWebView) {
            magnificationObserver = webView.observe(\.magnification, options: .new) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    guard let tab = self?.parent.tab, tab.webView === webView else { return }
                    tab.zoomScale = webView.magnification
                }
            }
            progressObserver = webView.observe(\.estimatedProgress, options: .new) {
                [weak self] webView, _ in
                DispatchQueue.main.async {
                    let progress = webView.estimatedProgress

                    // Use safe progress conversion to prevent crashes
                    self?.parent.estimatedProgress = SafeNumericConversions.safeProgress(progress)

                    // Update URLSynchronizer with progress changes for consistent state
                    if let tab = self?.parent.tab {
                        URLSynchronizer.shared.updateFromWebViewNavigation(
                            url: webView.url,
                            title: webView.title,
                            isLoading: webView.isLoading,
                            progress: progress,
                            tabID: tab.id
                        )
                    }
                }
            }

            // SECURITY: Mixed content monitoring observer
            mixedContentObserver = webView.observe(\.hasOnlySecureContent, options: [.new, .old]) {
                [weak self] webView, change in
                DispatchQueue.main.async {
                    self?.handleMixedContentStatusChange(webView: webView)
                }
            }

            titleObserver = webView.observe(\.title, options: .new) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    self?.parent.title = webView.title

                    // Update URLSynchronizer when title changes for better URL bar display
                    if let tab = self?.parent.tab {
                        URLSynchronizer.shared.updateFromWebViewNavigation(
                            url: webView.url,
                            title: webView.title,
                            isLoading: webView.isLoading,
                            progress: webView.estimatedProgress,
                            tabID: tab.id
                        )
                    }
                }
            }

            urlObserver = webView.observe(\.url, options: .new) { [weak self] webView, _ in
                DispatchQueue.main.async {
                    if let url = webView.url {
                        self?.parent.url = url
                        if let tab = self?.parent.tab {
                            tab.url = url
                            // Update URLSynchronizer immediately for consistent URL display
                            URLSynchronizer.shared.updateFromWebViewNavigation(
                                url: url,
                                title: webView.title,
                                isLoading: webView.isLoading,
                                progress: webView.estimatedProgress,
                                tabID: tab.id
                            )
                        }
                    }
                }
            }
        }

        // MARK: - Mixed Content Monitoring

        func setupMixedContentMonitoring(for webView: WKWebView, tabID: UUID) {
            // Set up mixed content status change notifications
            mixedContentNotificationObserver = NotificationCenter.default.publisher(
                for: .mixedContentStatusChanged
            )
            .sink { [weak self] notification in
                if let notificationTabID = notification.object as? UUID,
                    notificationTabID == tabID,
                    let status = notification.userInfo?["status"]
                        as? MixedContentManager.MixedContentStatus
                {
                    DispatchQueue.main.async {
                        self?.parent.mixedContentStatus = status
                    }
                }
            }

            if AppLog.isVerboseEnabled {
                AppLog.debug("Mixed content monitoring enabled for tab \(tabID)")
            }
        }

        private func handleMixedContentStatusChange(webView: WKWebView) {
            guard let tab = parent.tab else { return }

            // Check mixed content status using MixedContentManager
            let status = MixedContentManager.shared.checkMixedContentStatus(
                for: webView, tabID: tab.id)

            // Update parent binding
            parent.mixedContentStatus = status

            // Log security event if mixed content detected
            if status.mixedContentDetected {
                AppLog.warn(
                    "Mixed content detected on \(status.url?.host ?? "unknown") - secure=\(status.hasOnlySecureContent)"
                )
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!)
        {
            documentRevision &+= 1
            parent.tab?.themeColor = nil
            parent.isLoading = true
            parent.tab?.notifyLoadingStateChanged()

            // Update URLSynchronizer with loading state
            if let tab = parent.tab {
                URLSynchronizer.shared.updateFromWebViewNavigation(
                    url: webView.url,
                    title: webView.title,
                    isLoading: true,
                    progress: webView.estimatedProgress,
                    tabID: tab.id
                )
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // CRITICAL: Update URL immediately when navigation commits (highest priority for URL bar updates)
            if let url = webView.url {
                DispatchQueue.main.async {
                    self.parent.url = url
                    if let tab = self.parent.tab {
                        tab.url = url
                        // Immediate URLSynchronizer update for instant URL bar display
                        URLSynchronizer.shared.updateFromWebViewNavigation(
                            url: url,
                            title: webView.title,
                            isLoading: webView.isLoading,
                            progress: webView.estimatedProgress,
                            tabID: tab.id
                        )
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            refreshThemeColor(from: webView)
            parent.isLoading = false
            parent.title = webView.title
            parent.canGoBack = webView.canGoBack
            parent.canGoForward = webView.canGoForward
            parent.tab?.notifyLoadingStateChanged()

            // SECURITY: Check mixed content status after navigation completes
            if let tab = parent.tab {
                let mixedContentStatus = MixedContentManager.shared.checkMixedContentStatus(
                    for: webView, tabID: tab.id)
                DispatchQueue.main.async {
                    self.parent.mixedContentStatus = mixedContentStatus
                }
            }

            // Reset network error state on successful navigation
            currentNetworkError = nil
            isShowingNoInternetPage = false
            circuitBreaker.recordSuccess()

            // Final URLSynchronizer update with completed navigation state
            if let tab = parent.tab {
                tab.restoreState(to: webView)
                URLSynchronizer.shared.updateFromWebViewNavigation(
                    url: webView.url,
                    title: webView.title,
                    isLoading: false,
                    progress: 1.0,
                    tabID: tab.id
                )
            }

            // Record visit for Autofill history and browser history (only for non-incognito tabs)
            if let url = webView.url, parent.tab?.isIncognito != true {
                let title = webView.title ?? url.absoluteString
                AutofillService.shared.recordVisit(url: url.absoluteString, title: title)
                HistoryService.shared.recordVisit(url: url.absoluteString, title: webView.title)
            }

            // Only extract favicon if we don't have one for this domain
            if parent.tab?.isActive == true, parent.tab?.isIncognito != true,
                let currentURL = webView.url, let host = currentURL.host {
                Self.cacheQueue.sync {

                    let hasCachedFavicon = Self.faviconCache[host] != nil
                    let isDownloading = Self.faviconDownloadTasks.contains(host)

                    if !hasCachedFavicon && !isDownloading {
                        Self.faviconDownloadTasks.insert(host)  // Mark as downloading immediately

                        // Extract favicon with delay to ensure page is fully loaded
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.extractFavicon(from: webView, websiteHost: host)
                        }
                    } else if let cachedFavicon = Self.faviconCache[host] {
                        // Update LRU access order
                        Self.cacheAccessOrder.removeAll { $0 == host }
                        Self.cacheAccessOrder.append(host)

                        // Use cached favicon
                        DispatchQueue.main.async {
                            self.parent.favicon = cachedFavicon
                            if let tab = self.parent.tab {
                                tab.favicon = cachedFavicon
                            }
                        }
                    }
                }
            }

            // ENHANCED AUTO-READ: Intelligent content extraction with adaptive timing
            // This provides comprehensive page content without user intervention
            if parent.tab?.isIncognito != true,
                let currentURL = webView.url,
                let scheme = currentURL.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            {

                // Use adaptive timing system instead of fixed delay
                Task {
                    if let tab = self.parent.tab {
                        await self.performAdaptiveContentExtraction(webView: webView, tab: tab)
                    }
                }
            } else {
                // For non-HTTP/HTTPS pages, still notify navigation completion
                NotificationCenter.default.post(
                    name: .pageNavigationCompleted,
                    object: parent.tab?.id
                )
            }
        }

        // CRITICAL FIX: Enhanced WebContent process termination handler with network awareness
        // and circuit breaker pattern to prevent infinite reload loops when offline.
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            AppLog.warn("WebContent process terminated")

            // Check if we have a URL to reload
            guard webView.url != nil else {
                if AppLog.isVerboseEnabled {
                    AppLog.debug("WebContent terminated but no URL to reload")
                }
                return
            }

            // CRITICAL: Check network connectivity before attempting reload
            let networkMonitor = NetworkConnectivityMonitor.shared
            guard networkMonitor.hasInternetConnection else {
                AppLog.warn("WebContent terminated, offline – showing offline page")
                showNoInternetConnectionPage()
                return
            }

            // Check circuit breaker to prevent infinite reload loops
            guard circuitBreaker.canAttemptRequest() else {
                AppLog.warn("Circuit breaker open - not reloading after termination")
                showNoInternetConnectionPage()
                return
            }

            // Only reload if we have connectivity and circuit breaker allows it
            if AppLog.isVerboseEnabled {
                AppLog.debug("WebContent terminated – reloading (network ok, breaker closed)")
            }

            // Add slight delay to prevent immediate re-termination
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                webView.reload()

                // Monitor the reload attempt
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    // If still loading after 5 seconds and we have network issues, consider it a failure
                    if webView.isLoading && !NetworkConnectivityMonitor.shared.hasInternetConnection
                    {
                        self?.circuitBreaker.recordFailure()
                        self?.showNoInternetConnectionPage()
                    }
                }
            }
        }

        // Show the no internet connection page when network issues are detected
        private func showNoInternetConnectionPage() {
            guard !isShowingNoInternetPage else { return }

            isShowingNoInternetPage = true
            circuitBreaker.recordFailure()

            DispatchQueue.main.async { [weak self] in
                // Create and show the no internet page
                NotificationCenter.default.post(
                    name: .showNoInternetConnection,
                    object: self?.parent.tab?.id,
                    userInfo: [
                        "error": self?.currentNetworkError as Any,
                        "url": self?.parent.url as Any,
                    ]
                )
            }
        }

        func webView(
            _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            let nsError = error as NSError
            let networkMonitor = NetworkConnectivityMonitor.shared

            // Classify the error type for appropriate handling
            let errorType = networkMonitor.classifyError(error)
            let isNetworkError = networkMonitor.isNetworkError(error)

            NSLog(
                "Web navigation failed (domain: \(nsError.domain), code: \(nsError.code))"
            )

            parent.isLoading = false
            parent.tab?.notifyLoadingStateChanged()
            currentNetworkError = error

            // Update URLSynchronizer with error state
            if let tab = parent.tab {
                URLSynchronizer.shared.updateFromWebViewNavigation(
                    url: webView.url,
                    title: webView.title,
                    isLoading: false,
                    progress: 0.0,
                    tabID: tab.id
                )
            }

            // Handle network errors specifically
            if isNetworkError {
                circuitBreaker.recordFailure()

                // Show no internet page for network connectivity issues
                if errorType == .networkUnavailable || !networkMonitor.hasInternetConnection {
                    showNoInternetConnectionPage()
                }
            } else {
                // For non-network errors, reset circuit breaker on successful connectivity
                if networkMonitor.hasInternetConnection {
                    circuitBreaker.recordSuccess()
                    isShowingNoInternetPage = false
                }
            }
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            let nsError = error as NSError
            let errorCode = nsError.code
            let networkMonitor = NetworkConnectivityMonitor.shared

            // Don't process NSURLErrorCancelled (-999) as it's expected behavior
            guard errorCode != NSURLErrorCancelled else {
                parent.isLoading = false
                parent.tab?.notifyLoadingStateChanged()
                return
            }

            // Classify the error type for appropriate handling
            let errorType = networkMonitor.classifyError(error)
            let isNetworkError = networkMonitor.isNetworkError(error)

            NSLog(
                "Web navigation could not start (domain: \(nsError.domain), code: \(errorCode))"
            )

            parent.isLoading = false
            parent.tab?.notifyLoadingStateChanged()
            currentNetworkError = error

            // Update URLSynchronizer with error state
            if let tab = parent.tab {
                URLSynchronizer.shared.updateFromWebViewNavigation(
                    url: webView.url,
                    title: webView.title,
                    isLoading: false,
                    progress: 0.0,
                    tabID: tab.id
                )
            }

            // Handle network errors specifically - provisional navigation failures are often network-related
            if isNetworkError {
                circuitBreaker.recordFailure()

                // Show no internet page for network connectivity issues
                if errorType == .networkUnavailable || !networkMonitor.hasInternetConnection {
                    showNoInternetConnectionPage()
                } else if errorType == .timeout || errorType == .dnsFailure {
                    // For timeouts and DNS failures, show no internet page if we detect no connectivity
                    if !networkMonitor.hasInternetConnection {
                        showNoInternetConnectionPage()
                    }
                }
            } else {
                // For non-network errors, reset circuit breaker if we have good connectivity
                if networkMonitor.hasInternetConnection {
                    circuitBreaker.recordSuccess()
                    isShowingNoInternetPage = false
                }
            }
        }

        private func extractFavicon(from webView: WKWebView, websiteHost: String) {
            let script = """
                function getFavicon() {
                    try {
                        // Get favicon with comprehensive preference order - improved selectors
                        var faviconSelectors = [
                            'link[rel="icon"][sizes="32x32"]',
                            'link[rel="icon"][sizes="16x16"]',
                            'link[rel="shortcut icon"]',
                            'link[rel="icon"]',
                            'link[rel="apple-touch-icon"][sizes="180x180"]',
                            'link[rel="apple-touch-icon"][sizes="152x152"]',
                            'link[rel="apple-touch-icon"]',
                            'link[rel="apple-touch-icon-precomposed"]',
                            'link[rel="mask-icon"]'
                        ];
                        
                        var faviconURL = null;
                        var foundElements = [];
                        
                        // Debug: collect all found elements
                        for (var i = 0; i < faviconSelectors.length; i++) {
                            var favicon = document.querySelector(faviconSelectors[i]);
                            if (favicon && favicon.href) {
                                foundElements.push({
                                    selector: faviconSelectors[i],
                                    href: favicon.href,
                                    sizes: favicon.getAttribute('sizes')
                                });
                                if (!faviconURL) {
                                    faviconURL = favicon.href;
                                }
                            }
                        }
                        
                        // Convert relative URLs to absolute
                        if (faviconURL && !faviconURL.startsWith('http')) {
                            if (faviconURL.startsWith('//')) {
                                faviconURL = window.location.protocol + faviconURL;
                            } else if (faviconURL.startsWith('/')) {
                                faviconURL = window.location.origin + faviconURL;
                            } else {
                                faviconURL = window.location.origin + '/' + faviconURL;
                            }
                        }
                        
                        // If no favicon found, try default locations
                        if (!faviconURL) {
                            faviconURL = window.location.origin + '/favicon.ico';
                        }
                        
                        return {
                            favicon: faviconURL,
                            success: true,
                            debug: {
                                foundElements: foundElements,
                                finalURL: faviconURL,
                                origin: window.location.origin
                            }
                        };
                    } catch (e) {
                        return {
                            favicon: window.location.origin + '/favicon.ico',
                            success: false,
                            error: e.toString()
                        };
                    }
                }
                getFavicon();
                """

            webView.evaluateJavaScript(script) { [weak self] result, error in
                if let error = error {
                    NSLog("Site icon extraction failed (domain: \((error as NSError).domain), code: \((error as NSError).code))")
                    // Try fallback immediately
                    let fallbackURL = URL(string: "https://\(websiteHost)/favicon.ico")
                    if let fallback = fallbackURL {
                        self?.downloadFavicon(from: fallback, websiteHost: websiteHost)
                    }
                    return
                }

                if let data = result as? [String: Any] {
                    if let faviconURL = data["favicon"] as? String,
                        let url = URL(string: faviconURL)
                    {
                        self?.downloadFavicon(from: url, websiteHost: websiteHost)
                    } else {
                        // Fallback: try to get favicon from website domain
                        let fallbackURL = URL(string: "https://\(websiteHost)/favicon.ico")
                        if let fallback = fallbackURL {
                            self?.downloadFavicon(from: fallback, websiteHost: websiteHost)
                        }
                    }
                }
            }
        }

        private func downloadFavicon(from url: URL, websiteHost: String) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                defer {
                    // Always remove from download tasks when done using website host
                    Self.cacheQueue.async(flags: .barrier) {
                        Self.faviconDownloadTasks.remove(websiteHost)
                    }
                }

                if let error = error {
                    NSLog("Site icon download failed (domain: \((error as NSError).domain), code: \((error as NSError).code))")
                    // If favicon download fails, try alternative fallbacks
                    self?.tryFaviconFallbacks(websiteHost: websiteHost)
                    return
                }

                guard let data = data else {
                    self?.tryFaviconFallbacks(websiteHost: websiteHost)
                    return
                }

                // Validate that we got a proper image
                if let image = NSImage(data: data), image.isValid {
                    // Cache the favicon using website host as key with LRU eviction
                    Self.cacheQueue.async(flags: .barrier) {
                        // Clean cache using LRU if it gets too large
                        if Self.faviconCache.count >= Self.maxCacheSize {
                            let removeCount = Self.faviconCache.count - Self.maxCacheSize + 10
                            let keysToRemove = Array(Self.cacheAccessOrder.prefix(removeCount))
                            for key in keysToRemove {
                                Self.faviconCache.removeValue(forKey: key)
                                Self.cacheAccessOrder.removeAll { $0 == key }
                            }
                        }

                        // Update cache and access order
                        Self.faviconCache[websiteHost] = image
                        Self.cacheAccessOrder.removeAll { $0 == websiteHost }
                        Self.cacheAccessOrder.append(websiteHost)
                    }

                    DispatchQueue.main.async {
                        self?.parent.favicon = image
                        // Also update the tab model
                        if let tab = self?.parent.tab {
                            tab.favicon = image
                        }
                    }
                } else {
                    // Data was not a valid image, try fallbacks
                    self?.tryFaviconFallbacks(websiteHost: websiteHost)
                }
            }.resume()
        }

        private func tryFaviconFallbacks(websiteHost: String) {
            let fallbackURLs = [
                "https://\(websiteHost)/apple-touch-icon.png",
                "https://\(websiteHost)/favicon.png",
                "https://\(websiteHost)/favicon.gif",
                "https://www.google.com/s2/favicons?domain=\(websiteHost)&sz=32",  // Google favicon service as last resort
            ]
            tryFaviconURL(from: fallbackURLs, index: 0, websiteHost: websiteHost)
        }

        private func tryFaviconURL(from urls: [String], index: Int, websiteHost: String) {
            guard index < urls.count, let url = URL(string: urls[index]) else {
                return
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                forHTTPHeaderField: "User-Agent")

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in

                defer {
                    // Remove from download tasks when fallback completes using website host
                    Self.cacheQueue.async(flags: .barrier) {
                        Self.faviconDownloadTasks.remove(websiteHost)
                    }
                }

                if let error = error {
                    NSLog("Site icon fallback failed (domain: \((error as NSError).domain), code: \((error as NSError).code))")
                } else if let data = data,
                    let image = NSImage(data: data),
                    image.isValid
                {
                    // Cache the favicon using website host as key with LRU eviction
                    Self.cacheQueue.async(flags: .barrier) {
                        // Clean cache using LRU if it gets too large
                        if Self.faviconCache.count >= Self.maxCacheSize {
                            let removeCount = Self.faviconCache.count - Self.maxCacheSize + 10
                            let keysToRemove = Array(Self.cacheAccessOrder.prefix(removeCount))
                            for key in keysToRemove {
                                Self.faviconCache.removeValue(forKey: key)
                                Self.cacheAccessOrder.removeAll { $0 == key }
                            }
                        }

                        // Update cache and access order
                        Self.faviconCache[websiteHost] = image
                        Self.cacheAccessOrder.removeAll { $0 == websiteHost }
                        Self.cacheAccessOrder.append(websiteHost)
                    }

                    DispatchQueue.main.async {
                        self?.parent.favicon = image
                        if let tab = self?.parent.tab {
                            tab.favicon = image
                        }
                    }
                    return  // Success, don't try more fallbacks
                }

                // Try next fallback
                if index + 1 < urls.count {
                    self?.tryFaviconURL(from: urls, index: index + 1, websiteHost: websiteHost)
                }
            }.resume()
        }

        private func refreshThemeColor(from webView: WKWebView) {
            guard let sourceURL = webView.url, NavigationResolver.isWebURL(sourceURL),
                  let tab = parent.tab else { return }
            let revision = documentRevision
            webView.evaluateJavaScript(PageThemeColor.script, in: nil, in: .defaultClient) {
                [weak self, weak webView, weak tab] result in
                guard let self, let webView, let tab,
                      self.documentRevision == revision, webView.url == sourceURL,
                      self.parent.tab === tab else { return }
                if case .success(let pixels) = result {
                    tab.themeColor = PageThemeColor.color(from: pixels)
                } else {
                    tab.themeColor = nil
                }
            }
        }

        // MARK: - Navigation policy handling
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {

            // Check for CMD + click to open links in new background tabs
            if navigationAction.navigationType == .linkActivated,
                !navigationAction.shouldPerformDownload,
                (navigationAction.modifierFlags.contains(.command) || navigationAction.buttonNumber == 2),
                let targetURL = navigationAction.request.url,
                NavigationResolver.isWebURL(targetURL),
                let sourceTab = parent.tab
            {
                let sourceTabID = sourceTab.id
                let isIncognito = sourceTab.isIncognito

                // Create new tab in background using NotificationCenter
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("newTabInBackgroundRequested"),
                        object: nil,
                        userInfo: ["url": targetURL, "sourceTabID": sourceTabID, "isIncognito": isIncognito,
                            "activate": BrowserLinkDisposition.opensForeground(modifiers: navigationAction.modifierFlags,
                                buttonNumber: navigationAction.buttonNumber)]
                    )
                }

                // Cancel navigation in current tab
                decisionHandler(.cancel)
                return
            }

            // SECURITY: Safe Browsing threat detection for navigation requests
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            // Skip Safe Browsing checks for local/internal URLs
            if shouldSkipSafeBrowsingCheck(for: url) {
                decisionHandler(allowedNavigationPolicy(for: navigationAction))
                return
            }

            // Perform asynchronous Safe Browsing check
            performSafeBrowsingCheck(
                for: url, navigationAction: navigationAction, decisionHandler: decisionHandler)
        }

        // MARK: - Safe Browsing Integration

        private func allowedNavigationPolicy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
            let policy = parent.onNavigationAction?(action) ?? .allow
            guard policy == .allow, action.shouldPerformDownload else { return policy }
            guard let url = action.request.url, NavigationResolver.isWebURL(url) else { return .cancel }
            return .download
        }

        private func shouldSkipSafeBrowsingCheck(for url: URL) -> Bool {
            guard let scheme = url.scheme?.lowercased() else { return true }

            // Skip for non-web schemes
            if !["http", "https"].contains(scheme) {
                return true
            }

            // Skip for localhost and development domains
            if let host = url.host?.lowercased() {
                let developmentHosts = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]
                if developmentHosts.contains(host) || host.hasSuffix(".local") {
                    return true
                }
            }

            return false
        }

        private func performSafeBrowsingCheck(
            for url: URL,
            navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Perform Safe Browsing check asynchronously to avoid blocking navigation
            Task { @MainActor in
                let safetyResult = await SafeBrowsingManager.shared.checkURLSafety(url, allowRemoteLookup: self.parent.tab?.isIncognito != true)

                switch safetyResult {
                case .safe:
                    decisionHandler(self.allowedNavigationPolicy(for: navigationAction))

                case .unsafe(let threat):
                    // URL is malicious - block navigation and show warning
                    NSLog(
                        "Safe Browsing blocked navigation"
                    )

                    // Post notification to show threat warning
                    NotificationCenter.default.post(
                        name: .safeBrowsingThreatDetected,
                        object: nil,
                        userInfo: [
                            "url": url,
                            "threat": threat,
                            "navigationAction": navigationAction,
                            "webView": self.webView as Any,
                        ]
                    )

                    // Block navigation
                    decisionHandler(.cancel)

                case .unknown:
                    // Unable to determine safety (API error, offline, etc.)
                    // Allow navigation but log the issue
                    NSLog(
                        "Navigation reputation check unavailable"
                    )

                    decisionHandler(self.allowedNavigationPolicy(for: navigationAction))
                }
            }
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if DownloadResponsePolicy.shouldDownload(navigationResponse.response,
                                                       canShowMIMEType: navigationResponse.canShowMIMEType) {
                guard let url = navigationResponse.response.url, NavigationResolver.isWebURL(url) else {
                    decisionHandler(.cancel)
                    return
                }
                // Continue the original WebKit request with its cookies and body.
                decisionHandler(.download)
                return
            }

            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            acceptDownload(download)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            acceptDownload(download)
        }

        private func acceptDownload(_ download: WKDownload) {
            DownloadManager.shared.handleWebViewDownload(download, isPrivate: parent.tab?.isIncognito == true)
            parent.isLoading = false
            parent.tab?.notifyLoadingStateChanged()
        }

        // MARK: - TLS Certificate Validation

        /**
         * Handles TLS authentication challenges for comprehensive certificate validation
         *
         * This method is critical for browser security and handles:
         * - Server trust validation (TLS certificates)
         * - Certificate pinning for high-value domains
         * - User consent for certificate exceptions
         * - Security logging and audit trails
         *
         * Security Implementation:
         * - Never bypasses certificate errors without user consent
         * - Implements certificate pinning for critical domains
         * - Provides clear security warnings to users
         * - Logs all certificate validation events
         */
        func webView(
            _ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) ->
                Void
        ) {

            // Use CertificateManager for comprehensive validation
            let (disposition, credential) = CertificateManager.shared.validateChallenge(challenge)

            // Handle the result based on CertificateManager's decision
            switch disposition {
            case .useCredential:
                // Certificate validation passed - proceed with credential
                completionHandler(.useCredential, credential)

            case .cancelAuthenticationChallenge:
                // Certificate validation failed or requires user intervention
                // CertificateManager will handle showing security warnings via notifications
                completionHandler(.cancelAuthenticationChallenge, nil)

            case .performDefaultHandling:
                // Use WebKit's default handling (for non-server-trust challenges)
                completionHandler(.performDefaultHandling, nil)

            case .rejectProtectionSpace:
                // Reject the protection space entirely
                completionHandler(.rejectProtectionSpace, nil)

            @unknown default:
                // Future-proof handling for new challenge disposition types
                NSLog("⚠️ Unknown URLSession.AuthChallengeDisposition: \(disposition)")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }

        // MARK: - WKScriptMessageHandler (CSP-Protected)
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            switch message.name {
            case "linkHover":
                let validationResult = CSPManager.shared.validateMessageInput(
                    message, expectedHandler: "linkHover")

                switch validationResult {
                case .valid(let sanitizedBody):
                    DispatchQueue.main.async {
                        if let type = sanitizedBody["type"] as? String {
                            switch type {
                            case "hover":
                                if let url = sanitizedBody["url"] as? String {
                                    self.parent.hoveredLink = url
                                }
                            case "clear":
                                self.parent.hoveredLink = nil
                            default:
                                break
                            }
                        }
                    }
                case .invalid(let error):
                    NSLog("🔒 CSP: Link hover message validation failed: \(error.description)")
                }

            case "linkContextMenu":
                let validationResult = CSPManager.shared.validateMessageInput(
                    message, expectedHandler: "linkContextMenu")

                switch validationResult {
                case .valid(let sanitizedBody):
                    DispatchQueue.main.async {
                        if let type = sanitizedBody["type"] as? String {
                            switch type {
                            case "rightClick":
                                if let url = sanitizedBody["url"] as? String {
                                    self.rightClickedLinkURL = url
                                    // The context menu will be shown by WKUIDelegate method
                                }
                            default:
                                break
                            }
                        }
                    }
                case .invalid(let error):
                    NSLog(
                        "🔒 CSP: Link context menu message validation failed: \(error.description)")
                }

            case "agentBridge":
                let validationResult = CSPManager.shared.validateMessageInput(
                    message, expectedHandler: "agentBridge")

                switch validationResult {
                case .valid(let body):
                    if let type = body["type"] as? String {
                        switch type {
                        case "runtime_ready":
                            agentRuntimeReady = true
                            if AppLog.isVerboseEnabled { AppLog.debug("Agent runtime ready (M2)") }
                        case "ping":
                            if AppLog.isVerboseEnabled { AppLog.debug("Agent ping") }
                        default:
                            break
                        }
                    }
                case .invalid(let error):
                    AppLog.warn("CSP: Agent bridge validation failed: \(error.description)")
                }

            default:
                AppLog.warn("CSP: Unexpected message handler: \(message.name)")
                break
            }
        }

        // MARK: - WKUIDelegate
        // Note: Context menu customization is handled in CustomWebView subclass

        func webView(
            _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil,
                  let url = navigationAction.request.url,
                  NavigationResolver.isWebURL(url),
                  let sourceTab = parent.tab else { return nil }

            // Keep form submissions intact; a URL-only tab would turn POST into GET.
            if navigationAction.request.httpMethod?.uppercased() != "GET",
               navigationAction.request.httpMethod != nil {
                webView.load(navigationAction.request)
                return nil
            }
            NotificationCenter.default.post(
                name: .newTabInBackgroundRequested, object: nil,
                userInfo: ["url": url, "sourceTabID": sourceTab.id, "isIncognito": sourceTab.isIncognito,
                    "activate": BrowserLinkDisposition.opensForeground(modifiers: navigationAction.modifierFlags,
                        buttonNumber: navigationAction.buttonNumber)]
            )
            return nil
        }

        // MARK: - WebView Responsiveness Protection

        /// Ensures WebView remains responsive during AI operations
        /// AI RESPONSIVENESS FIX: Prevents AI processing from blocking WebView JavaScript
        private func protectWebViewResponsiveness() {
            guard let webView = webView else { return }

            // Periodically check if WebView is responsive during AI operations
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) {
                [weak self] timer in
                guard let self = self else {
                    timer.invalidate()
                    return
                }

                // Only run checks if we have an active WebView
                guard let webView = self.webView else {
                    timer.invalidate()
                    return
                }

                // Simple JavaScript responsiveness test
                webView.evaluateJavaScript("Date.now()") { result, error in
                    if let error = error {
                        NSLog(
                            "Page responsiveness check failed (domain: \((error as NSError).domain), code: \((error as NSError).code))"
                        )
                    } else if let timestamp = result as? NSNumber {
                        let responseTime =
                            Date().timeIntervalSince1970 * 1000 - timestamp.doubleValue
                        if responseTime > 1000 {  // > 1 second delay
                            NSLog("⚠️ WebView JavaScript response delay detected: \(responseTime)ms")
                        }
                    }
                }
            }

            // Suspend/resume this timer based on app backgrounding
            let suspendObserver = NotificationCenter.default.addObserver(
                forName: .suspendWebViewResponsivenessChecks, object: nil, queue: .main
            ) { _ in
                timer.invalidate()
            }

            let resumeObserver = NotificationCenter.default.addObserver(
                forName: .resumeWebViewResponsivenessChecks, object: nil, queue: .main
            ) { [weak self] _ in
                // Restart protection if needed
                self?.protectWebViewResponsiveness()
            }

            // Store observers to remove later
            objc_setAssociatedObject(
                webView, &CoordinatorObserverKeys.suspendKey, suspendObserver,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(
                webView, &CoordinatorObserverKeys.resumeKey, resumeObserver,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }

        private struct CoordinatorObserverKeys {
            static var suspendKey: UInt8 = 0
            static var resumeKey: UInt8 = 0
        }

        // MARK: - Adaptive Content Extraction

        /// Performs intelligent content extraction with adaptive timing based on page readiness
        /// AI RESPONSIVENESS FIX: Runs on background thread to prevent WebView blocking
        private func performAdaptiveContentExtraction(webView: WKWebView, tab: Tab) async {
            guard tab.isActive, tab.webView === webView else { return }
            // AI RESPONSIVENESS FIX: Start monitoring WebView responsiveness
            protectWebViewResponsiveness()

            // AI RESPONSIVENESS FIX: Run context extraction on background queue
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    Task {
                        await self.performBackgroundContextExtraction(webView: webView, tab: tab)
                        continuation.resume()
                    }
                }
            }
        }

        /// Background context extraction to prevent UI blocking
        /// AI RESPONSIVENESS FIX: Separated background processing logic
        private func performBackgroundContextExtraction(webView: WKWebView, tab: Tab) async {
            var attemptCount = 0
            let maxAttempts = 5
            var bestContext: WebpageContext?

            // Wait for basic page readiness
            await waitForPageReadiness(webView: webView)

            while attemptCount < maxAttempts {
                guard tab.isActive, tab.webView === webView else { return }
                attemptCount += 1

                let context = await ContextManager.shared.extractPageContext(
                    from: webView, tab: tab)

                if let context = context {
                    bestContext = context

                    // Log extraction attempt
                    if AppLog.isVerboseEnabled {
                        AppLog.debug(
                            "Auto-read attempt #\(attemptCount): len=\(context.text.count) q=\(context.contentQuality) (\(context.qualityDescription))"
                        )
                    }

                    // Check if we have good enough content or if JS recommends no retry
                    if context.isHighQuality || !context.shouldRetry {
                        if AppLog.isVerboseEnabled {
                            AppLog.debug(
                                "Auto-read complete: len=\(context.text.count) title=\(context.title)"
                            )
                        }
                        break
                    }

                    // If content is not stable, wait for stability
                    if !context.isContentStable {
                        NSLog("⏳ Content not stable, waiting...")
                        try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
                    } else {
                        // Wait progressively longer between attempts
                        let delay = Double(attemptCount) * 1.5  // 1.5s, 3s, 4.5s, 6s
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                } else {
                    // Failed extraction, wait before retry
                    try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 seconds
                }
            }

            // Notify completion regardless of result quality
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .pageNavigationCompleted,
                    object: tab.id
                )
            }

            if let finalContext = bestContext {
                NSLog(
                    "🏁 Final extraction result: \(finalContext.text.count) characters, quality: \(finalContext.contentQuality) (\(finalContext.qualityDescription)) after \(attemptCount) attempts"
                )
            } else {
                NSLog("❌ Content extraction failed after \(attemptCount) attempts")
            }
        }

        /// Waits for basic page readiness using document.readyState and network activity
        private func waitForPageReadiness(webView: WKWebView) async {
            let maxWaitTime: TimeInterval = 10.0  // Maximum wait time
            let startTime = Date()

            while Date().timeIntervalSince(startTime) < maxWaitTime {
                // Check document ready state
                let isReady = await withCheckedContinuation { continuation in
                    DispatchQueue.main.async {
                        webView.evaluateJavaScript("document.readyState") { result, error in
                            if let readyState = result as? String {
                                continuation.resume(returning: readyState == "complete")
                            } else {
                                continuation.resume(returning: false)
                            }
                        }
                    }
                }

                if isReady {
                    // Wait a bit more for dynamic content
                    try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
                    break
                }

                // Check every 100ms
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        deinit {
            // Comprehensive cleanup to prevent memory leaks
            progressObserver?.invalidate()
            titleObserver?.invalidate()
            magnificationObserver?.invalidate()
            urlObserver?.invalidate()
            mixedContentObserver?.invalidate()
            progressObserver = nil
            titleObserver = nil
            magnificationObserver = nil
            urlObserver = nil
            mixedContentObserver = nil

            // Clean up certificate notification observers
            certificateNotificationObserver?.cancel()
            certificateNotificationObserver = nil
            pendingChallenges.removeAll()

            // SECURITY: Clean up mixed content monitoring
            mixedContentNotificationObserver?.cancel()
            mixedContentNotificationObserver = nil

            if let webView = webView, let tab = parent.tab {
                MixedContentManager.shared.removeMixedContentMonitoring(for: webView, tabID: tab.id)
            }

            // Clean up WebView references
            if let webView = webView {
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
                webView.configuration.userContentController.removeAllUserScripts()

                // Remove script message handlers
                webView.configuration.userContentController.removeScriptMessageHandler(
                    forName: "linkHover")
                webView.configuration.userContentController.removeScriptMessageHandler(
                    forName: "linkContextMenu")
                webView.configuration.userContentController.removeScriptMessageHandler(
                    forName: "agentBridge")
                webView.configuration.userContentController.removeScriptMessageHandler(
                    forName: "adBlockHandler")
                webView.configuration.userContentController.removeScriptMessageHandler(
                    forName: "autofillHandler", contentWorld: .defaultClient)
                webView.configuration.userContentController.removeScriptMessageHandler(
                    forName: "incognitoHandler")

                self.webView = nil
            }
        }
    }
}


extension WebView {
    init(tab: Tab, hoveredLink: Binding<String?>) {
        self.init(
            url: Binding(get: { tab.url }, set: { tab.url = $0 }),
            canGoBack: Binding(get: { tab.canGoBack }, set: { tab.canGoBack = $0 }),
            canGoForward: Binding(get: { tab.canGoForward }, set: { tab.canGoForward = $0 }),
            isLoading: Binding(get: { tab.isLoading }, set: { tab.isLoading = $0 }),
            estimatedProgress: Binding(get: { tab.estimatedProgress }, set: { tab.estimatedProgress = $0 }),
            title: Binding(get: { tab.title }, set: { tab.title = $0 ?? "New Tab" }),
            favicon: Binding(get: { tab.favicon }, set: { tab.favicon = $0 }),
            hoveredLink: hoveredLink, mixedContentStatus: .constant(nil), tab: tab,
            onNavigationAction: nil, onDownloadRequest: nil)
    }
}

enum BrowserLinkDisposition {
    static func opensForeground(modifiers: NSEvent.ModifierFlags, buttonNumber: Int) -> Bool {
        if modifiers.contains(.shift) { return true }
        return buttonNumber != 2 && !modifiers.contains(.command)
    }
}
