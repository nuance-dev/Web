import AppKit
import Testing
@testable import Web

@Suite(.serialized)
@MainActor
struct PanelWindowIntegrationTests {
    @Test func explicitWindowWinsWhenAnotherWindowHasFocus() {
        let first = makeWindow()
        let second = makeWindow()
        defer { first.close(); second.close() }
        let registry = PanelWindowRegistry()
        registry.register(first)
        registry.register(second)
        registry.markActive(second)

        let target = registry.resolve(explicit: first, keyWindow: second, mainWindow: second)
        #expect(target === first)
        var presentations = PanelPresentationState()
        presentations.set(.settings, isPresented: true, in: target?.windowNumber)
        #expect(presentations.panels(in: first.windowNumber) == [.settings])
        #expect(presentations.panels(in: second.windowNumber).isEmpty)
    }

    @Test func missingKeyWindowUsesLastActiveVisibleBrowser() {
        let first = makeWindow()
        let second = makeWindow()
        defer { first.close(); second.close() }
        first.orderFront(nil)
        second.orderFront(nil)
        let registry = PanelWindowRegistry()
        registry.register(first)
        registry.register(second)
        registry.markActive(first)

        #expect(first.isVisible)
        let target = registry.resolve(keyWindow: nil, mainWindow: nil)
        #expect(target === first)
        var presentations = PanelPresentationState()
        presentations.set(.settings, isPresented: true, in: target?.windowNumber)
        registry.markActive(second)
        #expect(presentations.panels(in: first.windowNumber) == [.settings])
        #expect(presentations.panels(in: second.windowNumber).isEmpty)

        registry.unregister(first)
        first.orderOut(nil)
        #expect(registry.resolve(keyWindow: first, mainWindow: nil) === second)
    }

    @Test func nativeSheetRoutesToItsRegisteredBrowserWindow() {
        let browser = makeWindow()
        let sheet = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 80),
                            styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        browser.orderFront(nil)
        browser.beginSheet(sheet)
        defer {
            browser.endSheet(sheet)
            sheet.close()
            browser.close()
        }
        let registry = PanelWindowRegistry()
        registry.register(browser)
        #expect(sheet.sheetParent === browser)
        #expect(registry.resolve(keyWindow: sheet, mainWindow: nil) === browser)
        #expect(registry.resolve(explicit: sheet, keyWindow: nil, mainWindow: nil) === browser)
    }

    @Test func unrelatedPanelCannotOwnBrowserPresentation() {
        let browser = makeWindow()
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        browser.orderFront(nil)
        defer { panel.close(); browser.close() }
        let registry = PanelWindowRegistry()
        registry.register(browser)
        #expect(registry.resolve(keyWindow: panel, mainWindow: nil) === browser)
        #expect(registry.resolve(explicit: panel, keyWindow: browser, mainWindow: browser) == nil)
        registry.unregister(browser)
        #expect(registry.resolve(keyWindow: nil, mainWindow: nil) == nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
}
