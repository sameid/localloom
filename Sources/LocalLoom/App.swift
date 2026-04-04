import SwiftUI
import AppKit

@main
struct LocalLoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                recordingManager: appDelegate.recordingManager,
                ngrokManager: appDelegate.ngrokManager,
                ngrokConfig: appDelegate.ngrokConfig,
                onCopyLink: { recording in
                    appDelegate.copyLinkForRecording(recording)
                },
                onOpenPreferences: {
                    appDelegate.openPreferences()
                }
            )
        } label: {
            Image(systemName: appDelegate.recordingManager.isRecording
                  ? "record.circle.fill"
                  : "video.circle.fill")
        }

        Window("LocalLoom Preferences", id: "preferences") {
            PreferencesView(ngrokConfig: appDelegate.ngrokConfig)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let recordingManager = RecordingManager()
    let ngrokConfig = NgrokConfig()
    lazy var ngrokManager = NgrokManager(config: ngrokConfig)
    let localServer = LocalServer()
    var keyboardShortcut: GlobalKeyboardShortcut?

    private var serverPort: UInt16 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permission
        NotificationHelper.shared.requestPermission()

        // Wire up local server to recording manager
        localServer.getRecordings = { [weak self] in
            return self?.recordingManager.recordings ?? []
        }

        // Start the local HTTP server
        do {
            serverPort = try localServer.start()
        } catch {
            print("[App] Failed to start server: \(error.localizedDescription)")
            recordingManager.lastError = "Failed to start local server: \(error.localizedDescription)"
        }

        // Register global keyboard shortcut
        keyboardShortcut = GlobalKeyboardShortcut { [weak self] in
            self?.toggleRecording()
        }
        keyboardShortcut?.register()

        // Setup recording completion handler to auto-share
        setupRecordingShareHandler()

        // Start ngrok if configured
        if ngrokConfig.isConfigured && serverPort > 0 {
            ngrokManager.start(port: serverPort)
        }

        // If ngrok is not configured, prompt preferences on first launch
        if !ngrokConfig.isConfigured {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.openPreferences()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ngrokManager.stop()
        localServer.stop()
        keyboardShortcut?.unregister()
    }

    func toggleRecording() {
        recordingManager.toggleRecording()
    }

    func copyLinkForRecording(_ recording: Recording) {
        ensureTunnelRunning()

        let url = recordingManager.shareableURL(for: recording, tunnelURL: ngrokManager.publicURL)
        ClipboardHelper.copyToClipboard(url)
        NotificationHelper.shared.showNotification(
            title: "Link Copied",
            body: url
        )
    }

    func openPreferences() {
        if #available(macOS 14, *) {
            // On macOS 14+ we can open the settings window
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.title.contains("Preferences") }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                // Open via environment openWindow — fallback to a new window
                showPreferencesWindow()
            }
        } else {
            showPreferencesWindow()
        }
    }

    private func showPreferencesWindow() {
        let prefsView = PreferencesView(ngrokConfig: ngrokConfig)
        let hostingController = NSHostingController(rootView: prefsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "LocalLoom Preferences"
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupRecordingShareHandler() {
        // Observe when a new recording is added
        var previousCount = recordingManager.recordings.count

        // We set up a timer to check for new recordings
        // This is simpler than fighting with Combine in this context
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let currentCount = self.recordingManager.recordings.count

            if currentCount > previousCount, let latest = self.recordingManager.recordings.first {
                previousCount = currentCount

                // Auto-share the new recording
                self.ensureTunnelRunning()

                // Give ngrok a moment to connect if it was just started
                let checkAndCopy = { [weak self] in
                    guard let self = self else { return }
                    let url = self.recordingManager.shareableURL(
                        for: latest,
                        tunnelURL: self.ngrokManager.publicURL
                    )
                    ClipboardHelper.copyToClipboard(url)
                    NotificationHelper.shared.showNotification(
                        title: "Link Copied!",
                        body: "Your recording is live at \(url)"
                    )
                }

                if self.ngrokManager.publicURL != nil {
                    checkAndCopy()
                } else {
                    // Wait a bit for ngrok to establish the tunnel
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        checkAndCopy()
                    }
                }
            }

            // Keep in sync if recordings are deleted
            if currentCount < previousCount {
                previousCount = currentCount
            }
        }
    }

    private func ensureTunnelRunning() {
        guard serverPort > 0, ngrokConfig.isConfigured else { return }
        // start() internally guards against double-launch via process != nil
        ngrokManager.start(port: serverPort)
    }
}
