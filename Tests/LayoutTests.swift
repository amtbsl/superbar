import Foundation
import CoreGraphics

enum LayoutTests {
    typealias Token = MenuLayoutPlanner.Token
    typealias Item = MenuLayoutPlanner.Item

    static func run() throws {
        try groupingAndAnchors()
        try exhaustivePlacement()
        try measuredVerification()
        try movementRequestBoundary()
        try presentationBoundary()
        try cancelledOperationLeases()
        print("PASS layout grouping, deterministic order, fixed anchors, bounded placements, geometry verification, request and separator policies")
    }

    private static func groupingAndAnchors() throws {
        let items = [
            Item(id: "visible", visibility: .visible, order: -10, x: 90, movable: true),
            Item(id: "hidden-z", visibility: .hidden, order: 2, x: 40, movable: true),
            Item(id: "always", visibility: .alwaysHidden, order: 8, x: 150, movable: true),
            Item(id: "hidden-a", visibility: .hidden, order: 2, x: 40, movable: true),
            Item(id: "hidden-first", visibility: .hidden, order: 1, x: 80, movable: true),
            Item(id: "fixed-right", visibility: .alwaysHidden, order: -99, x: 240, movable: false),
            Item(id: "fixed-left", visibility: .hidden, order: -99, x: 210, movable: false),
            Item(id: "hidden-z", visibility: .alwaysHidden, order: -99, x: 0, movable: true)
        ]
        let plan = MenuLayoutPlanner.plan(items: items)
        let expected: [Token] = [.icon("always"), .alwaysHiddenSeparator, .icon("hidden-first"), .icon("hidden-a"),
                                 .icon("hidden-z"), .hiddenSeparator, .control, .icon("visible"),
                                 .icon("fixed-left"), .icon("fixed-right")]
        try expect(plan.desired == expected, "The main item is the native hidden/visible boundary: always-hidden, hidden, main, visible, then fixed anchors")
        try expect(plan.fixed == [.icon("fixed-left"), .icon("fixed-right")], "Fixed records must retain their native relative order")
        try expect(plan.hiddenIDs == ["hidden-first", "hidden-a", "hidden-z"], "Fixed and always-hidden items must not enter the hidden membership")
        try expect(plan.alwaysHiddenIDs == ["always"], "Always-hidden membership must ignore duplicate records and fixed items")
        try expect(MenuLayoutPlanner.moves(for: plan, current: expected).isEmpty, "An already correct native layout must request no moves")
        let empty = MenuLayoutPlanner.plan(items: [])
        try expect(empty.desired == [.alwaysHiddenSeparator, .hiddenSeparator, .control], "Empty plans still have ordered boundaries")
        try expect(empty.hiddenIDs.isEmpty && empty.alwaysHiddenIDs.isEmpty && empty.fixed.isEmpty, "Empty discovery must not fabricate icons")
    }

    private static func exhaustivePlacement() throws {
        let plan = MenuLayoutPlanner.plan(items: [
            Item(id: "always", visibility: .alwaysHidden, order: 0, x: 0, movable: true),
            Item(id: "hidden", visibility: .hidden, order: 0, x: 20, movable: true),
            Item(id: "visible", visibility: .visible, order: 0, x: 40, movable: true)
        ])
        for current in permutations(plan.desired) {
            let moves = MenuLayoutPlanner.moves(for: plan, current: current)
            try expect(Set(moves.map(\.item)).count == moves.count, "The bounded planner must not repeatedly move one token")
            try expect(moves.count < plan.desired.count, "At least the rightmost anchor must remain untouched")
            try expect(applying(moves, to: current) == plan.desired, "Placements must converge from every six-token permutation")
        }

        let anchored = MenuLayoutPlanner.plan(items: [
            Item(id: "hidden", visibility: .hidden, order: 0, x: 0, movable: true),
            Item(id: "visible", visibility: .visible, order: 0, x: 20, movable: true),
            Item(id: "fixed-one", visibility: .hidden, order: 0, x: 80, movable: false),
            Item(id: "fixed-two", visibility: .alwaysHidden, order: 0, x: 100, movable: false)
        ])
        for current in permutations(anchored.desired) where current.filter({ anchored.fixed.contains($0) }) == [.icon("fixed-one"), .icon("fixed-two")] {
            let moves = MenuLayoutPlanner.moves(for: anchored, current: current)
            try expect(moves.allSatisfy { !anchored.fixed.contains($0.item) }, "A layout plan must never drag fixed native items")
            try expect(Set(moves.map(\.item)).count == moves.count, "Anchored layout must also have one placement per movable token")
            try expect(applying(moves, to: current) == anchored.desired, "All arrangements preserving fixed anchors must converge")
        }
        var missing = plan.desired
        missing.removeAll { $0 == .hiddenSeparator }
        let missingMoves = MenuLayoutPlanner.moves(for: plan, current: missing)
        try expect(missingMoves.allSatisfy { $0.item != .hiddenSeparator && $0.before != .hiddenSeparator }, "Unavailable tokens must not become native drag targets")
    }

    private static func applying(_ moves: [MenuLayoutPlanner.Move], to initial: [Token]) -> [Token] {
        var result = initial
        for move in moves {
            guard let from = result.firstIndex(of: move.item) else { continue }
            result.remove(at: from)
            guard let to = result.firstIndex(of: move.before) else { continue }
            result.insert(move.item, at: to)
        }
        return result
    }

