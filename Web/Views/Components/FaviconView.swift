import SwiftUI
import AppKit

struct FaviconView: View {
    @ObservedObject var tab: Web.Tab
    let size: CGFloat
    
    var body: some View {
        Group {
            if let favicon = tab.favicon {
                Image(nsImage: favicon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                // Draw at the display scale instead of shrinking the app's dock icon.
                Image(systemName: "globe")
                    .font(.system(size: size * 0.85, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    let tab = Web.Tab()
    return FaviconView(tab: tab, size: 24)
}
