import Foundation
import Security

struct Recording: Identifiable, Codable {
    let id: String
    let date: Date
    var duration: TimeInterval
    let size: Int64
    /// Fixed when the recording is made, so switching modes later doesn't move it.
    let destination: Destination
    /// The share link a self-hosted server returned. "This Mac" links are built from the
    /// ngrok address instead, since the local server can't know it.
    var shareURL: String?
    var isUploaded: Bool

    /// Where the file waits until the server has all of it.
    var pendingFileURL: URL {
        Recording.pendingDirectory.appendingPathComponent("\(id).mp4")
    }

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// 128 random bits, base64url. The share link is the only thing protecting a recording.
    static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static var pendingDirectory: URL {
        let dir = applicationSupport.appendingPathComponent("LocalLoom/pending")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var newTempFileURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("localloom_\(UUID().uuidString).mp4")
    }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }
}

/// How recordings were stored before the server existed: files served straight from disk.
struct LegacyRecording: Codable {
    let id: String
    let date: Date
    let duration: TimeInterval
    let filePath: String

    static let storageKey = "LocalLoom.recordings"

    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LocalLoom/recordings")
    }
}
