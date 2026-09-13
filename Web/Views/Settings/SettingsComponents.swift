import SwiftUI

struct SettingsStack<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 10) { content }
        }
        .font(.system(size: 13))
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String?
    @ViewBuilder let content: Content

    init(_ title: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)) }
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}

struct SettingsToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13)).foregroundStyle(.primary)
                if let detail {
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(value).foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
    }
}

struct SettingsNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension View {
    func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        SettingsCard(title, content: content)
    }
}

struct LibrarySearchField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button { text = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .glassEffect(.regular, in: .rect(cornerRadius: 10))
        .onAppear { focused = true }
        .accessibilityLabel(placeholder)
    }
}

struct LibraryPageIcon: View {
    let data: Data?
    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "globe").font(.system(size: 15)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

struct LibraryEmptyState: View {
    let title: String
    let detail: String
    let icon: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
