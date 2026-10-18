import Foundation

class NgrokManager: ObservableObject {
    @Published var publicURL: String?
    @Published var isRunning = false
    @Published var lastError: String?

    private var process: Process?
    private var outputPipe: Pipe?
    private var retryCount = 0
    private let maxRetries = 3
    private var retryDelay: TimeInterval = 2.0
    private var isShuttingDown = false
    private var currentPort: UInt16 = 0

    // Accumulate partial lines across multiple readabilityHandler callbacks
    private var lineBuffer = ""

    private let config: NgrokConfig

    init(config: NgrokConfig) {
        self.config = config
    }

    func start(port: UInt16) {
        // Use process existence + isRunning together so we don't double-launch
        guard process == nil else { return }
        guard config.isConfigured else {
            DispatchQueue.main.async {
                self.lastError = "ngrok authtoken not configured. Please set it in Preferences."
            }
            return
        }

        isShuttingDown = false
        retryCount = 0
        retryDelay = 2.0
        currentPort = port
        launchNgrok(port: port)
    }

    /// Points the tunnel at a new port, e.g. after the local server restarted elsewhere.
    func restart(port: UInt16) {
        stop()
        start(port: port)
    }

    func stop() {
        isShuttingDown = true
        killProcess()
        DispatchQueue.main.async {
            self.isRunning = false
            self.publicURL = nil
        }
    }

    private func launchNgrok(port: UInt16) {
        guard let ngrokPath = findNgrokBinary() else {
            DispatchQueue.main.async {
                self.lastError = "ngrok binary not found. Install via 'brew install ngrok' or place the binary in the app bundle."
            }
            return
        }

        // Ensure the binary is executable
        let attrs = (try? FileManager.default.attributesOfItem(atPath: ngrokPath)) ?? [:]
        if (attrs[.posixPermissions] as? Int ?? 0) & 0o111 == 0 {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: ngrokPath
            )
        }

