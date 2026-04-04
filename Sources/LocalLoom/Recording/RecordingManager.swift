import Foundation
import SwiftUI

class RecordingManager: ObservableObject {
    @Published var isRecording = false
    @Published var recordings: [Recording] = []
    @Published var lastError: String?

    private let recorder = ScreenRecorder()
    private let storageKey = "LocalLoom.recordings"
    private let maxRecentRecordings = 10

    init() {
        loadRecordings()
        setupCallbacks()
    }

    private func setupCallbacks() {
        recorder.onRecordingStarted = { [weak self] in
            DispatchQueue.main.async {
                self?.isRecording = true
                NotificationHelper.shared.showNotification(
                    title: "Recording Started",
                    body: "Your screen is now being recorded. Press Cmd+Shift+L to stop."
                )
            }
        }

        recorder.onRecordingStopped = { [weak self] recording in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRecording = false
                self.recordings.insert(recording, at: 0)

                // Trim to max recent recordings
                if self.recordings.count > self.maxRecentRecordings {
                    let removed = self.recordings.removingSubrange(self.maxRecentRecordings...)
                    // Delete old files
                    for rec in removed {
                        try? FileManager.default.removeItem(at: rec.fileURL)
                    }
                }

                self.saveRecordings()

                // The link generation and clipboard copy will be done by the app coordinator
                NotificationHelper.shared.showNotification(
                    title: "Recording Saved",
                    body: "Recording saved! Duration: \(recording.formattedDuration)"
                )
            }
        }

        recorder.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.isRecording = false
                self?.lastError = error.localizedDescription
                NotificationHelper.shared.showNotification(
                    title: "Recording Error",
                    body: error.localizedDescription
                )
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        lastError = nil
        recorder.startRecording()
    }

    func stopRecording() {
        recorder.stopRecording()
    }

    func deleteRecording(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        try? FileManager.default.removeItem(at: recording.fileURL)
        saveRecordings()
    }

    func shareableURL(for recording: Recording, tunnelURL: String?) -> String {
        if let tunnel = tunnelURL {
            return "\(tunnel)/v/\(recording.id)"
        }
        return "http://localhost/v/\(recording.id)"
    }

    // MARK: - Persistence

    private func saveRecordings() {
        if let data = try? JSONEncoder().encode(recordings) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private func loadRecordings() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Recording].self, from: data) else {
            return
        }

        // Filter out recordings whose files no longer exist
        recordings = decoded.filter { FileManager.default.fileExists(atPath: $0.filePath) }
        if recordings.count != decoded.count {
            saveRecordings()
        }
    }
}

// Extension to allow removeSubrange to return the removed elements
private extension Array {
    @discardableResult
    mutating func removingSubrange(_ range: PartialRangeFrom<Int>) -> [Element] {
        let removed = Array(self[range])
        let rangeToRemove = range.lowerBound..<self.count
        self.removeSubrange(rangeToRemove)
        return removed
    }
}
