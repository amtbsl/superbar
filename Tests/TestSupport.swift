import Foundation

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private(set) var assertionCount = 0

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String,
            file: StaticString = #filePath, line: UInt = #line) throws {
    assertionCount += 1
    guard try condition() else { throw TestFailure(description: "\(file):\(line): \(message)") }
}

func expectError(_ message: String, _ action: () throws -> Void) throws {
    do {
        try action()
    } catch {
        return
    }
    throw TestFailure(description: message)
}

func permutations<T>(_ values: [T]) -> [[T]] {
    if values.isEmpty { return [[]] }
    return values.indices.flatMap { index -> [[T]] in
        var tail = values
        let first = tail.remove(at: index)
        return permutations(tail).map { [first] + $0 }
    }
}
