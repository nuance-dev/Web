import Foundation
import Network
import SwiftUI
import Testing
import WebKit
@testable import Web

@Suite(.serialized)
@MainActor
struct BackgroundNavigationTests {
    @Test func privateBackgroundPageLoadsBeforeSelectionAndReusesConfiguredView() async throws {
        let fixture = try await BackgroundPageFixture.start()
        defer { fixture.listener.cancel() }
        let environment = try BackgroundTabEnvironment()
        defer { environment.remove() }
        let manager = environment.manager
        let original = try #require(manager.activeTab)
        let tab = manager.createNewTabInBackground(url: fixture.url, isIncognito: true)
        let webView = try #require(tab.webView as? Web.WebView.CustomWebView)
        let coordinator = try #require(webView.coordinator)
        let deadline = Date().addingTimeInterval(8)
        while tab.title != "Background ready", Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(tab.title == "Background ready")
        #expect(manager.activeTab === original)
        #expect(!tab.isActive)
        #expect(!webView.configuration.websiteDataStore.isPersistent)
        #expect(webView.navigationDelegate === coordinator)
        #expect(webView.uiDelegate === coordinator)

        // Page-owned timers must survive a beforeunload event that doesn't
        // actually navigate. Some sites cancel navigation to protect a form.
        let nativeTimers = try await webView.evaluateJavaScript("window.setTimeout === window.originalPageTimeout")
        #expect(nativeTimers as? Bool == true)
        let previousTicks = try await webView.evaluateJavaScript("window.pageTicks") as? Int ?? 0
        _ = try await webView.evaluateJavaScript("window.dispatchEvent(new Event('beforeunload')); true")
        try await Task.sleep(for: .milliseconds(100))
        let ticks = try await webView.evaluateJavaScript("window.pageTicks") as? Int ?? 0
        #expect(ticks > previousTicks)

        manager.setActiveTab(tab)
        let visible = Web.WebView(tab: tab, hoveredLink: .constant(nil))
        #expect(visible.makeCoordinator() === coordinator)
        #expect(visible.configuredWebView(coordinator: coordinator) === webView)
        #expect(webView.url == fixture.url)

        manager.closeTab(tab)
        #expect(tab.webView == nil)
        #expect(webView.navigationDelegate == nil)
        #expect(webView.uiDelegate == nil)
    }

    @Test func emptyBackgroundTabsDoNotCreateWebViewsOrChangeSelection() throws {
        let environment = try BackgroundTabEnvironment()
        defer { environment.remove() }
        let original = environment.manager.activeTab
        let background = environment.manager.createNewTabInBackground()
        #expect(environment.manager.activeTab === original)
        #expect(background.webView == nil)
    }

    @Test func normalConfiguredTabHasOnePersistentViewAndDelegate() {
        let tab = Tab()
        defer { tab.dispose() }
        let view = Web.WebView(tab: tab, hoveredLink: .constant(nil))
        let coordinator = view.makeCoordinator()
        let first = view.configuredWebView(coordinator: coordinator)
        let second = view.configuredWebView(coordinator: view.makeCoordinator())
        #expect(first === second)
        #expect(first.configuration.websiteDataStore.isPersistent)
        #expect(first.navigationDelegate === coordinator)
        #expect(first.uiDelegate === coordinator)
    }

    @Test func nativeLinkModifiersChooseVisibleAndBackgroundDestinations() {
        #expect(BrowserLinkDisposition.opensForeground(modifiers: [], buttonNumber: 0))
        #expect(!BrowserLinkDisposition.opensForeground(modifiers: .command, buttonNumber: 0))
        #expect(!BrowserLinkDisposition.opensForeground(modifiers: [], buttonNumber: 2))
        #expect(BrowserLinkDisposition.opensForeground(modifiers: [.command, .shift], buttonNumber: 0))
        #expect(BrowserLinkDisposition.opensForeground(modifiers: .shift, buttonNumber: 2))
    }
}

@MainActor
private struct BackgroundTabEnvironment {
    let directory: URL
    let defaults: UserDefaults
    let suite: String
    let manager: TabManager

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suite = "BackgroundNavigationTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        let store = SessionStore(fileURL: directory.appendingPathComponent("session.json"), defaults: defaults,
            observeLifecycle: false)
        manager = TabManager(sessionStore: store)
    }

    func remove() {
        manager.closeWindow()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct BackgroundPageFixture {
    let listener: NWListener
    let url: URL

    static func start() async throws -> Self {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let html = """
        <html><head><title>Background ready</title><script>
        window.originalPageTimeout = window.setTimeout;
        window.pageTicks = 0;
        window.setInterval(() => window.pageTicks++, 20);
        </script></head><body><input aria-label="Test field"></body></html>
        """
        let body = Data(html.utf8)
        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global(qos: .userInitiated))
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
        guard let port = listener.port else { throw URLError(.cannotConnectToHost) }
        return Self(listener: listener, url: URL(string: "http://127.0.0.1:\(port.rawValue)/page")!)
    }
}
