import Foundation

enum DiscoveryTests {
    static func run() throws {
        let controlCenter = "com.apple.controlcenter"
        let privacyIdentifier = "com.apple.menuextra.audiovideo"
        let privacyTitle = "AudioVideoModule"

        try expect(MenuDiscoveryPolicy.excludes(bundleID: controlCenter, identifier: privacyIdentifier, windowTitle: nil),
                   "The exact Control Center AX privacy identifier must be excluded even without a CG title")
        try expect(MenuDiscoveryPolicy.excludes(bundleID: controlCenter, identifier: nil, windowTitle: privacyTitle),
                   "The exact Control Center CG privacy window must be excluded even without an AX identifier")
        try expect(MenuDiscoveryPolicy.excludes(bundleID: controlCenter, identifier: privacyIdentifier, windowTitle: privacyTitle),
                   "A privacy item seen by both discovery paths must remain excluded")

        let ordinaryItems: [(identifier: String?, title: String?)] = [
            ("com.apple.menuextra.sound", "Sound"),
            ("com.apple.menuextra.battery", "Battery"),
            ("com.apple.menuextra.bluetooth", "Bluetooth"),
            ("com.apple.menuextra.airport", "Wi-Fi"),
            ("com.apple.menuextra.clock", "Clock"),
            ("com.apple.menuextra.controlcenter", "Control Center"),
            (nil, "Sound"),
            ("com.apple.menuextra.battery", nil),
            (nil, nil),
            ("", "")
        ]
        for item in ordinaryItems {
            try expect(!MenuDiscoveryPolicy.excludes(bundleID: controlCenter, identifier: item.identifier, windowTitle: item.title),
                       "The privacy filter must retain ordinary Control Center items: \(item.identifier ?? "nil") / \(item.title ?? "nil")")
        }

        // Names resembling Apple's indicator are insufficient. In particular,
        // third-party owners must survive even when both names match exactly.
        for owner in ["com.example.recorder", "com.apple.systemuiserver", "com.apple.ControlCenter", ""] {
            for hints in [(privacyIdentifier as String?, nil as String?), (nil, privacyTitle), (privacyIdentifier, privacyTitle)] {
                try expect(!MenuDiscoveryPolicy.excludes(bundleID: owner, identifier: hints.0, windowTitle: hints.1),
                           "A matching privacy name must not exclude a different owner: \(owner)")
            }
        }
        for identifier in ["com.apple.menuextra.audiovideo.helper", "com.apple.menuextra.audiovideo ", "com.apple.menuextra.AudioVideo", "audiovideo"] {
            try expect(!MenuDiscoveryPolicy.excludes(bundleID: controlCenter, identifier: identifier, windowTitle: nil),
                       "AX privacy exclusion must use the full exact identifier, not a substring or case-folded match")
        }
        for title in ["AudioVideoModuleHelper", "AudioVideoModule ", "AudioVideo", "audiovideomodule", "AudioVideoModule: Sound"] {
            try expect(!MenuDiscoveryPolicy.excludes(bundleID: controlCenter, identifier: nil, windowTitle: title),
                       "CG privacy exclusion must use the exact window title, not a broad audio/video match")
        }

        let persistedPrivacyID = "\(controlCenter)|\(privacyIdentifier)"
        try expect(MenuDiscoveryPolicy.excludesPersistedID(persistedPrivacyID),
                   "The exact old privacy composite ID must be excluded from shortcut registration")
        for id in [privacyIdentifier, privacyTitle, "com.example.recorder|\(privacyIdentifier)",
                   "\(controlCenter)|com.apple.menuextra.sound", "\(controlCenter)|com.apple.menuextra.battery",
                   persistedPrivacyID + "|second", persistedPrivacyID + " ", "com.apple.ControlCenter|\(privacyIdentifier)", ""] {
            try expect(!MenuDiscoveryPolicy.excludesPersistedID(id),
                       "Persisted-ID cleanup must retain unrelated and near-matching saved rules: \(id)")
        }
        print("PASS exact AX/CG privacy exclusion, ordinary Control Center retention, third-party ownership and persisted-ID boundaries")
    }
}
