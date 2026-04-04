import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreGraphics

class ScreenRecorder: NSObject, @unchecked Sendable {
    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    // All mutable state below is touched exclusively on writerQueue
    private var writerState: WriterState = .idle

    // Single serial queue that owns ALL writer mutations and ALL sample buffer appends.
    // Both SCStreamOutput callbacks funnel through here so startWriting is called exactly once.
    private let writerQueue = DispatchQueue(label: "com.localloom.assetwriter", qos: .userInitiated)

    private(set) var isRecording = false        // main-thread only
    private(set) var currentRecording: Recording?

    var onRecordingStarted: (() -> Void)?
    var onRecordingStopped: ((Recording) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Public API (called on main thread)

    func startRecording() {
        guard !isRecording else { return }

        SCShareableContent.getWithCompletionHandler { [weak self] content, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async { self.onError?(error) }
                return
            }

            guard let display = content?.displays.first else {
                DispatchQueue.main.async { self.onError?(RecorderError.noDisplayFound) }
                return
            }

            do {
                try self.setupAndStart(display: display)
            } catch {
                DispatchQueue.main.async { self.onError?(error) }
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false

        stream?.stopCapture { [weak self] error in
            if let error = error {
                print("[ScreenRecorder] stopCapture error: \(error.localizedDescription)")
            }
            self?.finalizeRecording()
        }
    }

    // MARK: - Setup

    private func setupAndStart(display: SCDisplay) throws {
        let recording = Recording.newRecording()
        self.currentRecording = recording

        // SCDisplay.width/height are in logical points. SCKit delivers sample buffers
        // at the backing pixel resolution, which we need to match in AVAssetWriter's
        // video settings. We derive pixel dimensions from NSScreen's backingScaleFactor
        // and round up to the nearest even number (H.264 requires even dimensions).
        let scale = NSScreen.main?.backingScaleFactor ?? 1.0
        let pixelWidth  = makeEven(Int(Double(display.width)  * scale))
        let pixelHeight = makeEven(Int(Double(display.height) * scale))

        print("[ScreenRecorder] Display logical: \(display.width)x\(display.height), scale: \(scale), pixels: \(pixelWidth)x\(pixelHeight)")

        let config = SCStreamConfiguration()
        // Set the stream to deliver frames at the exact pixel size we want.
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2

        // AVAssetWriter -- created here but NOT started yet.
        // startWriting() is called the first time a sample buffer arrives on writerQueue.
        let tempURL = recording.tempFileURL

        // Remove stale temp file if one exists from a previous crashed session
        try? FileManager.default.removeItem(at: tempURL)

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mp4)

        // Video settings must use the same pixel dimensions as the stream config.
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ] as [String: Any],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw RecorderError.writerCantAddInputs
        }
        writer.add(videoInput)
        writer.add(audioInput)

        // Commit to writerQueue atomically before SCStream can deliver any buffers
        writerQueue.sync {
            self.assetWriter = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.writerState = .waitingForFirstBuffer
        }

