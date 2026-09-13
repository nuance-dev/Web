import Foundation
import Combine
import Testing
import WebKit
@testable import Web

@Suite(.serialized)
@MainActor
struct TabManagerTests {
    @Test func firstNavigationNotifiesWindowChrome() throws {
        let environment = try TabManagerTestEnvironment()
        defer { environment.remove() }
        let manager = environment.manager
        let tab = try #require(manager.activeTab)
        var notified = false
        let observation = manager.objectWillChange.sink { notified = true }
        tab.navigate(to: URL(string: "https://example.com")!)
        #expect(notified)
        #expect(manager.activeTab?.url?.host == "example.com")
        withExtendedLifetime(observation) {}
    }

    @Test func duplicatingPrivateTabsKeepsThemPrivateAndOutOfRestoration() throws {
        let environment = try TabManagerTestEnvironment()
        defer { environment.remove() }
        let manager = environment.manager
        let source = manager.createIncognitoTab(url: URL(string: "https://private.example/page")!)
        source.title = "Private page"
        source.zoomScale = 1.5

        let duplicate = try #require(manager.duplicateTab(source))
        #expect(duplicate.id != source.id)
        #expect(duplicate.isIncognito)
        #expect(duplicate.url == source.url)
        #expect(duplicate.zoomScale == 1.5)
        #expect(manager.activeTab?.id == duplicate.id)
        #expect(IncognitoSession.shared.incognitoTabs.contains { $0.id == duplicate.id })

        environment.store.flush()
        let reopened = SessionStore(fileURL: environment.fileURL, defaults: environment.defaults, observeLifecycle: false)
        let restored = try #require(reopened.registerWindow().restored)
        #expect(restored.tabs.count == 1)
        #expect(restored.tabs.first?.url == nil)

        manager.closeTab(duplicate)
        manager.closeTab(source)
        #expect(manager.recentlyClosedTabs.isEmpty)
        #expect(manager.reopenLastClosedTab() == nil)
    }

    @Test func closingWindowReleasesItsPrivateTabsAndIsIdempotent() throws {
        let environment = try TabManagerTestEnvironment()
        defer { environment.remove() }
        let manager = environment.manager
        let baseline = Set(IncognitoSession.shared.incognitoTabs.map(\.id))
        let storeBefore = WebKitManager.shared.incognitoDataStore
        let first = manager.createIncognitoTab()
        let second = manager.createIncognitoTab()

        manager.closeWindow()
        manager.closeWindow()

        #expect(manager.tabs.isEmpty)
        #expect(manager.activeTab == nil)
        #expect(manager.recentlyClosedTabs.isEmpty)
        #expect(!first.isActive && !second.isActive)
        #expect(Set(IncognitoSession.shared.incognitoTabs.map(\.id)) == baseline)
        if baseline.isEmpty {
            #expect(!IncognitoSession.shared.isActive)
            #expect(WebKitManager.shared.incognitoDataStore !== storeBefore)
        }
        let reopened = SessionStore(fileURL: environment.fileURL, defaults: environment.defaults, observeLifecycle: false)
        #expect(reopened.registerWindow().restored == nil)
    }

    @Test func bulkClosePreservesPinnedTabsAndTheRequestedTab() throws {
        let environment = try TabManagerTestEnvironment()
        defer { environment.remove() }
        let manager = environment.manager
        let pinned = try #require(manager.activeTab)
        manager.togglePin(pinned)
        let keep = manager.createNewTab(url: URL(string: "https://keep.example"))
        _ = manager.createNewTab(url: URL(string: "https://close.example"))

        manager.closeOtherTabs(except: keep)

        #expect(manager.tabs.map(\.id) == [pinned.id, keep.id])
        #expect(pinned.isPinned)
        #expect(manager.activeTab?.id == keep.id)
        #expect(manager.recentlyClosedTabs.count == 1)
    }

    @Test func closingTabsToTheRightKeepsPinnedNeighbors() throws {
        let environment = try TabManagerTestEnvironment()
        defer { environment.remove() }
        let manager = environment.manager
        let first = try #require(manager.activeTab)
        manager.togglePin(first)
        let second = manager.createNewTab()
        manager.togglePin(second)
        _ = manager.createNewTab(url: URL(string: "https://right.example"))

        manager.closeTabsToTheRight(of: first)

        #expect(manager.tabs.map(\.id) == [first.id, second.id])
        #expect(manager.tabs.allSatisfy { $0.isPinned })
        #expect(manager.activeTab?.id == second.id)
    }

    @Test func duplicateCleanupKeepsActivePinnedAndPrivateCopies() throws {
        let environment = try TabManagerTestEnvironment()
        defer { environment.remove() }
        let manager = environment.manager
        let url = URL(string: "https://duplicate.example/article")!
        let pinned = manager.createNewTab(url: url)
        manager.togglePin(pinned)
        let active = manager.createNewTab(url: url)
        let redundant = manager.createNewTab(url: url)
        let privateOne = manager.createIncognitoTab(url: url)
        let privateTwo = manager.createIncognitoTab(url: url)
        manager.setActiveTab(active)

        #expect(manager.closeDuplicateTabs() == 2)
        #expect(manager.activeTab?.id == active.id)
        #expect(active.isActive)
        #expect(manager.tabs.contains { $0.id == active.id })
        #expect(manager.tabs.contains { $0.id == pinned.id })
        #expect(!manager.tabs.contains { $0.id == redundant.id })
        #expect(manager.tabs.filter { $0.isIncognito && $0.url == url }.count == 1)
        #expect(manager.recentlyClosedTabs.allSatisfy { !$0.isIncognito })
        #expect(manager.recentlyClosedTabs.count == 1)
        let privateIDs = Set([privateOne.id, privateTwo.id])
        #expect(IncognitoSession.shared.incognitoTabs.filter { privateIDs.contains($0.id) }.count == 1)
    }

    @Test func foreignTabsCannotReplaceTheActiveTabOrBecomePinned() throws {
        let environment = try TabManagerTestEnvironment()
        defer { environment.remove() }
        let manager = environment.manager
        let original = try #require(manager.activeTab)
        let foreign = Tab()
        defer { foreign.dispose() }

        manager.setActiveTab(foreign)
        manager.togglePin(foreign)

        #expect(manager.activeTab?.id == original.id)
        #expect(!foreign.isPinned)
        #expect(manager.duplicateTab(foreign) == nil)
    }
}

@MainActor
private struct TabManagerTestEnvironment {
    let directory: URL
    let fileURL: URL
    let defaults: UserDefaults
    let suite: String
    let store: SessionStore
    let manager: TabManager

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("windows.json")
        suite = "TabManagerTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: SessionStore.preferenceKey)
        store = SessionStore(fileURL: fileURL, defaults: defaults, observeLifecycle: false)
        manager = TabManager(sessionStore: store)
    }

    func remove() {
        manager.closeWindow()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
