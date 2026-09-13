import SwiftUI
import CoreData

struct HistoryView: View {
    var tabManager: TabManager? = nil
    @ObservedObject private var history = HistoryService.shared
    @State private var search = ""
    @State private var timeRange: HistoryTimeRange = .all
    @State private var selection: UUID?
    @State private var confirmClear = false
    @State private var isClearing = false
    @State private var clearFailed = false

    private var items: [HistoryItem] {
        let matching = search.isEmpty ? history.recentHistory : history.searchHistory(query: search)
        let calendar = Calendar.current
        let now = Date()
        return matching.filter { item in
            switch timeRange {
            case .today: calendar.isDateInToday(item.lastVisitDate)
            case .yesterday: calendar.isDateInYesterday(item.lastVisitDate)
            case .thisWeek: item.lastVisitDate >= (calendar.date(byAdding: .day, value: -7, to: now) ?? now)
            case .thisMonth: item.lastVisitDate >= (calendar.date(byAdding: .month, value: -1, to: now) ?? now)
            case .all: true
            }
        }.sorted { $0.lastVisitDate > $1.lastVisitDate }
    }

    private var sections: [(date: Date, items: [HistoryItem])] {
        Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.lastVisitDate) }
            .map { (date: $0.key, items: $0.value) }.sorted { $0.date > $1.date }
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            if items.isEmpty {
                LibraryEmptyState(title: search.isEmpty ? "No history here" : "No matches",
                    detail: search.isEmpty ? "Pages you visit will appear here." : "Try another title or address.", icon: "clock")
            } else {
                List(selection: $selection) {
                    ForEach(sections, id: \.date) { section in
                        Section(sectionTitle(section.date)) {
                            ForEach(section.items, id: \.id) { item in
                                row(item).tag(item.id)
                                    .onTapGesture(count: 2) { open(item) }
                                    .contextMenu { actions(item) }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onKeyPress(.return) {
                    guard let item = items.first(where: { $0.id == selection }) else { return .ignored }
                    open(item)
                    return .handled
                }
            }
            HStack {
                Text("\(items.count) pages").monospacedDigit()
                Spacer()
                Text("Double-click to open")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.bottom, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: search) { _, _ in selection = nil }
        .onChange(of: timeRange) { _, _ in selection = nil }
        .alert("Clear browsing history?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive, action: clear)
        } message: { Text("This removes all page visits and address suggestions. Bookmarks and downloads are kept.") }
        .alert("Couldn't clear history", isPresented: $clearFailed) {
            Button("OK", role: .cancel) {}
        } message: { Text("Try again in a moment.") }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("History").font(.system(size: 17, weight: .semibold))
                Spacer()
                if isClearing { ProgressView().controlSize(.small) }
                Button("Clear…") { confirmClear = true }.disabled(isClearing || history.recentHistory.isEmpty)
                    .buttonStyle(.glass).controlSize(.small)
                Button { KeyboardShortcutHandler.shared.showHistoryPanel = false } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                }
                .buttonStyle(.glass).buttonBorderShape(.circle)
                .help("Close history · Esc").accessibilityLabel("Close history")
            }
            HStack(spacing: 8) {
                LibrarySearchField(placeholder: "Search history", text: $search) {
                    if let item = items.first(where: { $0.id == selection }) ?? items.first { open(item) }
                }
                Picker("Time range", selection: $timeRange) {
                    ForEach(HistoryTimeRange.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).frame(width: 118).controlSize(.small)
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    private func row(_ item: HistoryItem) -> some View {
        HStack(spacing: 9) {
            LibraryPageIcon(data: item.faviconData)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(URL(string: item.url)?.host ?? item.url).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(item.lastVisitDate, format: .dateTime.hour().minute())
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Menu { actions(item) } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 26)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Page actions").accessibilityLabel("Actions for \(item.displayTitle)")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(item.url)
    }

    @ViewBuilder private func actions(_ item: HistoryItem) -> some View {
        Button("Open") { open(item) }
        Button("Open in New Tab") { open(item, newTab: true) }
        Divider()
        Button("Remove from History", role: .destructive) {
            if selection == item.id { selection = nil }
            history.deleteHistoryItem(item)
        }
    }

    private func sectionTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func open(_ item: HistoryItem, newTab: Bool = false) {
        guard let url = URL(string: item.url), NavigationResolver.isWebURL(url), let tabManager else { return }
        if !newTab, let tab = tabManager.activeTab { tab.navigate(to: url) }
        else { _ = tabManager.createNewTab(url: url, isIncognito: tabManager.activeTab?.isIncognito ?? false) }
        KeyboardShortcutHandler.shared.showHistoryPanel = false
    }

    private func clear() {
        isClearing = true
        history.clearAllHistory { success in
            isClearing = false
            if success {
                selection = nil
                AutofillService.shared.clearHistory()
                ContextManager.shared.clearContextCache()
                ContextManager.shared.lastExtractedContext = nil
            } else { clearFailed = true }
        }
    }
}

#Preview { HistoryView().frame(width: 630, height: 520) }
