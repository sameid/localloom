import Foundation
import SwiftUI

class RecordingManager: ObservableObject {
    @Published var isRecording = false
    @Published var recordings: [Recording] = []
    /// Progress (0...1) of the recording currently uploading
    @Published var uploadProgress: [String: Double] = [:]
    /// Why the last attempt failed, for recordings waiting to be retried
    @Published var uploadErrors: [String: String] = [:]
    @Published var lastError: String?

    // Supplied by the app: where new recordings go, an API client for a destination (nil while
    // it isn't reachable), and a recording's public link (nil while it isn't known yet).
    var currentDestination: () -> Destination = { .thisMac }
    var clientFor: (Destination) -> ServerClient? = { _ in nil }
    var shareLink: (Recording) -> String? = { _ in nil }

    private let recorder = ScreenRecorder()
    private let storageKey = "LocalLoom.recordings.v2"
    private var uploadTask: Task<Void, Never>?
    private var retryWorkItem: DispatchWorkItem?
    private let retryDelay: TimeInterval = 30
    /// Fresh recordings whose link goes to the clipboard as soon as it's known
    private var linksToCopy: Set<String> = []

    init() {
        loadRecordings()
        migrateLegacyRecordings()
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

        recorder.onRecordingStopped = { [weak self] tempURL, duration in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRecording = false
                self.add(tempURL: tempURL, duration: duration)
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

    private func add(tempURL: URL, duration: TimeInterval) {
        do {
            let size = (try FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let recording = Recording(
                id: Recording.newID(),
                date: Date(),
                duration: duration,
                size: size,
                destination: currentDestination(),
                shareURL: nil,
                isUploaded: false
            )
            try FileManager.default.moveItem(at: tempURL, to: recording.pendingFileURL)

            recordings.insert(recording, at: 0)
            saveRecordings()
            linksToCopy.insert(recording.id)
            copyWaitingLinks()
            processUploads()
        } catch {
            lastError = "Couldn't save the recording: \(error.localizedDescription)"
        }
    }

    func deleteRecording(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        uploadErrors[recording.id] = nil
        linksToCopy.remove(recording.id)
        saveRecordings()
        try? FileManager.default.removeItem(at: recording.pendingFileURL)

        guard let client = clientFor(recording.destination) else {
            if recording.isUploaded {
                lastError = "Removed from the list, but \(recording.destination.label) isn't reachable, so the copy there wasn't deleted."
            }
            return
        }
        Task { @MainActor in
            do {
                try await client.delete(id: recording.id)
            } catch {
                self.lastError = "Couldn't delete the recording from the server: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Links

    /// Copies links that were waiting on the server or the tunnel. The app calls this again
    /// when the ngrok address becomes known.
    func copyWaitingLinks() {
        for id in linksToCopy {
            guard let recording = recordings.first(where: { $0.id == id }) else {
                linksToCopy.remove(id)
                continue
            }
            guard let link = shareLink(recording) else { continue }
            linksToCopy.remove(id)

            ClipboardHelper.copyToClipboard(link)
            let stillUploading = !recording.isUploaded && recording.destination == .server
            NotificationHelper.shared.showNotification(
                title: "Link Copied!",
                body: stillUploading ? "\(link)\nIt will play as soon as the upload finishes." : link
            )
        }
    }

    // MARK: - Uploads

    /// Uploads waiting recordings one at a time, newest first. Safe to call at any time;
    /// the app calls it whenever a destination may have become reachable.
    func processUploads() {
        guard uploadTask == nil else { return }
        uploadTask = Task { @MainActor in
            while let next = self.nextUpload() {
                await self.upload(next.recording, with: next.client)
            }
            self.uploadTask = nil
        }
    }

    /// Clears failures and tries again now instead of waiting for the automatic retry.
    func retryUploads() {
        retryWorkItem?.cancel()
        uploadErrors.removeAll()
        processUploads()
    }

    private func nextUpload() -> (recording: Recording, client: ServerClient)? {
        for recording in recordings where !recording.isUploaded && uploadErrors[recording.id] == nil {
            if let client = clientFor(recording.destination) {
                return (recording, client)
            }
        }
        return nil
    }

    @MainActor
    private func upload(_ recording: Recording, with client: ServerClient) async {
        let id = recording.id
        uploadProgress[id] = 0
        defer { uploadProgress[id] = nil }

        do {
            let remote = try await client.create(id: id, size: recording.size, duration: recording.duration)
            if recording.destination == .server {
                update(id) { $0.shareURL = remote.shareUrl }
                copyWaitingLinks()
            }

            if !remote.isReady {
                try await client.upload(id: id, file: recording.pendingFileURL, from: remote.offset, size: recording.size) { sent in
                    DispatchQueue.main.async {
                        guard self.uploadProgress[id] != nil else { return }
                        self.uploadProgress[id] = Double(sent) / Double(max(recording.size, 1))
                    }
                }
                _ = try await client.complete(id: id)
            }

            guard recordings.contains(where: { $0.id == id }) else { return } // Deleted meanwhile
            update(id) { $0.isUploaded = true }
            try? FileManager.default.removeItem(at: recording.pendingFileURL)

            if recording.destination == .server {
                NotificationHelper.shared.showNotification(
                    title: "Upload Finished",
                    body: "Your recording is ready to watch."
                )
            }
        } catch {
            guard recordings.contains(where: { $0.id == id }) else { return }
            print("[RecordingManager] Upload of \(id) failed: \(error)")
            uploadErrors[id] = error.localizedDescription

            // Tell the user once, rather than copying a link minutes later out of nowhere.
            if linksToCopy.remove(id) != nil {
                NotificationHelper.shared.showNotification(
                    title: "Upload Failed",
                    body: "\(error.localizedDescription) LocalLoom will keep retrying."
                )
            }
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        retryWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.retryUploads() }
        retryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
    }

    private func update(_ id: String, _ change: (inout Recording) -> Void) {
        guard let index = recordings.firstIndex(where: { $0.id == id }) else { return }
        change(&recordings[index])
        saveRecordings()
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
        recordings = decoded
    }

    /// Recordings from before the server existed are uploaded to the server on this Mac under
    /// their old IDs, so links that were already shared keep working.
    private func migrateLegacyRecordings() {
        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: LegacyRecording.storageKey) else { return }
        let legacy = (try? JSONDecoder().decode([LegacyRecording].self, from: data)) ?? []
        let fm = FileManager.default

        for old in legacy where !recordings.contains(where: { $0.id == old.id }) {
            guard let size = (try? fm.attributesOfItem(atPath: old.filePath))?[.size] as? NSNumber else { continue }
            let recording = Recording(
                id: old.id,
                date: old.date,
                duration: old.duration,
                size: size.int64Value,
                destination: .thisMac,
                shareURL: nil,
                isUploaded: false
            )
            do {
                try fm.moveItem(at: URL(fileURLWithPath: old.filePath), to: recording.pendingFileURL)
                recordings.append(recording)
            } catch {
                print("[RecordingManager] Couldn't migrate recording \(old.id): \(error.localizedDescription)")
            }
        }

        recordings.sort { $0.date > $1.date }
        saveRecordings()
        defaults.removeObject(forKey: LegacyRecording.storageKey)
        let legacyDir = LegacyRecording.recordingsDirectory
        if (try? fm.contentsOfDirectory(atPath: legacyDir.path))?.isEmpty == true {
            try? fm.removeItem(at: legacyDir)
        }
    }
}
