import SwiftUI
import AppKit

struct MenuBarView: View {
    @ObservedObject var recordingManager: RecordingManager
    @ObservedObject var ngrokManager: NgrokManager
    @ObservedObject var serverConfig: ServerConfig
    @ObservedObject var bundledServer: BundledServer

    var onCopyLink: ((Recording) -> Void)?
    var onOpenPreferences: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Record / Stop button
            Button(action: {
                recordingManager.toggleRecording()
            }) {
                HStack {
                    if recordingManager.isRecording {
                        Image(systemName: "stop.circle.fill")
                            .foregroundColor(.red)
                        Text("Stop Recording")
                    } else {
                        Image(systemName: "record.circle")
                            .foregroundColor(.red)
                        Text("Start Recording")
                    }
                    Spacer()
                    Text("Cmd+Shift+L")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Divider()
                .padding(.vertical, 4)

            // Destination status
            if serverConfig.destination == .thisMac {
                HStack {
                    Circle()
                        .fill(ngrokManager.isRunning ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(ngrokManager.isRunning ? "Tunnel active" : "Tunnel inactive")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let url = ngrokManager.publicURL {
                        Spacer()
                        Text(url.replacingOccurrences(of: "https://", with: ""))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            } else {
                HStack {
                    Image(systemName: "server.rack")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(serverConfig.serverBaseURL?.host.map { "Uploading to \($0)" } ?? "No server set")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }

            // Error display
            if let error = recordingManager.lastError ?? destinationError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
            }

            Divider()
                .padding(.vertical, 4)

            // Recent recordings
            if recordingManager.recordings.isEmpty {
                Text("No recordings yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
            } else {
                Text("Recent Recordings")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)

                ForEach(recordingManager.recordings.prefix(10)) { recording in
                    RecordingRow(
                        recording: recording,
                        progress: recordingManager.uploadProgress[recording.id],
                        error: recordingManager.uploadErrors[recording.id],
                        onCopyLink: { onCopyLink?(recording) },
                        onRetry: { recordingManager.retryUploads() },
                        onDelete: { recordingManager.deleteRecording(recording) }
                    )
                }
            }

            Divider()
                .padding(.vertical, 4)

            // Preferences
            Button(action: {
                onOpenPreferences?()
            }) {
                HStack {
                    Image(systemName: "gear")
                    Text("Preferences...")
                }
            }

            Divider()
                .padding(.vertical, 4)

            // Quit
            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                HStack {
                    Image(systemName: "power")
                    Text("Quit LocalLoom")
                }
            }
            .keyboardShortcut("q")
        }
        .padding(8)
        .frame(width: 300)
    }

    private var destinationError: String? {
        guard serverConfig.destination == .thisMac else { return nil }
        return bundledServer.lastError ?? ngrokManager.lastError
    }
}

struct RecordingRow: View {
    let recording: Recording
    let progress: Double?
    let error: String?
    let onCopyLink: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.id)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.medium)
                HStack(spacing: 8) {
                    Text(recording.formattedDuration)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(recording.formattedDate)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let status = uploadStatus {
                        Text(status)
                            .font(.caption2)
                            .foregroundColor(error == nil ? .secondary : .red)
                    }
                }
            }

            Spacer()

            if let error {
                Button(action: onRetry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Upload failed: \(error) Click to retry.")
            }

            Button(action: onCopyLink) {
                Image(systemName: "link")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Copy shareable link")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete recording")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
    }

    private var uploadStatus: String? {
        if recording.isUploaded { return nil }
        if error != nil { return "Upload failed" }
        if let progress { return "Uploading \(Int(progress * 100))%" }
        return "Waiting to upload"
    }
}
