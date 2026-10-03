import AppKit

@main struct Superbar {
    @MainActor static func main() {
        let application = NSApplication.shared
        let coordinator = ApplicationCoordinator()
        application.delegate = coordinator
        withExtendedLifetime(coordinator) { application.run() }
    }
}
