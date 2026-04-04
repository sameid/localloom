import Foundation

struct Recording: Identifiable, Codable {
    let id: String
    let fileName: String
    let date: Date
    var duration: TimeInterval
    var filePath: String

    var fileURL: URL {
        URL(fileURLWithPath: filePath)
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

    static func newRecording() -> Recording {
        let id = UUID().uuidString.prefix(8).lowercased()
        let fileName = "\(id).mp4"
        let recordingsDir = Recording.recordingsDirectory
        let filePath = recordingsDir.appendingPathComponent(fileName).path

        return Recording(
            id: String(id),
            fileName: fileName,
            date: Date(),
            duration: 0,
            filePath: filePath
        )
    }

    static var recordingsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("LocalLoom/recordings")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var tempFileURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("localloom_\(id).mp4")
    }
}