    private static func measuredVerification() throws {
        let plan = MenuLayoutPlanner.plan(items: [Item(id: "hidden", visibility: .hidden, order: 0, x: 0, movable: true)])
        var frames = Dictionary(uniqueKeysWithValues: plan.desired.enumerated().map {
            ($0.element, CGRect(x: $0.offset * 30, y: 0, width: 24, height: 24))
        })
        try expect(MenuLayoutPlanner.verify(plan, frames: frames).valid, "Non-overlapping desired native order must verify")
        try expect(MenuLayoutPlanner.currentOrder(frames: frames) == plan.desired, "Native order must be derived from measured geometry")
        frames[.icon("hidden")] = nil
        let missing = MenuLayoutPlanner.verify(plan, frames: frames)
        try expect(!missing.valid && missing.missing == [.icon("hidden")], "Missing native geometry must invalidate success")
        frames[.icon("hidden")] = .zero
        try expect(MenuLayoutPlanner.verify(plan, frames: frames).missing == [.icon("hidden")], "Zero-sized/offscreen placeholder geometry is unavailable")
        frames[.icon("hidden")] = CGRect(x: CGFloat.infinity, y: 0, width: 24, height: 24)
        try expect(MenuLayoutPlanner.verify(plan, frames: frames).missing == [.icon("hidden")], "Nonfinite geometry must not be accepted")
        frames[.icon("hidden")] = CGRect(x: 20, y: 0, width: 24, height: 24)
        let overlap = MenuLayoutPlanner.verify(plan, frames: frames)
        try expect(!overlap.valid && overlap.misplaced.contains(.alwaysHiddenSeparator), "Overlapping group boundaries must invalidate success")
        frames[.icon("hidden")] = CGRect(x: 22, y: 0, width: 24, height: 24)
        try expect(MenuLayoutPlanner.verify(plan, frames: frames, tolerance: 2).valid, "The documented two-point tolerance must permit edge rounding")
        try expect(!MenuLayoutPlanner.verify(plan, frames: frames, tolerance: 0).valid, "The same measured overlap must fail at zero tolerance")
    }

    private static func movementRequestBoundary() throws {
        let permitted: [MenuLayoutRequestPolicy.Trigger] = [.explicitApply]
        for trigger in MenuLayoutRequestPolicy.Trigger.allCases {
            try expect(MenuLayoutRequestPolicy.permits(trigger) == permitted.contains(trigger), "Routine polling, capture, hover, return, menu dismissal and ordinary settings must not schedule physical relayout: \(trigger)")
        }
        try expect(!MenuLayoutRequestPolicy.permits(.temporaryReturn), "After a temporary aggregate activation, automatic return restores the divider position without synthetic native movement")
    }

    private static func cancelledOperationLeases() throws {
        var generation = MenuOperationGeneration()
        let first = generation.advance()
        try expect(generation.accepts(first), "Fresh explicit operations may complete under their own lease")
        let replacement = generation.advance()
        try expect(!generation.accepts(first), "Cancelling/replacing native movement invalidates a previously awaiting completion")
        try expect(generation.accepts(replacement), "The replacement operation keeps its current lease")
        _ = generation.advance()
        try expect(!generation.accepts(first) && !generation.accepts(replacement), "Stop/cleanup invalidates every stale capture or movement completion")
    }

    private static func presentationBoundary() throws {
        for mode in BarMode.allCases {
            for expanded in [false, true] {
                for hasHidden in [false, true] {
                    for hasAlwaysHidden in [false, true] {
                        let state = MenuSeparatorPolicy.State(mode: mode, expanded: expanded, layoutReady: true, editing: false,
                                                              hasHidden: hasHidden, hasAlwaysHidden: hasAlwaysHidden)
                        let lengths = MenuSeparatorPolicy.lengths(for: state)
                        try expect(lengths.alwaysHidden == (hasAlwaysHidden ? MenuSeparatorPolicy.concealed : MenuSeparatorPolicy.collapsed), "Always-hidden separator must stay concealed in both modes, including expanded normal mode")
                        let revealNative = mode == .normal && expanded
                        try expect(lengths.hidden == (hasHidden && !revealNative ? MenuSeparatorPolicy.concealed : MenuSeparatorPolicy.collapsed), "Reveal/return must change separator geometry only for the ordinary hidden group")
                    }
                }
            }
        }
        let startup = MenuSeparatorPolicy.lengths(for: .init(mode: .normal, expanded: false, layoutReady: false, editing: false, hasHidden: true, hasAlwaysHidden: true))
        try expect(startup == .init(hidden: MenuSeparatorPolicy.collapsed, alwaysHidden: MenuSeparatorPolicy.collapsed), "Before a verified layout, separators must not conceal unclassified native items")
        let editing = MenuSeparatorPolicy.lengths(for: .init(mode: .aggregate, expanded: false, layoutReady: true, editing: true, hasHidden: true, hasAlwaysHidden: true))
        try expect(editing == .init(hidden: MenuSeparatorPolicy.editing, alwaysHidden: MenuSeparatorPolicy.editing), "Explicit layout editing exposes both movable boundaries")
    }
}
