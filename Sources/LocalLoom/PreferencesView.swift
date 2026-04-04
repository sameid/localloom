import SwiftUI

struct PreferencesView: View {
    @ObservedObject var ngrokConfig: NgrokConfig
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("LocalLoom Preferences")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("ngrok Configuration") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Auth Token")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        SecureField("Paste your ngrok authtoken", text: $ngrokConfig.authtoken)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Domain")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("e.g., localloom or myapp.ngrok-free.app", text: $ngrokConfig.subdomain)
                            .textFieldStyle(.roundedBorder)
                    }

                    if !ngrokConfig.isConfigured {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                                .font(.caption)
                            Text("An ngrok authtoken is required to share recordings.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Link("Get your free authtoken at ngrok.com",
                         destination: URL(string: "https://dashboard.ngrok.com/get-started/your-authtoken")!)
                        .font(.caption)
                }
                .padding(8)
            }

            GroupBox("About") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LocalLoom records your screen and creates shareable links.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Recordings are stored locally and served from your machine through ngrok.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Text("Recordings folder:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Open") {
                            NSWorkspace.shared.open(Recording.recordingsDirectory)
                        }
                        .font(.caption)
                    }
                }
                .padding(8)
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
