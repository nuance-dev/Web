import SwiftUI
import AppKit

// Shared tab context menu for right-click actions
struct TabContextMenu: View {
    let tab: Tab
    let tabManager: TabManager
    
    var body: some View {
        Button("Close Tab") {
            tabManager.closeTab(tab)
        }
        
        Button("Close Other Tabs") {
            tabManager.closeOtherTabs(except: tab)
        }
        
        Divider()
        
        Button("Duplicate Tab") {
            if let url = tab.url {
                _ = tabManager.createNewTab(url: url, isIncognito: tab.isIncognito)
            }
        }
        
        if let url = tab.url {
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }
}

// Find-in-Page overlay component
struct FindOverlay: View {
    @Binding var query: String
    var onClose: () -> Void
    var onNext: () -> Void
    var onPrev: () -> Void
    var onSubmit: () -> Void
    
    @FocusState private var isFieldFocused: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Find in page", text: $query)
                .textFieldStyle(.plain)
                .frame(width: 220)
                .focused($isFieldFocused)
                .onSubmit { onSubmit() }
            Button(action: onPrev) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            Button(action: onNext) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            Divider().frame(height: 14)
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.white.opacity(0.15), lineWidth: 0.5)
                )
        )
        .onAppear { isFieldFocused = true }
    }
}