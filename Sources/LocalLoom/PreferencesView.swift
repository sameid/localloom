import SwiftUI

struct PreferencesView: View {
    @ObservedObject var ngrokConfig: NgrokConfig
    @ObservedObject var serverConfig: ServerConfig
    @Environment(\.dismiss) private var dismiss

    @State private var connectionStatus: String?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("LocalLoom Preferences")
                .font(.title2)
                .fontWeight(.semibold)

            GroupBox("Destination") {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Share recordings from", selection: $serverConfig.destination) {
                        ForEach(Destination.allCases) { destination in
                            Text(destination.label).tag(destination)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    Text(serverConfig.destination == .thisMac
                         ? "Recordings stay on this Mac and are shared through ngrok. Links only work while this Mac is awake and online."
                         : "Recordings are uploaded to a localloom-server you host, so links keep working when this Mac is off.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            if serverConfig.destination == .thisMac {
                ngrokSection
            } else {
                serverSection
            }

            GroupBox("About") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("LocalLoom records your screen and creates shareable links.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Text("Recordings on this Mac:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Open") {
                            NSWorkspace.shared.open(Recording.pendingDirectory.deletingLastPathComponent())
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
        .frame(width: 440)
    }

    private var ngrokSection: some View {
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
                    TextField("Optional, e.g. you.ngrok-free.app", text: $ngrokConfig.subdomain)
                        .textFieldStyle(.roundedBorder)
                    Text("Leave empty to use your ngrok account's free domain.")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
    }

    private var serverSection: some View {
        GroupBox("Server") {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server URL")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("https://loom.example.com", text: $serverConfig.serverURL)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Token")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField("The token file in the server's data folder", text: $serverConfig.serverToken)
                        .textFieldStyle(.roundedBorder)
                }

                if serverConfig.serverBaseURL?.scheme?.lowercased() == "http" {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                        Text("Plain HTTP sends your token unencrypted, and macOS only allows it for local network addresses. Use HTTPS for anything on the internet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack {
                    Button(isTesting ? "Testing…" : "Test Connection") {
                        testConnection()
                    }
                    .disabled(isTesting || serverConfig.serverClient == nil)

                    if let connectionStatus {
                        Text(connectionStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }

                Text("Run localloom-server on your own machine; see server/README.md.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(8)
        }
    }

    private func testConnection() {
        guard let client = serverConfig.serverClient else { return }
        isTesting = true
        connectionStatus = nil
        Task { @MainActor in
            do {
                try await client.status()
                connectionStatus = "Connected"
            } catch {
                connectionStatus = error.localizedDescription
            }
            isTesting = false
        }
    }
}
