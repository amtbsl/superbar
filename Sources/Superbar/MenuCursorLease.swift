import CoreGraphics
import CoreFoundation
import Darwin

/// A balanced cursor lease for an explicitly requested native placement.
/// The reference enables background cursor changes on its own WindowServer
/// connection, then hides during the selected-window gesture. Ordinary hide
/// and reveal never instantiate this lease.
@MainActor final class MenuCursorLease {
    private typealias DefaultConnection = @convention(c) () -> UInt32
    private typealias SetProperty = @convention(c) (UInt32, UInt32, CFString, CFTypeRef) -> Int32
    private let display = CGMainDisplayID()
    private var hides = 0
    private(set) var backgroundEnabled = false

    init() {
        let handle = UnsafeMutableRawPointer(bitPattern: -2)
        if let connectionSymbol = dlsym(handle, "_CGSDefaultConnection"),
           let propertySymbol = dlsym(handle, "CGSSetConnectionProperty") {
            let connection = unsafeBitCast(connectionSymbol, to: DefaultConnection.self)()
            let setProperty = unsafeBitCast(propertySymbol, to: SetProperty.self)
            backgroundEnabled = setProperty(connection, connection, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
        }
    }

    func hide() {
        if CGDisplayHideCursor(display) == .success { hides += 1 }
    }

    func release() {
        while hides > 0 {
            CGDisplayShowCursor(display)
            hides -= 1
        }
    }
}
