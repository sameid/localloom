import Foundation
import Swifter

class LocalServer {
    private var server: HttpServer?
    private(set) var port: UInt16 = 0
    private let recordingsDirectory: URL

    var getRecordings: (() -> [Recording])?

    init() {
        self.recordingsDirectory = Recording.recordingsDirectory
    }

    func start() throws -> UInt16 {
        let server = HttpServer()
        self.server = server

        setupRoutes(server)

        // Try ports in range 9400-9500
        var lastError: Error?
        for candidatePort in UInt16(9400)...UInt16(9500) {
            do {
                try server.start(candidatePort, forceIPv4: false, priority: .default)
                self.port = candidatePort
                print("[LocalServer] Started on port \(candidatePort)")
                return candidatePort
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? ServerError.couldNotStart
    }

    func stop() {
        server?.stop()
        server = nil
        print("[LocalServer] Stopped")
    }

    private func setupRoutes(_ server: HttpServer) {
        // GET / — never reveal recordings; a share link is the only way to reach one
        server["/"] = { _ in
            return .ok(.html(VideoPlayerHTML.notFoundPage()))
        }

        // GET /v/:id — HTML video player page
        server["/v/:id"] = { [weak self] request in
            guard let self = self else { return .notFound }
            guard let recordingId = request.params[":id"] else {
                return .notFound
            }

            let recordings = self.getRecordings?() ?? []
            guard recordings.contains(where: { $0.id == recordingId }) else {
                return .ok(.html(VideoPlayerHTML.notFoundPage()))
            }

            return .ok(.html(VideoPlayerHTML.page(recordingId: recordingId)))
        }

        // GET /media/:filename — serve video file with range request support
        server["/media/:filename"] = { [weak self] request in
            guard let self = self else { return .notFound }
            guard let filename = request.params[":filename"] else {
                return .notFound
            }

            // Only serve files that belong to a known recording. Swifter percent-decodes
            // path params after splitting, so "..%2F" would otherwise escape the folder.
            guard let recording = self.getRecordings?().first(where: { $0.fileName == filename }) else {
                return .notFound
            }
            let filePath = recording.fileURL.path

            guard FileManager.default.fileExists(atPath: filePath) else {
                return .notFound
            }

            guard let fileHandle = FileHandle(forReadingAtPath: filePath) else {
                return .internalServerError
            }

            let fileAttributes = try? FileManager.default.attributesOfItem(atPath: filePath)
            let fileSize = (fileAttributes?[.size] as? UInt64) ?? 0

            // Check for Range header
            if let rangeHeader = request.headers["range"] {
                return self.handleRangeRequest(
                    rangeHeader: rangeHeader,
                    fileHandle: fileHandle,
                    fileSize: fileSize
                )
            }

            // Full file response
            fileHandle.seekToEndOfFile()
            let endOffset = fileHandle.offsetInFile
            fileHandle.seek(toFileOffset: 0)
            let data = fileHandle.readDataToEndOfFile()
            fileHandle.closeFile()

            return HttpResponse.raw(200, "OK", [
                "Content-Type": "video/mp4",
                "Content-Length": "\(endOffset)",
                "Accept-Ranges": "bytes",
                "Cache-Control": "no-cache",
            ]) { writer in
                try writer.write(data)
            }
        }
    }

    private func handleRangeRequest(
        rangeHeader: String,
        fileHandle: FileHandle,
        fileSize: UInt64
    ) -> HttpResponse {
        // Parse "bytes=start-end" or "bytes=start-"
        let rangeString = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
        let parts = rangeString.split(separator: "-", maxSplits: 1)

        guard let startStr = parts.first, let start = UInt64(startStr) else {
            fileHandle.closeFile()
            return .raw(416, "Range Not Satisfiable", [
                "Content-Range": "bytes */\(fileSize)"
            ], { _ in })
        }

        let end: UInt64
        if parts.count > 1, let endVal = UInt64(parts[1]) {
            end = min(endVal, fileSize - 1)
        } else {
            end = fileSize - 1
        }

        guard start <= end, start < fileSize else {
            fileHandle.closeFile()
            return .raw(416, "Range Not Satisfiable", [
                "Content-Range": "bytes */\(fileSize)"
            ], { _ in })
        }

        let contentLength = end - start + 1

        fileHandle.seek(toFileOffset: start)
        let data = fileHandle.readData(ofLength: Int(contentLength))
        fileHandle.closeFile()

        return .raw(206, "Partial Content", [
            "Content-Type": "video/mp4",
            "Content-Length": "\(contentLength)",
            "Content-Range": "bytes \(start)-\(end)/\(fileSize)",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-cache",
        ]) { writer in
            try writer.write(data)
        }
    }
}

enum ServerError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return "Could not start the local HTTP server. All ports in range 9400-9500 are in use."
        }
    }
}
