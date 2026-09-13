import SwiftUI

struct SecuritySettingsView: View {
    var body: some View {
        ScrollView { BasicSecuritySettingsView().padding(10) }
            .frame(minWidth: 360, minHeight: 380)
    }
}
