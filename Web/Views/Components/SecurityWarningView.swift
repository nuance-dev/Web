import SwiftUI
import WebKit

struct SecurityWarningView: View {
    let challenge: URLAuthenticationChallenge
    let error: CertificateManager.CertificateError
    let host: String
    let port: Int
    let onProceedWithRisk: () -> Void
    let onGoBack: () -> Void
    let onAlwaysAllow: () -> Void
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connection isn’t secure", systemImage: "lock.slash")
                .font(.title3.weight(.semibold))
            Text(host).font(.system(.body, design: .monospaced))
                .textSelection(.enabled).lineLimit(2)
            Text("Web couldn’t verify this site’s certificate. The page was blocked.")
                .font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("Details", isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error.localizedDescription)
                    Text("Port \(port)")
                    if let trust = challenge.protectionSpace.serverTrust,
                       let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                       let certificate = certificates.first,
                       let subject = SecCertificateCopySubjectSummary(certificate) {
                        Text(subject as String)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
            HStack {
                Spacer()
                Button("Go back", action: onGoBack)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 410)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .onExitCommand(perform: onGoBack)
    }
}

struct SecurityWarningSheet: View {
    @State private var isPresented = false
    @State private var currentChallenge: URLAuthenticationChallenge?
    @State private var currentError: CertificateManager.CertificateError?
    @State private var currentHost: String?
    @State private var currentPort: Int?
    
    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                if let challenge = currentChallenge,
                   let error = currentError,
                   let host = currentHost,
                   let port = currentPort {
                    SecurityWarningView(
                        challenge: challenge,
                        error: error,
                        host: host,
                        port: port,
                        onProceedWithRisk: {
                            // Handle proceed with risk
                            NotificationCenter.default.post(
                                name: .userGrantedTemporaryCertificateException,
                                object: nil,
                                userInfo: ["challenge": challenge]
                            )
                            isPresented = false
                        },
                        onGoBack: {
                            // Handle go back (safe option)
                            isPresented = false
                        },
                        onAlwaysAllow: {
                            // Handle always allow
                            CertificateManager.shared.grantException(for: host, port: port)
                            NotificationCenter.default.post(
                                name: .userGrantedCertificateException,
                                object: nil,
                                userInfo: ["challenge": challenge, "host": host, "port": port]
                            )
                            isPresented = false
                        }
                    )
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showCertificateSecurityWarning)) { notification in
                if let challenge = notification.userInfo?["challenge"] as? URLAuthenticationChallenge,
                   let error = notification.userInfo?["error"] as? CertificateManager.CertificateError,
                   let host = notification.userInfo?["host"] as? String,
                   let port = notification.userInfo?["port"] as? Int {
                    
                    currentChallenge = challenge
                    currentError = error
                    currentHost = host
                    currentPort = port
                    isPresented = true
                }
            }
    }
}

// MARK: - Additional Notification Names

extension Notification.Name {
    static let userGrantedTemporaryCertificateException = Notification.Name("userGrantedTemporaryCertificateException")
}
