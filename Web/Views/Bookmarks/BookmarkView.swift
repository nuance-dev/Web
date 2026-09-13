import SwiftUI
import CoreData

struct BookmarkView: View {
    var tabManager: TabManager? = nil
    @ObservedObject private var bookmarks = BookmarkService.shared
    @State private var search = ""
    @State private var folderSelection = "all"
    @State private var selection: UUID?
    @State private var showingNewFolder = false
    @State private var showingEditor = false
    @State private var editingBookmark: Bookmark?
    @State private var bookmarkToDelete: Bookmark?
    @State private var confirmDelete = false

    private var folders: [(folder: BookmarkFolder, depth: Int)] {
        var result: [(BookmarkFolder, Int)] = []
        var seen = Set<UUID>()
        func append(_ children: [BookmarkFolder], depth: Int) {
            guard depth < 12 else { return }
            for folder in children where seen.insert(folder.id).inserted {
                result.append((folder, depth))
                append(folder.subfoldersArray, depth: depth + 1)
            }
        }
        append(bookmarks.folders, depth: 0)
        return result
    }

    private var selectedFolder: BookmarkFolder? {
        folders.first(where: { $0.folder.id.uuidString == folderSelection })?.folder
    }

    private var items: [Bookmark] {
        bookmarks.bookmarks.filter { bookmark in
            (selectedFolder == nil || bookmark.folder?.id == selectedFolder?.id)
                && (search.isEmpty || bookmark.displayTitle.localizedCaseInsensitiveContains(search)
                    || bookmark.url.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            HStack(spacing: 8) {
                folderSidebar
                VStack(spacing: 0) {
                    if items.isEmpty {
                        LibraryEmptyState(title: search.isEmpty ? "No bookmarks here" : "No matches",
                            detail: search.isEmpty ? "Save a page with ⌘D, or add an address." : "Try another title or address.",
                            icon: selectedFolder == nil ? "bookmark" : "folder")
                    } else {
                        List(selection: $selection) {
                            ForEach(items, id: \.id) { bookmark in
                                row(bookmark).tag(bookmark.id)
                                    .onTapGesture(count: 2) { open(bookmark) }
                                    .contextMenu { actions(bookmark) }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .onKeyPress(.return) {
                            guard let bookmark = items.first(where: { $0.id == selection }) else { return .ignored }
                            open(bookmark)
                            return .handled
                        }
                    }
                    HStack {
                        Text("\(items.count) bookmarks").monospacedDigit()
                        Spacer()
                        Text("Double-click to open")
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.bottom, 2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: search) { _, _ in selection = nil }
        .onChange(of: folderSelection) { _, _ in selection = nil }
        .sheet(isPresented: $showingNewFolder) { NewFolderSheet(parentFolder: selectedFolder) }
        .sheet(isPresented: $showingEditor) {
            BookmarkEditorSheet(bookmark: editingBookmark, folder: selectedFolder,
                initialURL: editingBookmark == nil ? tabManager?.activeTab?.url?.absoluteString ?? "" : "",
                initialTitle: editingBookmark == nil ? tabManager?.activeTab?.title ?? "" : "")
        }
        .alert("Delete bookmark?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) { bookmarkToDelete = nil }
            Button("Delete", role: .destructive) {
                if let bookmark = bookmarkToDelete {
                    if selection == bookmark.id { selection = nil }
                    bookmarks.deleteBookmark(bookmark)
                }
                bookmarkToDelete = nil
            }
        } message: { Text(bookmarkToDelete?.displayTitle ?? "This bookmark will be removed.") }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Bookmarks").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { editingBookmark = nil; showingEditor = true } label: { Label("Add", systemImage: "plus") }
                    .buttonStyle(.glass).controlSize(.small).help("Add a bookmark")
                Button { KeyboardShortcutHandler.shared.showBookmarksPanel = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .help("Close bookmarks · Esc").accessibilityLabel("Close bookmarks")
            }
            LibrarySearchField(placeholder: "Search bookmarks", text: $search) {
                if let bookmark = items.first(where: { $0.id == selection }) ?? items.first { open(bookmark) }
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private var folderSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            List(selection: Binding<String?>(get: { folderSelection }, set: { if let value = $0 { folderSelection = value } })) {
                folderRow("All bookmarks", icon: "bookmark", count: bookmarks.bookmarks.count).tag("all")
                ForEach(folders, id: \.folder.id) { item in
                    folderRow(item.folder.name, icon: "folder", count: item.folder.bookmarksArray.count)
                        .padding(.leading, CGFloat(item.depth) * 8)
                        .tag(item.folder.id.uuidString)
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden).scrollIndicators(.hidden)
            Button { showingNewFolder = true } label: {
                Label("New folder", systemImage: "folder.badge.plus").font(.system(size: 12))
            }
            .buttonStyle(.glass).controlSize(.small)
            .padding(8)
        }
        .frame(width: 152)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func folderRow(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 12))
            Text(title).lineLimit(1)
            Spacer(minLength: 2)
            Text("\(count)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }.font(.system(size: 12))
    }

    private func row(_ bookmark: Bookmark) -> some View {
        HStack(spacing: 9) {
            LibraryPageIcon(data: bookmark.faviconData)
            VStack(alignment: .leading, spacing: 2) {
                Text(bookmark.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(URL(string: bookmark.url)?.host ?? bookmark.url)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Menu { actions(bookmark) } label: { Image(systemName: "ellipsis").frame(width: 24, height: 26) }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Bookmark actions").accessibilityLabel("Actions for \(bookmark.displayTitle)")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(bookmark.url)
    }

    @ViewBuilder private func actions(_ bookmark: Bookmark) -> some View {
        Button("Open") { open(bookmark) }
        Button("Open in New Tab") { open(bookmark, newTab: true) }
        Divider()
        Button("Edit…") { editingBookmark = bookmark; showingEditor = true }
        Menu("Move to") {
            Button("Bookmarks") { bookmarks.moveBookmark(bookmark, to: nil) }
            ForEach(folders, id: \.folder.id) { item in
                Button(item.folder.name) { bookmarks.moveBookmark(bookmark, to: item.folder) }
            }
        }
        Button("Delete…", role: .destructive) { bookmarkToDelete = bookmark; confirmDelete = true }
    }

    private func open(_ bookmark: Bookmark, newTab: Bool = false) {
        guard let url = URL(string: bookmark.url), NavigationResolver.isWebURL(url), let tabManager else { return }
        if !newTab, let tab = tabManager.activeTab { tab.navigate(to: url) }
        else { _ = tabManager.createNewTab(url: url, isIncognito: tabManager.activeTab?.isIncognito ?? false) }
        KeyboardShortcutHandler.shared.showBookmarksPanel = false
    }
}

struct NewFolderSheet: View {
    let parentFolder: BookmarkFolder?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New folder").font(.system(size: 17, weight: .semibold))
            TextField("Folder name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            SettingsNote("In \(parentFolder?.name ?? "Bookmarks")")
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Create") {
                    BookmarkService.shared.createFolder(name: name.trimmingCharacters(in: .whitespacesAndNewlines), parentFolder: parentFolder)
                    dismiss()
                }
                .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16).frame(width: 320)
        .onAppear { focused = true }
    }
}

struct BookmarkEditorSheet: View {
    @ObservedObject private var service = BookmarkService.shared
    let bookmark: Bookmark?
    let folder: BookmarkFolder?
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var address: String
    @FocusState private var addressFocused: Bool

    init(bookmark: Bookmark?, folder: BookmarkFolder?, initialURL: String = "", initialTitle: String = "") {
        self.bookmark = bookmark
        self.folder = folder
        _title = State(initialValue: bookmark?.title ?? initialTitle)
        _address = State(initialValue: bookmark?.url ?? initialURL)
    }

    private var destination: URL? {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NavigationResolver.resolve(address)
    }

    private var isDuplicate: Bool {
        guard let destination else { return false }
        return service.bookmarks.contains { $0.url == destination.absoluteString && $0.id != bookmark?.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(bookmark == nil ? "Add bookmark" : "Edit bookmark").font(.system(size: 17, weight: .semibold))
            SettingsStack {
                SettingsCard("Page", icon: "bookmark") {
                    TextField("Title", text: $title).textFieldStyle(.roundedBorder)
                    TextField("Address", text: $address).textFieldStyle(.roundedBorder).focused($addressFocused)
                    if isDuplicate { SettingsNote("This page is already bookmarked.") }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.glass).keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(destination == nil || isDuplicate)
            }
        }
        .padding(16).frame(width: 390)
        .onAppear { addressFocused = true }
    }

    private func save() {
        guard let destination, NavigationResolver.isWebURL(destination), !isDuplicate else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bookmark {
            BookmarkService.shared.updateBookmark(bookmark, title: title, url: destination.absoluteString, folder: bookmark.folder)
        } else {
            BookmarkService.shared.addBookmark(url: destination.absoluteString, title: title, folder: folder)
        }
        dismiss()
    }
}

#Preview { BookmarkView().frame(width: 680, height: 500) }
