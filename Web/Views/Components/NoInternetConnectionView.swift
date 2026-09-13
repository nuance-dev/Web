import SwiftUI

struct NoInternetConnectionView: View {
    @ObservedObject private var networkMonitor = NetworkConnectivityMonitor.shared
    let onRetry: () -> Void
    var onGoBack: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("You’re offline").font(.title3.weight(.semibold))
                Text(networkMonitor.isConnected
                     ? "The network is available. Try loading this page again."
                     : "Check your connection, then try again.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 8) {
                if let onGoBack {
                    Button("Go back", action: onGoBack).buttonStyle(.glass)
                }
                Button("Try again", action: onRetry).buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
