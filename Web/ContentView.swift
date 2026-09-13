import SwiftUI

struct ContentView: View {
    var body: some View {
        BrowserView()
            .background(Color(nsColor: .windowBackgroundColor))
            .ignoresSafeArea(.container, edges: .top)
    }
}

#Preview {
    ContentView().frame(width: 1200, height: 800)
}
