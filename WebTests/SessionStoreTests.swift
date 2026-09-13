import Foundation
import Testing
@testable import Web

struct SessionStoreTests {
    @Test func privateAndCredentialBearingPagesNeverEnterSnapshots() {
        #expect(SessionTabSnapshot(url: URL(string: "https://example.com"), title: "Secret", isPinned: true, zoomScale: 1, isPrivate: true) == nil)
        for value in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "https://user:password@example.com", "https://example.com/?access_token=secret", "https://example.com/#id_token=secret", "https://example.com/?code=one-time"] {
            #expect(!SessionTabSnapshot.isRestorableURL(URL(string: value)!))
        }
        #expect(SessionTabSnapshot.isRestorableURL(URL(string: "https://example.com/article?q=swift#examples")!))
    }

    @Test func snapshotsBoundTitleAndZoom() throws {
        let entry = try #require(SessionTabSnapshot(url: nil, title: String(repeating: "x", count: 1_000), isPinned: true, zoomScale: .infinity, isPrivate: false))
        #expect(entry.title.count == 300)
        #expect(entry.zoomScale == 1)
        #expect(entry.isPinned)
    }

    @Test func multiwindowSessionsRestoreExactlyOnceWithoutOverwriting() throws {
        let environment = try SessionTestEnvironment()
        defer { environment.remove() }
        environment.defaults.set(true, forKey: SessionStore.preferenceKey)
        let firstStore = SessionStore(fileURL: environment.fileURL, defaults: environment.defaults, observeLifecycle: false)
        let first = firstStore.registerWindow()
        let second = firstStore.registerWindow()
        #expect(first.id != second.id)
        let one = try snapshot("https://one.example")
        let two = try snapshot("https://two.example")
        firstStore.update(one, for: first.id)
        firstStore.update(two, for: second.id)
        firstStore.flush()

        let restarted = SessionStore(fileURL: environment.fileURL, defaults: environment.defaults, observeLifecycle: false)
        let restoredFirst = restarted.registerWindow()
        let restoredSecond = restarted.registerWindow()
        let newWindow = restarted.registerWindow()
        #expect(restoredFirst.restored == one)
        #expect(restoredSecond.restored == two)
        #expect(newWindow.restored == nil)
        #expect(newWindow.id != restoredFirst.id)
        #expect(newWindow.id != restoredSecond.id)
    }

    @Test func disablingRestoreDeletesDiskStateAndRejectsQueuedUpdates() throws {
        let environment = try SessionTestEnvironment()
        defer { environment.remove() }
        environment.defaults.set(true, forKey: SessionStore.preferenceKey)
        let store = SessionStore(fileURL: environment.fileURL, defaults: environment.defaults, observeLifecycle: false)
        let registration = store.registerWindow()
        store.update(try snapshot("https://example.com"), for: registration.id)
        store.flush()
        #expect(FileManager.default.fileExists(atPath: environment.fileURL.path))
        environment.defaults.set(false, forKey: SessionStore.preferenceKey)
        store.refreshPreference()
        store.update(try snapshot("https://example.com/new"), for: registration.id)
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: environment.fileURL.path))
    }

    @Test func windowClosureDoesNotEraseOtherWindowsAndQuitPreservesOpenTabs() throws {
        let environment = try SessionTestEnvironment()
        defer { environment.remove() }
        environment.defaults.set(true, forKey: SessionStore.preferenceKey)
        let store = SessionStore(fileURL: environment.fileURL, defaults: environment.defaults, observeLifecycle: false)
        let first = store.registerWindow()
        let second = store.registerWindow()
        store.update(try snapshot("https://closed.example"), for: first.id)
        let remaining = try snapshot("https://remaining.example")
        store.update(remaining, for: second.id)
        store.closeWindow(first.id)
        store.prepareForTermination()
        store.closeWindow(second.id)
        store.flush()
        let restarted = SessionStore(fileURL: environment.fileURL, defaults: environment.defaults, observeLifecycle: false)
        #expect(restarted.registerWindow().restored == remaining)
        #expect(restarted.registerWindow().restored == nil)
    }

    @Test func duplicateSnapshotsPreserveTheActivePosition() throws {
        let item = try #require(SessionTabSnapshot(url: URL(string: "https://example.com"), title: "Same page", isPinned: false, zoomScale: 1, isPrivate: false))
        let snapshot = WindowSessionSnapshot(tabs: [item, item], activeIndex: 1)
        #expect(snapshot.validated.activeIndex == 1)
    }

    @Test func corruptedSessionFailsClosed() throws {
        let environment = try SessionTestEnvironment()
        defer { environment.remove() }
        environment.defaults.set(true, forKey: SessionStore.preferenceKey)
        try Data("not JSON".utf8).write(to: environment.fileURL)
        let store = SessionStore(fileURL: environment.fileURL, defaults: environment.defaults, observeLifecycle: false)
        #expect(store.registerWindow().restored == nil)
    }

    private func snapshot(_ url: String) throws -> WindowSessionSnapshot {
        WindowSessionSnapshot(tabs: [try #require(SessionTabSnapshot(url: URL(string: url), title: "Page", isPinned: false, zoomScale: 1, isPrivate: false))], activeIndex: 0)
    }
}

private struct SessionTestEnvironment {
    let directory: URL
    let fileURL: URL
    let defaults: UserDefaults
    let suite: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("windows.json")
        suite = "SessionTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
