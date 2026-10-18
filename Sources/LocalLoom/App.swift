import SwiftUI
import AppKit
import Combine

@main
struct LocalLoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                recordingManager: appDelegate.recordingManager,
                ngrokManager: appDelegate.ngrokManager,
                serverConfig: appDelegate.serverConfig,
                bundledServer: appDelegate.bundledServer,
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
            PreferencesView(ngrokConfig: appDelegate.ngrokConfig, serverConfig: appDelegate.serverConfig)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let recordingManager = RecordingManager()
    let ngrokConfig = NgrokConfig()
    let serverConfig = ServerConfig()
    lazy var ngrokManager = NgrokManager(config: ngrokConfig)
    let bundledServer = BundledServer()
    var keyboardShortcut: GlobalKeyboardShortcut?

    private var cancellables = Set<AnyCancellable>()
    /// The port ngrok was last pointed at
    private var tunnelPort: UInt16 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request notification permission
        NotificationHelper.shared.requestPermission()

        // Wire the recording manager to wherever recordings are shared from
        recordingManager.currentDestination = { [unowned self] in self.serverConfig.destination }
        recordingManager.clientFor = { [unowned self] in self.client(for: $0) }
        recordingManager.shareLink = { [unowned self] in self.shareLink(for: $0) }

        bundledServer.onReady = { [weak self] port in
            self?.localServerReady(port: port)
        }

        // Register global keyboard shortcut
        keyboardShortcut = GlobalKeyboardShortcut { [weak self] in
            self?.toggleRecording()
        }
        keyboardShortcut?.register()

        // Start whatever the chosen destination needs, now and whenever it changes.
        // (@Published emits before the value is stored, hence receive(on:) before reading it.)
        serverConfig.$destination
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyDestination() }
            .store(in: &cancellables)

        // A fixed server address or token may unblock failed uploads
        Publishers.CombineLatest(serverConfig.$serverURL, serverConfig.$serverToken)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.recordingManager.retryUploads() }
            .store(in: &cancellables)

        // Start the tunnel as soon as an authtoken is entered
        ngrokConfig.$authtoken
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.ensureTunnelRunning() }
            .store(in: &cancellables)

        // "This Mac" links are built from the ngrok address, which arrives after launch
        ngrokManager.$publicURL
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recordingManager.copyWaitingLinks() }
            .store(in: &cancellables)

        // If the chosen destination is not set up yet, prompt preferences on launch
        if !isDestinationConfigured {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.openPreferences()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ngrokManager.stop()
        bundledServer.stop()
        keyboardShortcut?.unregister()
    }

    func toggleRecording() {
        recordingManager.toggleRecording()
    }

    func copyLinkForRecording(_ recording: Recording) {
        ensureTunnelRunning()

        guard let url = shareLink(for: recording) else {
            NotificationHelper.shared.showNotification(title: "No Link Yet", body: noLinkReason(for: recording))
            return
        }
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
        let prefsView = PreferencesView(ngrokConfig: ngrokConfig, serverConfig: serverConfig)
        let hostingController = NSHostingController(rootView: prefsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "LocalLoom Preferences"
        window.styleMask = [.titled, .closable]
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Destinations

    private var isDestinationConfigured: Bool {
        switch serverConfig.destination {
        case .thisMac: return ngrokConfig.isConfigured
        case .server: return serverConfig.serverClient != nil
        }
    }

    private func applyDestination() {
        switch serverConfig.destination {
        case .thisMac:
            // ngrok follows once the server is listening (localServerReady)
            bundledServer.start(token: serverConfig.localToken)
        case .server:
            ngrokManager.stop()
            bundledServer.stop()
        }
        recordingManager.processUploads()
    }

    private func localServerReady(port: UInt16) {
        if tunnelPort != 0 && tunnelPort != port {
            // The server came back on a different port; move the tunnel with it
            tunnelPort = port
            ngrokManager.restart(port: port)
        } else {
            ensureTunnelRunning()
        }
        recordingManager.processUploads()
    }

    private func ensureTunnelRunning() {
        guard serverConfig.destination == .thisMac, bundledServer.port > 0, ngrokConfig.isConfigured else { return }
        tunnelPort = bundledServer.port
        // start() internally guards against double-launch via process != nil
        ngrokManager.start(port: bundledServer.port)
    }

    private func client(for destination: Destination) -> ServerClient? {
        switch destination {
        case .thisMac:
            guard bundledServer.port > 0 else { return nil }
            return ServerClient(
                baseURL: URL(string: "http://127.0.0.1:\(bundledServer.port)")!,
                token: serverConfig.localToken
            )
        case .server:
            return serverConfig.serverClient
        }
    }

    private func shareLink(for recording: Recording) -> String? {
        switch recording.destination {
        case .server:
            return recording.shareURL
        case .thisMac:
            guard serverConfig.destination == .thisMac, ngrokConfig.isConfigured else { return nil }
            // Before the tunnel reports its address, the configured domain is what it will use
            guard let base = ngrokManager.publicURL ?? ngrokConfig.domain.map({ "https://\($0)" }) else {
                return nil
            }
            return "\(base)/v/\(recording.id)"
        }
    }

    private func noLinkReason(for recording: Recording) -> String {
        switch recording.destination {
        case .server:
            return "Your server hasn't confirmed this recording yet. LocalLoom will keep trying."
        case .thisMac where serverConfig.destination != .thisMac:
            return "This recording is shared from this Mac. Switch back to This Mac in Preferences to share it."
        case .thisMac where !ngrokConfig.isConfigured:
            return "Add your ngrok authtoken in Preferences to share recordings from this Mac."
        case .thisMac:
            return "The ngrok tunnel is still connecting. Try again in a moment."
        }
    }
}