        print("[NgrokManager] Launching ngrok at \(ngrokPath) on port \(port)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ngrokPath)

        // 127.0.0.1 rather than "localhost": the local server only listens on IPv4 loopback
        var arguments = [
            "http", "127.0.0.1:\(port)",
            "--authtoken", config.authtoken.trimmingCharacters(in: .whitespacesAndNewlines),
            "--log", "stdout",
            "--log-format", "json",
        ]

        if let domain = config.domain {
            arguments.append(contentsOf: ["--domain", domain])
        }

        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        self.outputPipe = outPipe
        self.lineBuffer = ""

        // stdout: JSON log lines
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // Empty data = EOF; nil out the handler so the runloop doesn't spin
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8) else { return }
            self?.processChunk(chunk)
        }

        // stderr: capture for debugging but don't try to parse as JSON
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            if let text = String(data: data, encoding: .utf8) {
                print("[NgrokManager] stderr: \(text)")
            }
        }

        process.terminationHandler = { [weak self] proc in
            // A process we replaced or stopped on purpose must not trigger retries
            guard let self = self, self.process === proc else { return }

            // Drain any remaining buffered output
            if !self.lineBuffer.isEmpty {
                self.parseLine(self.lineBuffer)
                self.lineBuffer = ""
            }

            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            self.process = nil

            let code = proc.terminationStatus
            print("[NgrokManager] Process exited with code \(code)")

            DispatchQueue.main.async {
                self.isRunning = false
                self.publicURL = nil
            }

            guard !self.isShuttingDown else { return }

            if self.retryCount < self.maxRetries {
                self.retryCount += 1
                let delay = self.retryDelay
                self.retryDelay = min(self.retryDelay * 2, 30)
                print("[NgrokManager] Retrying in \(delay)s (attempt \(self.retryCount)/\(self.maxRetries))")
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, !self.isShuttingDown else { return }
                    self.launchNgrok(port: self.currentPort)
                }
            } else {
                DispatchQueue.main.async {
                    self.lastError = "ngrok failed after \(self.maxRetries) retries. Check your authtoken and network."
                }
            }
        }

        do {
            self.process = process
            try process.run()
            print("[NgrokManager] Started ngrok PID \(process.processIdentifier), args: \(arguments.joined(separator: " "))")
        } catch {
            self.process = nil
            DispatchQueue.main.async {
                self.lastError = "Failed to launch ngrok: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Line-buffered output parsing

    /// Accumulate raw stdout chunks into complete newline-terminated lines
    private func processChunk(_ chunk: String) {
        lineBuffer += chunk
        // Split on newlines, keeping any trailing partial line in the buffer
        var lines = lineBuffer.components(separatedBy: "\n")
        // The last element is either empty (chunk ended with \n) or a partial line
        lineBuffer = lines.removeLast()
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parseLine(trimmed)
            }
        }
    }

    private func parseLine(_ line: String) {
        print("[NgrokManager] \(line)")

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Not JSON — banner text or similar, ignore
            return
        }

        let msg = json["msg"] as? String ?? ""
        let lvl = json["lvl"] as? String ?? ""

        // ── Tunnel is up ──────────────────────────────────────────────────
        // ngrok v3 log line: {"msg":"started tunnel","url":"https://..."}
        if msg == "started tunnel", let url = json["url"] as? String {
            DispatchQueue.main.async {
                self.publicURL = url
                self.isRunning = true
                self.lastError = nil
                self.retryCount = 0
                self.retryDelay = 2.0
                print("[NgrokManager] Tunnel active: \(url)")
            }
            return
        }

        // Fallback: any top-level "url" that looks like an https address
        if let url = json["url"] as? String, url.hasPrefix("https://"), !url.isEmpty {
            DispatchQueue.main.async {
                if self.publicURL == nil {
                    self.publicURL = url
                    self.isRunning = true
                    self.lastError = nil
                }
            }
            return
        }

        // ── Errors ────────────────────────────────────────────────────────
        if lvl == "error" || lvl == "crit" {
            // Prefer the "err" field; fall back to msg
            let errText = (json["err"] as? String).flatMap { $0 == "<nil>" ? nil : $0 } ?? msg
            print("[NgrokManager] Error from ngrok: \(errText)")
            DispatchQueue.main.async {
                self.lastError = errText
            }
        }
    }

    // MARK: - Binary discovery

    private func findNgrokBinary() -> String? {
        let fm = FileManager.default

        // 1. SPM resource bundle (when built with `swift build`)
        if let url = Bundle.module_safe?.url(forResource: "ngrok", withExtension: nil),
           fm.fileExists(atPath: url.path) {
            // Only return the bundled binary if it is a real executable (>0 bytes)
            let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0
            if size > 0 { return url.path }
        }

        // 2. .app bundle Resources (when wrapped with make-app.sh)
        if let bundledPath = Bundle.main.path(forResource: "ngrok", ofType: nil),
           fm.fileExists(atPath: bundledPath) {
            let size = (try? fm.attributesOfItem(atPath: bundledPath))?[.size] as? Int ?? 0
            if size > 0 { return bundledPath }
        }

        // 3. Sibling of the executable (handy during development)
        if let execURL = Bundle.main.executableURL {
            let sibling = execURL.deletingLastPathComponent().appendingPathComponent("ngrok")
            if fm.fileExists(atPath: sibling.path) { return sibling.path }
        }

        // 4. Homebrew, manual installs, PATH
        return ExecutableLocator.find("ngrok")
    }

    // MARK: - Teardown

    private func killProcess() {
        guard let p = process else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        if p.isRunning { p.terminate() }
        process = nil
    }

    deinit {
        stop()
    }
}

// MARK: - Safe Bundle.module access for SPM resource bundles

private extension Bundle {
    static var module_safe: Bundle? {
        // SPM generates a `Bundle.module` accessor only when there are declared resources.
        // We locate the bundle manually so we don't crash when running outside Xcode/SPM.
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"),
            Bundle(for: NgrokManager_BundleLocator.self).resourceURL,
        ]
        for base in candidates.compactMap({ $0 }) {
            let bundleURL = base.appendingPathComponent("LocalLoom_LocalLoom.bundle")
            if let b = Bundle(url: bundleURL) { return b }
        }
        return Bundle.main
    }
}

// Used only for Bundle(for:) lookup above
private final class NgrokManager_BundleLocator {}
