import SwiftUI

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Spacer()
                Button {
                    KeyboardShortcutHandler.shared.showAboutPanel = false
                } label: {
                    Image(systemName: "xmark").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Close About")
            }
            Spacer()
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: 96, height: 96)
            }
            Text("Web").font(.system(size: 32, weight: .semibold))
            Text("\(version) · Preview").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 20) {
                Link("GitHub", destination: URL(string: "https://github.com/nuance-dev/Web")!)
                Link("Releases", destination: URL(string: "https://github.com/nuance-dev/Web/releases")!)
                Link("Report a bug", destination: URL(string: "https://github.com/nuance-dev/Web/issues")!)
            }
            .font(.callout)
            Spacer()
            Text("nuance-dev").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
