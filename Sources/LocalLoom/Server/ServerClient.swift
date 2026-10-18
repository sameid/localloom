import Foundation

/// Talks to a localloom-server: the one the app runs on this Mac, or one the user hosts.
struct ServerClient {
    let baseURL: URL
    let token: String
    /// Stays under Cloudflare's 100 MB request limit, a common way to expose a homelab.
    var chunkSize = 32 * 1024 * 1024

    struct RemoteRecording: Decodable {
        let id: String
        let size: Int64
        let status: String
        let offset: Int64
        let shareUrl: String

        var isReady: Bool { status == "ready" }
    }

    private struct OffsetResponse: Decodable { let offset: Int64 }
    private struct ErrorResponse: Decodable { let error: String; let offset: Int64? }

    func status() async throws {
        _ = try await send("GET", "api/status")
    }

    /// Reserves the recording on the server. Safe to repeat: the server returns the existing
    /// recording (and how much of it has arrived) when the id and size match.
    func create(id: String, size: Int64, duration: TimeInterval) async throws -> RemoteRecording {
        let body = try JSONSerialization.data(withJSONObject: ["id": id, "size": size, "duration": duration])
        return try decode(await send("POST", "api/recordings", body: body, contentType: "application/json"))
    }

    func complete(id: String) async throws -> RemoteRecording {
        try decode(await send("POST", "api/recordings/\(id)/complete"))
    }

    func delete(id: String) async throws {
        do {
            _ = try await send("DELETE", "api/recordings/\(id)")
        } catch ServerClientError.http(404, _, _) {
            // Already gone
        }
    }

    /// Uploads `file` in chunks starting at `offset`. If the server reports a different
    /// offset (say, a chunk landed but its response was lost), resumes from the server's.
    func upload(
        id: String,
        file: URL,
        from offset: Int64,
        size: Int64,
        progress: @escaping (Int64) -> Void
    ) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        var offset = offset
        var resyncs = 0
        while offset < size {
            try handle.seek(toOffset: UInt64(offset))
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                throw ServerClientError.fileTooShort
            }
            do {
                let data = try await send(
                    "PUT", "api/recordings/\(id)/content",
                    body: chunk,
                    contentType: "application/octet-stream",
                    headers: ["Upload-Offset": String(offset)]
                )
                offset = try JSONDecoder().decode(OffsetResponse.self, from: data).offset
                resyncs = 0
                progress(offset)
            } catch ServerClientError.http(409, _, let serverOffset?) where resyncs < 3 {
                resyncs += 1
                offset = serverOffset
            }
        }
    }

    private func send(
        _ method: String,
        _ path: String,
        body: Data? = nil,
        contentType: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        if let body {
            (data, response) = try await URLSession.shared.upload(for: request, from: body)
        } else {
            (data, response) = try await URLSession.shared.data(for: request)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ServerClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw ServerClientError.http(
                status: http.statusCode,
                message: error?.error ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
                offset: error?.offset
            )
        }
        return data
    }

    private func decode(_ data: Data) throws -> RemoteRecording {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(RemoteRecording.self, from: data)
    }
}

enum ServerClientError: LocalizedError {
    case http(status: Int, message: String, offset: Int64?)
    case invalidResponse
    case fileTooShort

    var errorDescription: String? {
        switch self {
        case .http(401, _, _):
            return "The server rejected the token. Check it in Preferences."
        case .http(let status, let message, _):
            return "Server error \(status): \(message)"
        case .invalidResponse:
            return "Unexpected response from the server."
        case .fileTooShort:
            return "The recording file is shorter than expected."
        }
    }
}