        // Both output types share the same writerQueue so startWriting is called once
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scStream = SCStream(filter: filter, configuration: config, delegate: self)
        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: writerQueue)
        try scStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writerQueue)
        self.stream = scStream

        scStream.startCapture { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { self.onError?(error) }
                return
            }
            DispatchQueue.main.async {
                self.isRecording = true
                self.onRecordingStarted?()
            }
        }
    }

    // MARK: - Finalization

    private func finalizeRecording() {
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            guard let writer = self.assetWriter else { return }

            // Mark inputs finished before calling finishWriting
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            self.writerState = .finishing

            guard writer.status == .writing else {
                let writerError = writer.error
                let ns = writerError.map { $0 as NSError }
                print("[ScreenRecorder] Writer in state \(writer.status.rawValue) — error: \(ns?.domain ?? "-") \(ns?.code ?? 0): \(ns?.localizedDescription ?? "none")")
                DispatchQueue.main.async {
                    self.onError?(writerError.map { RecorderError.writerError($0) } ?? RecorderError.writerFailed)
                }
                self.cleanupOnQueue()
                return
            }

            let semaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { semaphore.signal() }
            semaphore.wait()

            if writer.status != .completed {
                let writerError = writer.error
                let ns = writerError.map { $0 as NSError }
                print("[ScreenRecorder] finishWriting failed — \(ns?.domain ?? "-") \(ns?.code ?? 0): \(ns?.localizedDescription ?? "unknown")")
                DispatchQueue.main.async {
                    self.onError?(writerError.map { RecorderError.writerError($0) } ?? RecorderError.writerFailed)
                }
                self.cleanupOnQueue()
                return
            }

            self.moveAndPublish()
        }
    }

    private func moveAndPublish() {
        // Still on writerQueue
        guard var recording = currentRecording else { return }

        let tempURL = recording.tempFileURL
        let finalURL = recording.fileURL

        do {
            // Load duration synchronously now that the file is complete
            // Load duration asynchronously (all synchronous AVAsset accessors are deprecated on macOS 13+)
            let asset = AVURLAsset(url: tempURL)
            var duration: Double = 0
            let durSemaphore = DispatchSemaphore(value: 0)
            Task {
                if let cmDuration = try? await asset.load(.duration) {
                    duration = CMTimeGetSeconds(cmDuration)
                }
                durSemaphore.signal()
            }
            durSemaphore.wait()
            recording.duration = duration > 0 ? duration : 0

            try FileManager.default.createDirectory(
                at: Recording.recordingsDirectory,
                withIntermediateDirectories: true
            )

            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: finalURL)
            recording.filePath = finalURL.path

            DispatchQueue.main.async {
                self.onRecordingStopped?(recording)
            }
        } catch {
            print("[ScreenRecorder] Error moving file: \(error.localizedDescription)")
            DispatchQueue.main.async { self.onError?(error) }
        }

        cleanupOnQueue()
    }

    /// Must be called on writerQueue
    private func cleanupOnQueue() {
        assetWriter = nil
        videoInput = nil
        audioInput = nil
        writerState = .idle
        currentRecording = nil
        stream = nil
    }
}

// MARK: - SCStreamOutput

extension ScreenRecorder: SCStreamOutput {
    // Called on writerQueue (we passed writerQueue as sampleHandlerQueue for both types)
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Drop buffers unless we're actively recording
        guard writerState == .waitingForFirstBuffer || writerState == .writing else { return }
        guard let writer = assetWriter else { return }
        guard sampleBuffer.isValid else { return }

        // Start the writer session exactly once on the very first buffer
        if writerState == .waitingForFirstBuffer {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            if writer.status == .failed {
                let writerError = writer.error
                let ns = writerError.map { $0 as NSError }
                print("[ScreenRecorder] startWriting failed — \(ns?.domain ?? "-") \(ns?.code ?? 0): \(ns?.localizedDescription ?? "unknown")")
                DispatchQueue.main.async { self.onError?(writerError.map { RecorderError.writerError($0) } ?? RecorderError.writerFailed) }
                cleanupOnQueue()
                return
            }
            writer.startSession(atSourceTime: timestamp)
            writerState = .writing
        }

        switch type {
        case .screen:
            if let input = videoInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        case .audio:
            if let input = audioInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        case .microphone:
            break
        @unknown default:
            break
        }
    }
}

// MARK: - SCStreamDelegate

extension ScreenRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[ScreenRecorder] Stream stopped with error: \(error.localizedDescription)")
        DispatchQueue.main.async {
            if self.isRecording {
                self.isRecording = false
                self.finalizeRecording()
            }
        }
    }
}

// MARK: - Writer state machine

private enum WriterState: Equatable {
    case idle
    case waitingForFirstBuffer
    case writing
    case finishing
}

// MARK: - Helpers

/// Round up to the nearest even integer (H.264 requires even dimensions)
private func makeEven(_ value: Int) -> Int {
    return value % 2 == 0 ? value : value + 1
}

// MARK: - Errors

enum RecorderError: LocalizedError {
    case noDisplayFound
    case writerCantAddInputs
    case writerFailed
    case writerError(Error)

    var errorDescription: String? {
        switch self {
        case .noDisplayFound:
            return "No display found for screen recording."
        case .writerCantAddInputs:
            return "AVAssetWriter rejected one or more inputs."
        case .writerFailed:
            return "Video writer failed unexpectedly."
        case .writerError(let underlying):
            let ns = underlying as NSError
            return "Video writer error (\(ns.domain) \(ns.code)): \(ns.localizedDescription)"
        }
    }
}
