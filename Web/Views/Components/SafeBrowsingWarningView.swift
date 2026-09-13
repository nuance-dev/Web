import SwiftUI
import WebKit

struct SafeBrowsingWarningView: View {
    let threat: SafeBrowsingManager.ThreatMatch
    let url: URL
    let onGoBack: () -> Void
    let onProceedWithRisk: () -> Void
    let onAddException: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Site blocked", systemImage: "exclamationmark.shield")
                .font(.title3.weight(.semibold))
            Text(url.host ?? "Unknown site")
                .font(.system(.body, design: .monospaced)).textSelection(.enabled).lineLimit(2)
            Text("Google Safe Browsing reported \(threat.threatType.userFriendlyName.lowercased()) on this site.")
                .font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("Details", isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(url.absoluteString)
                    Text(threat.detectedAt, format: .dateTime)
                }
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }
            HStack {
                Spacer()
                Button("Go back", action: onGoBack)
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 410)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onExitCommand(perform: onGoBack)
    }
}

struct SafeBrowsingWarningSheet: View {
    @State private var isPresented = false
    @State private var currentThreat: SafeBrowsingManager.ThreatMatch?
    @State private var currentURL: URL?
    
    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                if let threat = currentThreat,
                   let url = currentURL {
                    SafeBrowsingWarningView(
                        threat: threat,
                        url: url,
                        onGoBack: {
                            // Handle go back (safe option)
                            isPresented = false
                        },
                        onProceedWithRisk: {
                            // Handle proceed with risk
                            NotificationCenter.default.post(
                                name: .safeBrowsingUserOverride,
                                object: nil,
                                userInfo: [
                                    "action": "proceed",
                                    "url": url,
                                    "threat": threat
                                ]
                            )
                            isPresented = false
                        },
                        onAddException: {
                            // Handle always allow
                            SafeBrowsingManager.shared.addUserOverride(for: url)
                            NotificationCenter.default.post(
                                name: .safeBrowsingUserOverride,
                                object: nil,
                                userInfo: [
                                    "action": "exception",
                                    "url": url,
                                    "threat": threat
                                ]
                            )
                            isPresented = false
                        }
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .safeBrowsingThreatDetected)) { notification in
                if let threat = notification.userInfo?["threat"] as? SafeBrowsingManager.ThreatMatch,
                   let url = notification.userInfo?["url"] as? URL {
                    
                    currentThreat = threat
                    currentURL = url
                    isPresented = true
                }
            }
    }
}
