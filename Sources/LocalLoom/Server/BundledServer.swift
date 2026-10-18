import Foundation

/// Runs localloom-server privately on this Mac, bound to 127.0.0.1, for the "This Mac" mode.
/// ngrok then exposes it, exactly as it would expose a server anywhere else.
class BundledServer: ObservableObject {
    /// 0 until the server is listening.
    @Published private(set) var port: UInt16 = 0
    @Published var lastError: String?

    /// Called on the main thread each time the server starts listening.
    var onReady: ((UInt16) -> Void)?

    static var dataDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("LocalLoom/server")
    }

    private var process: Process?
    private var stdinPipe: Pipe?
    private var lineBuffer = ""
    private var token = ""
    private var lastPort: UInt16 = 0
    private var isShuttingDown = false
    private var retryCount = 0
    private let maxRetries = 3

    func start(token: String) {
        guard process == nil else { return }
        self.token = token
        isShuttingDown = false
        retryCount = 0
        launch()
    }

    func stop() {
        isShuttingDown = true
        let running = process
        process = nil
        stdinPipe = nil
        if running?.isRunning == true { running?.terminate() }
        port = 0
    }

    private func launch() {
        guard let located = locate() else {
            lastError = "The bundled server is missing. Rebuild the app with make-app.sh."
            return
        }
        let (node, script) = located

        let process = Process()
        process.executableURL = node
        process.arguments = [script.path]

        var environment = ProcessInfo.processInfo.environment
        environment["NODE_OPTIONS"] = nil
        environment["LOCALLOOM_DATA_DIR"] = Self.dataDirectory.path
        environment["LOCALLOOM_HOST"] = "127.0.0.1"
        // After a crash, reuse the old port so the ngrok tunnel still points at it.
        environment["LOCALLOOM_PORT"] = String(lastPort)
        environment["LOCALLOOM_TOKEN"] = token
        // The server exits when our end of its stdin closes, i.e. when this app quits or crashes.
        environment["LOCALLOOM_EXIT_WITH_PARENT"] = "1"
        process.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        lineBuffer = ""

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            self?.processChunk(chunk)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if let text = String(data: data, encoding: .utf8) {
                print("[BundledServer] stderr: \(text)")
            }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self, self.process === proc else { return } // Stopped on purpose
                print("[BundledServer] Exited with code \(proc.terminationStatus)")

                // If it never started listening, the old port may be taken; let it pick a new one.
                if self.port == 0 { self.lastPort = 0 }
                self.process = nil
                self.stdinPipe = nil
                self.port = 0

                guard !self.isShuttingDown else { return }
                if self.retryCount < self.maxRetries {
                    self.retryCount += 1
                    let delay = pow(2.0, Double(self.retryCount))
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard !self.isShuttingDown, self.process == nil else { return }
                        self.launch()
                    }
                } else {
                    self.lastError = "The local server keeps stopping. Check Console for [BundledServer] logs."
                }
            }
        }

        do {
            self.process = process
            self.stdinPipe = inPipe
            try process.run()
            print("[BundledServer] Started PID \(process.processIdentifier): \(node.path) \(script.path)")
        } catch {
            self.process = nil
            self.stdinPipe = nil
            lastError = "Failed to start the local server: \(error.localizedDescription)"
        }
    }

    /// The app bundle ships Node and the server. Debug builds (`swift run`) fall back to
    /// a Node on this machine and the server/ folder in this repo.
    private func locate() -> (URL, URL)? {
        let fm = FileManager.default
        if let resources = Bundle.main.resourceURL {
            let node = resources.appendingPathComponent("node")
            let script = resources.appendingPathComponent("server/src/index.js")
            if fm.isExecutableFile(atPath: node.path), fm.fileExists(atPath: script.path) {
                return (node, script)
            }
        }

        #if DEBUG
        let repoScript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Server
            .deletingLastPathComponent()  // LocalLoom
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("server/src/index.js")
        let nodePath = ProcessInfo.processInfo.environment["LOCALLOOM_NODE"] ?? ExecutableLocator.find("node")
        if let nodePath, fm.fileExists(atPath: repoScript.path) {
            return (URL(fileURLWithPath: nodePath), repoScript)
        }
        #endif

        return nil
    }

    // MARK: - Output parsing

    private func processChunk(_ chunk: String) {
        lineBuffer += chunk
        var lines = lineBuffer.components(separatedBy: "\n")
        lineBuffer = lines.removeLast()
        for line in lines where !line.isEmpty {
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        print("[BundledServer] \(line)")
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["msg"] as? String == "listening",
              let port = json["port"] as? Int, let listening = UInt16(exactly: port) else {
            return
        }
        DispatchQueue.main.async {
            self.port = listening
            self.lastPort = listening
            self.retryCount = 0
            self.lastError = nil
            self.onReady?(listening)
        }
    }

    deinit {
        stop()
    }
}
