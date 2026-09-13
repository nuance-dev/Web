import AppKit
import SwiftUI
import Testing
import WebKit
@testable import Web

@MainActor
struct NativePageContainerTests {
    @Test func resizingKeepsConfiguredPageAndCoordinator() {
        let tab = Tab(isIncognito: true)
        defer { tab.dispose() }
        let view = Web.WebView(tab: tab, hoveredLink: .constant(nil))
        let coordinator = view.makeCoordinator()
        let webView = view.configuredWebView(coordinator: coordinator)
        let container = NativePageContainer(webView: webView)

        for size in [NSSize(width: 1000, height: 700), NSSize(width: 286, height: 400),
                     NSSize(width: 1000, height: 700)] {
            container.setFrameSize(size)
            container.layoutSubtreeIfNeeded()
            #expect(container.webView === webView)
            #expect(webView.superview === container)
            #expect(webView.frame == container.bounds)
            #expect(tab.webView === webView)
            #expect(webView.navigationDelegate === coordinator)
            #expect(webView.uiDelegate === coordinator)
        }
        container.updateLayer()
        #expect(container.layer?.cornerRadius == 10)
        #expect(container.layer?.masksToBounds == true)
        #expect(!container.canDrawSubviewsIntoLayer)
    }
}
