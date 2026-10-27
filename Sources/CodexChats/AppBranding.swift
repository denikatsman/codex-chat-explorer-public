import Foundation

// Display branding is independent of the permanent bundle and preferences identity.
enum AppBranding {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Codex Chat Explorer"
    }
}
