import Foundation
import Security

/// Where new recordings are uploaded and shared from.
enum Destination: String, Codable, CaseIterable, Identifiable {
    /// The app runs the server privately on this Mac and shares it through ngrok.
    case thisMac
    /// A localloom-server the user hosts themselves.
    case server

    var id: String { rawValue }

    var label: String {
        switch self {
        case .thisMac: return "This Mac (via ngrok)"
        case .server: return "My server"
        }
    }
}

class ServerConfig: ObservableObject {
    @Published var destination: Destination {
        didSet { UserDefaults.standard.set(destination.rawValue, forKey: "Destination") }
    }
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: "ServerURL") }
    }
    @Published var serverToken: String {
        didSet { SecretStore.shared.set(serverToken, for: "serverToken") }
    }

    /// Token for the server the app runs on this Mac. Generated once and kept in the keychain.
    let localToken: String

    /// The user's server URL, or nil if it isn't a usable http(s) address yet.
    var serverBaseURL: URL? {
        var text = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    var serverClient: ServerClient? {
        let token = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = serverBaseURL, !token.isEmpty else { return nil }
        return ServerClient(baseURL: url, token: token)
    }

    init() {
        self.destination = UserDefaults.standard.string(forKey: "Destination")
            .flatMap(Destination.init(rawValue:)) ?? .thisMac
        self.serverURL = UserDefaults.standard.string(forKey: "ServerURL") ?? ""
        self.serverToken = SecretStore.shared.get("serverToken") ?? ""

        if let existing = SecretStore.shared.get("localServerToken") {
            self.localToken = existing
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            self.localToken = Data(bytes).base64EncodedString()
            SecretStore.shared.set(localToken, for: "localServerToken")
        }
    }
}
