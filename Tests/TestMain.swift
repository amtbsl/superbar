import Foundation
import Darwin

@main struct SuperbarLogicTests {
    static func main() {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("superbar-logic-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try ModelTests.run(root: root)
            try LayoutTests.run()
            try DiscoveryTests.run()
            try CaptureGeometryTests.run()
            try TemporaryRevealTests.run()
            print("PASS \(assertionCount) deterministic production-logic assertions. No app launch, permissions, UI automation, or synthetic input performed.")
        } catch {
            FileHandle.standardError.write(Data("FAIL \(error)\n".utf8))
            exit(1)
        }
    }
}
