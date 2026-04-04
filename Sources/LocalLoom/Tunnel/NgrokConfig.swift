import Foundation

class NgrokConfig: ObservableObject {
    @Published var authtoken: String {
        didSet { UserDefaults.standard.set(authtoken, forKey: "NgrokAuthtoken") }
    }
    @Published var subdomain: String {
        didSet { UserDefaults.standard.set(subdomain, forKey: "NgrokSubdomain") }
    }

    var isConfigured: Bool {
        !authtoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var domain: String {
        let sub = subdomain.trimmingCharacters(in: .whitespacesAndNewlines)
        if sub.isEmpty {
            return "localloom.ngrok.io"
        }
        // If user provides a full domain (e.g., myapp.ngrok-free.app), use it as-is
        if sub.contains(".") {
            return sub
        }
        return "\(sub).ngrok.io"
    }

    init() {
        self.authtoken = UserDefaults.standard.string(forKey: "NgrokAuthtoken") ?? ""
        self.subdomain = UserDefaults.standard.string(forKey: "NgrokSubdomain") ?? "localloom"
    }
}
