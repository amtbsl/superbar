import Foundation
import CoreGraphics

/// Value-only layout rules shared by the runtime and its tests. The planner
/// knows nothing about event delivery, status items, permissions, or windows.
enum MenuLayoutPlanner {
    enum Token: Hashable {
        case icon(String)
        case alwaysHiddenSeparator
        case hiddenSeparator
        case control
    }

    struct Item {
        let id: String
        let visibility: IconVisibility
        let order: Int
        let x: CGFloat
        let movable: Bool
    }

    struct Plan {
        /// All managed items, including fixed anchors, in native left-to-right order.
        let desired: [Token]
        let fixed: Set<Token>
        let hiddenIDs: Set<String>
        let alwaysHiddenIDs: Set<String>
    }

    struct Move: Equatable {
        let item: Token
        let before: Token
    }

    struct Verification: Equatable {
        let valid: Bool
        let missing: Set<Token>
        let misplaced: Set<Token>
    }

    static func plan(items: [Item]) -> Plan {
        // Duplicated discovery records never become two movement requests.
        var used = Set<String>()
        let unique = items.filter { used.insert($0.id).inserted }
        let movable = unique.filter(\.movable)
        func group(_ visibility: IconVisibility) -> [Item] {
            movable.filter { $0.visibility == visibility }.sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                if $0.x != $1.x { return $0.x < $1.x }
                return $0.id < $1.id
            }
        }
        let always = group(.alwaysHidden)
        let hidden = group(.hidden)
        let visible = group(.visible)
        let fixed = unique.filter { !$0.movable }.sorted {
            if $0.x != $1.x { return $0.x < $1.x }
            return $0.id < $1.id
        }.map { Token.icon($0.id) }
        let desired = always.map { Token.icon($0.id) } + [.alwaysHiddenSeparator]
            + hidden.map { Token.icon($0.id) } + [.hiddenSeparator]
            + [.control] + visible.map { Token.icon($0.id) } + fixed
        return Plan(desired: desired, fixed: Set(fixed),
                    hiddenIDs: Set(hidden.map(\.id)), alwaysHiddenIDs: Set(always.map(\.id)))
    }

    /// Computes a bounded set of placements. Items already left of their
    /// next desired neighbor remain in place; later placements resolve any
    /// intervening items. Each movable token appears at most once.
    static func moves(for plan: Plan, current: [Token]) -> [Move] {
        var order = current.filter { plan.desired.contains($0) }
        var moves: [Move] = []
        var anchor: Token?
        for token in plan.desired.reversed() {
            defer { anchor = token }
            guard !plan.fixed.contains(token), let anchor,
                  let sourceIndex = order.firstIndex(of: token),
                  let anchorIndex = order.firstIndex(of: anchor),
                  sourceIndex > anchorIndex else { continue }
            moves.append(Move(item: token, before: anchor))
            order.remove(at: sourceIndex)
            if let index = order.firstIndex(of: anchor) { order.insert(token, at: index) }
        }
        return moves
    }

    static func verify(_ plan: Plan, frames: [Token: CGRect], tolerance: CGFloat = 2) -> Verification {
        let missing = Set(plan.desired.filter { token in
            guard let frame = frames[token] else { return true }
            return !usable(frame)
        })
        var misplaced = Set<Token>()
        for (left, right) in zip(plan.desired, plan.desired.dropFirst()) {
            guard let lhs = frames[left], let rhs = frames[right],
                  usable(lhs), usable(rhs) else { continue }
            if lhs.maxX > rhs.minX + tolerance {
                misplaced.insert(left)
                misplaced.insert(right)
            }
        }
        return Verification(valid: missing.isEmpty && misplaced.isEmpty,
                            missing: missing, misplaced: misplaced)
    }

    static func currentOrder(frames: [Token: CGRect]) -> [Token] {
        frames.keys.sorted {
            let lhs = frames[$0]!, rhs = frames[$1]!
            if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
            if lhs.maxX != rhs.maxX { return lhs.maxX < rhs.maxX }
            return description($0) < description($1)
        }
    }

    static func usable(_ frame: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && frame.minX.isFinite && frame.minY.isFinite
            && frame.maxX.isFinite && frame.maxY.isFinite
    }

    static func description(_ token: Token) -> String {
        switch token {
        case .icon(let id): return id
        case .alwaysHiddenSeparator: return "alwaysHidden"
        case .hiddenSeparator: return "hidden"
        case .control: return "main"
        }
    }
}

/// A scheduling boundary: every caller states why native movement is wanted.
/// Refresh/hover/dismissal cannot turn into a repair operation accidentally.
enum MenuLayoutRequestPolicy {
    enum Trigger: CaseIterable {
        case rulesChanged, explicitApply, startupRestore
        case refresh, captureCompleted, hover, autoReturn, temporaryReturn, menuDismissal, settingsOnly
    }
    static func permits(_ trigger: Trigger) -> Bool {
        switch trigger {
        case .explicitApply: return true
        case .rulesChanged, .startupRestore, .refresh, .captureCompleted, .hover, .autoReturn, .temporaryReturn, .menuDismissal, .settingsOnly: return false
        }
    }
}

/// Monotonic leases invalidate stale asynchronous completions. The capture
/// service and native mover both use this same value-only lifetime boundary.
struct MenuOperationGeneration {
    private(set) var value: UInt64 = 0
    @discardableResult mutating func advance() -> UInt64 { value &+= 1; return value }
    func accepts(_ lease: UInt64) -> Bool { lease == value }
}

/// Separator lengths are a pure function of presentation state. Even an
/// expanded native bar leaves the always-hidden boundary widened.
enum MenuSeparatorPolicy {
    struct State {
        var mode: BarMode
        var expanded: Bool
        var layoutReady: Bool
        var editing: Bool
        var hasHidden: Bool
        var hasAlwaysHidden: Bool
    }
    struct Lengths: Equatable { let hidden: CGFloat; let alwaysHidden: CGFloat }
    static let collapsed: CGFloat = 0.0625
    static let editing: CGFloat = 14
    static let concealed: CGFloat = 5_000

    static func lengths(for state: State) -> Lengths {
        if state.editing { return Lengths(hidden: editing, alwaysHidden: editing) }
        guard state.layoutReady else { return Lengths(hidden: collapsed, alwaysHidden: collapsed) }
        let nativeReveal = state.mode == .normal && state.expanded
        return Lengths(hidden: state.hasHidden && !nativeReveal ? concealed : collapsed,
                       alwaysHidden: state.hasAlwaysHidden ? concealed : collapsed)
    }
}
