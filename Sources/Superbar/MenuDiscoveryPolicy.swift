import Foundation

/// Apple's transient camera/microphone/screen-sharing indicator is not a
/// user-managed menu extra. This matches the exact AudioVideoModule exclusion
/// observed in iBar's native macOS 26 discovery path, not an application list.
enum MenuDiscoveryPolicy {
    static func excludes(bundleID: String, identifier: String?, windowTitle: String?) -> Bool {
        guard bundleID == "com.apple.controlcenter" else { return false }
        return identifier == "com.apple.menuextra.audiovideo" || windowTitle == "AudioVideoModule"
    }

    static func excludesPersistedID(_ id: String) -> Bool {
        id == "com.apple.controlcenter|com.apple.menuextra.audiovideo"
    }
}
