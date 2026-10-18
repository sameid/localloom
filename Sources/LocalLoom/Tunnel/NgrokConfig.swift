import Foundation

class NgrokConfig: ObservableObject {
    @Published var authtoken: String {
        didSet { SecretStore.shared.set(authtoken, for: "ngrokAuthtoken") }
    }
    @Published var subdomain: String {
        didSet { UserDefaults.standard.set(subdomain, forKey: "NgrokSubdomain") }
    }

    var isConfigured: Bool {
        !authtoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// nil lets ngrok use the account's own free domain. A shared default can't work:
    /// each ngrok domain belongs to a single account.
    var domain: String? {
        let sub = subdomain.trimmingCharacters(in: .whitespacesAndNewlines)
        if sub.isEmpty {
            return nil
        }
        // If user provides a full domain (e.g., myapp.ngrok-free.app), use it as-is
        if sub.contains(".") {
            return sub
        }
        return "\(sub).ngrok.io"
    }

    init() {
        // Earlier versions kept the authtoken in UserDefaults; move it to the keychain.
        if let legacy = UserDefaults.standard.string(forKey: "NgrokAuthtoken") {
            if SecretStore.shared.get("ngrokAuthtoken") == nil {
                SecretStore.shared.set(legacy, for: "ngrokAuthtoken")
            }
            UserDefaults.standard.removeObject(forKey: "NgrokAuthtoken")
        }

        self.authtoken = SecretStore.shared.get("ngrokAuthtoken") ?? ""
        self.subdomain = UserDefaults.standard.string(forKey: "NgrokSubdomain") ?? ""
    }
}
