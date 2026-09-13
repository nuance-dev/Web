import SwiftUI

struct ContentView: View {
    var body: some View {
        BrowserView()
            .background {
                // Keep WebKit's remote layers outside the glass effect's content.
                Color.clear
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .ignoresSafeArea(.container, edges: .top)
    }
}

#Preview {
    ContentView().frame(width: 1200, height: 800)
}
