import XCTest
@testable import LocalLoom

/// Runs the app's ServerClient against the real server in server/, using `node` from PATH.
final class ServerClientTests: XCTestCase {
    private var server: Process!
    private var dataDir: URL!
    private var baseURL: URL!

    override func setUpWithError() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LocalLoomTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("localloom-\(UUID().uuidString)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", repo.appendingPathComponent("server/src/index.js").path]
        var environment = ProcessInfo.processInfo.environment
        environment["LOCALLOOM_DATA_DIR"] = dataDir.path
        environment["LOCALLOOM_HOST"] = "127.0.0.1"
        environment["LOCALLOOM_PORT"] = "0"
        environment["LOCALLOOM_TOKEN"] = "test-token"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        server = process

        // Wait for {"msg":"listening","port":N}
        var buffer = ""
        while !buffer.contains("\"listening\"") {
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { throw XCTSkip("Server exited; is node on PATH?") }
            buffer += String(decoding: data, as: UTF8.self)
        }
        let line = buffer.split(separator: "\n").first { $0.contains("\"listening\"") }!
        let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        baseURL = URL(string: "http://127.0.0.1:\(json["port"] as! Int)")!
    }

    override func tearDownWithError() throws {
        server?.terminate()
        server?.waitUntilExit()
        try? FileManager.default.removeItem(at: dataDir)
    }

    private func makeClient(token: String = "test-token") -> ServerClient {
        var client = ServerClient(baseURL: baseURL, token: token)
        client.chunkSize = 256 * 1024
        return client
    }

    private func makeFile(size: Int) throws -> (URL, Data) {
        let data = Data((0..<size).map { _ in UInt8.random(in: 0...255) })
        let url = dataDir.appendingPathComponent("\(UUID().uuidString).mp4")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try data.write(to: url)
        return (url, data)
    }

    private func download(_ id: String) async throws -> Data {
        try await URLSession.shared.data(from: baseURL.appendingPathComponent("media/\(id).mp4")).0
    }

    func testChunkedUploadThenPlayback() async throws {
        let client = makeClient()
        let (file, data) = try makeFile(size: 1_000_000)
        let id = Recording.newID()

        let created = try await client.create(id: id, size: Int64(data.count), duration: 12)
        XCTAssertEqual(created.offset, 0)
        XCTAssertEqual(created.shareUrl, "\(baseURL!)/v/\(id)")

        var reported: [Int64] = []
        try await client.upload(id: id, file: file, from: 0, size: Int64(data.count)) { reported.append($0) }
        XCTAssertEqual(reported.count, 4) // 1 MB in 256 KB chunks
        let completed = try await client.complete(id: id)
        XCTAssertTrue(completed.isReady)
        let downloaded = try await download(id)
        XCTAssertEqual(downloaded, data)
    }

    func testResumesFromServerOffsetAfterInterruption() async throws {
        let client = makeClient()
        let (file, data) = try makeFile(size: 600_000)
        let id = Recording.newID()
        _ = try await client.create(id: id, size: Int64(data.count), duration: 1)

        // First attempt stops after one chunk, as if the connection dropped.
        try await client.upload(id: id, file: file, from: 0, size: 256 * 1024) { _ in }

        // A retry that has lost track of progress starts from 0; the server corrects it.
        let retried = try await client.create(id: id, size: Int64(data.count), duration: 1)
        XCTAssertEqual(retried.offset, 256 * 1024)
        try await client.upload(id: id, file: file, from: 0, size: Int64(data.count)) { _ in }
        _ = try await client.complete(id: id)
        let downloaded = try await download(id)
        XCTAssertEqual(downloaded, data)
    }

    func testDeleteIsIdempotent() async throws {
        let client = makeClient()
        let id = Recording.newID()
        _ = try await client.create(id: id, size: 10, duration: 0)
        try await client.delete(id: id)
        try await client.delete(id: id) // 404 is treated as already gone
    }

    func testWrongTokenExplainsItself() async throws {
        do {
            try await makeClient(token: "wrong").status()
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "The server rejected the token. Check it in Preferences.")
        }
    }

    func testNewIDsAreURLSafe128Bit() {
        let id = Recording.newID()
        XCTAssertEqual(id.count, 22)
        XCTAssertNil(id.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }
}
