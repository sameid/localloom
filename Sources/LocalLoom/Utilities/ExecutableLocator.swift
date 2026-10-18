import Foundation

/// Finds command-line tools the user installed themselves (Homebrew, manual installs, PATH).
enum ExecutableLocator {
    static func find(_ name: String) -> String? {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/\(name)",        // Homebrew on Apple Silicon
            "/usr/local/bin/\(name)",           // Homebrew on Intel / manual install
            "\(NSHomeDirectory())/.local/bin/\(name)",
            "\(NSHomeDirectory())/bin/\(name)",
        ]
        for path in candidates where fm.fileExists(atPath: path) {
            return path
        }

        // Ask the shell — handles nvm-style PATH shims and custom profiles
        return runWhich(name)
    }

    private static func runWhich(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "which \(name)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = output, !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return path
    }
}
