import AppKit
import ApplicationServices
import CoreGraphics

/// One coordinate transform, shared by AX matching, native events and capture.
/// Quartz and AX use the primary display's top-left origin, not the bounds of
/// the union of every monitor.
struct MenuCoordinates {
    let primaryTop: CGFloat
    let screens: [CGRect]

    @MainActor static var current: MenuCoordinates {
        MenuCoordinates(primaryTop: NSScreen.screens.first?.frame.maxY ?? CGDisplayBounds(CGMainDisplayID()).height,
                        screens: NSScreen.screens.map(\.frame))
    }
    func cocoaRect(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
    func quartzRect(_ rect: CGRect) -> CGRect { cocoaRect(rect) }
    func quartzPoint(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x, y: primaryTop - point.y) }
    func isMenuBarPoint(_ point: CGPoint, thickness: CGFloat) -> Bool {
        screens.contains { screen in
            point.x >= screen.minX && point.x <= screen.maxX
                && point.y >= screen.maxY - thickness - 4 && point.y <= screen.maxY + 2
        }
    }
    func isMenuExtraFrame(_ quartz: CGRect) -> Bool {
        guard MenuLayoutPlanner.usable(quartz), quartz.width <= 400, quartz.height <= 100 else { return false }
        let cocoa = cocoaRect(quartz)
        // Hidden extras retain their real renderer windows above the desktop.
        if screens.contains(where: { cocoa.minY >= $0.maxY && cocoa.minY <= $0.maxY + 200 }) { return true }
        return screens.contains { screen in
            cocoa.minY <= screen.maxY + 4 && cocoa.maxY >= screen.maxY - 64
        }
    }

    static func matchScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat? {
        guard MenuLayoutPlanner.usable(lhs), MenuLayoutPlanner.usable(rhs) else { return nil }
        let width = min(lhs.width, rhs.width), height = min(lhs.height, rhs.height)
        let overlapX = max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
        let overlapY = max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
        guard overlapX >= min(width, max(0.025, width * 0.1)),
              overlapY >= max(1, height * 0.25) else { return nil }
        let distance = abs(lhs.midX - rhs.midX) + abs(lhs.midY - rhs.midY)
        let limit = max(6, width * 0.6)
        guard distance <= limit else { return nil }
        return (1 - distance / limit) * 100 + overlapX / width * 10 + overlapY / height * 4
    }
}

public struct MenuWindowMappingSnapshot: Codable {
    let windowID: UInt32
    let pid: Int32
    let owner: String
    let title: String
    let quartzFrame: [Double]
    let cocoaFrame: [Double]
    let axID: String?
    let axPID: Int32?
    let axBundleID: String?
    let axFrame: [Double]?
    let match: String
    let duplicate: Bool
    var rejectionReason: String? = nil
    var candidateWindowIDs: [UInt32]? = nil
    var axTitle: String? = nil
}

/// AX owns semantic identity and actions. CG owns renderer identity and live
/// geometry. Neither PID is substituted for the other when delivering input.
@MainActor final class MenuWindowDiscovery {
    struct Window {
        let id: CGWindowID
        let pid: pid_t
        let owner: String
        let title: String
        let layer: Int
        let quartzFrame: CGRect
        let frame: CGRect
        let isOnScreen: Bool
        let alpha: CGFloat
    }
    struct Record {
        var icon: MenuBarIcon
        let element: AXUIElement?
        let axFrame: CGRect?
        let semanticIdentifier: String?
        var renderer: Window?
    }
    struct Snapshot {
        let records: [Record]
        let windows: [Window]
        let mappings: [MenuWindowMappingSnapshot]
    }

    private struct AccessibleItem {
        let baseID: String
        let title: String
        let bundleID: String
        let pid: pid_t
        let frame: CGRect
        let element: AXUIElement
        let identifier: String?
        let movable: Bool
    }
    private struct StatusRendererIdentity {
        let id: CGWindowID
        let pid: pid_t
    }
    private var statusRenderers: [String: StatusRendererIdentity] = [:]

    func snapshot(accessibility: Bool, excluding ownedFrames: [CGRect], previous: [MenuBarIcon]) -> Snapshot {
        let all = allWindows()
        let coordinates = MenuCoordinates.current
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownedWindows = all.filter { window in
            window.title.hasPrefix("com.superbar.") || statusRenderers.contains { name, identity in
                identity.id == window.id && identity.pid == window.pid
                    && (window.title.isEmpty || window.title == name)
                    && (window.layer == 24 || window.layer == 25)
            }
        }
        let ownedIDs = Set(ownedWindows.map(\.id))
        let owned = ownedFrames + ownedWindows.map(\.frame)
        let allAccessible = accessibility ? accessibleItems() : []
        let excludedAX = allAccessible.filter {
            MenuDiscoveryPolicy.excludes(bundleID: $0.bundleID, identifier: $0.identifier, windowTitle: nil)
        }
        let excludedWindows = all.filter { window in
            let bundle = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier ?? ""
            return MenuDiscoveryPolicy.excludes(bundleID: bundle, identifier: nil, windowTitle: window.title)
                || excludedAX.contains { (MenuCoordinates.matchScore($0.frame, window.frame) ?? 0) >= 95 }
        }
        let excludedIDs = Set(excludedWindows.map(\.id))
        let windows = all.filter {
            ($0.layer == 24 || $0.layer == 25) && $0.pid != ownPID
                && !ownedIDs.contains($0.id)
                && !excludedIDs.contains($0.id)
                && coordinates.isMenuExtraFrame($0.quartzFrame)
                && !$0.owner.lowercased().contains("windowserver")
                && !$0.title.contains("com.superbar.")
        }.filter { window in
            !owned.contains { frame in
                (MenuCoordinates.matchScore(frame, window.frame) ?? 0) >= 95
            }
        }
        let accessible = allAccessible.filter { item in
            !MenuDiscoveryPolicy.excludes(bundleID: item.bundleID, identifier: item.identifier, windowTitle: nil)
                && item.identifier?.hasPrefix("com.superbar.") != true
                && !owned.contains { (MenuCoordinates.matchScore($0, item.frame) ?? 0) >= 95 }
        }
        var used = Set<String>()
        var records = accessible.map { item -> Record in
            let id = unique(item.baseID, used: &used)
            return Record(icon: MenuBarIcon(id: id, title: item.title, bundleID: item.bundleID, pid: item.pid,
                                           frame: item.frame, image: nil, windowID: nil, movable: item.movable),
                          element: item.element, axFrame: item.frame, semanticIdentifier: item.identifier, renderer: nil)
        }
        // Keep exclusion evidence in diagnostics, but never produce a model
        // icon, a capture request, a rule, or a movable layout token for it.
        var mappings: [MenuWindowMappingSnapshot] = excludedWindows.map { window in
            let item = excludedAX.first { MenuCoordinates.matchScore($0.frame, window.frame) != nil }
            return MenuWindowMappingSnapshot(windowID: window.id, pid: window.pid, owner: window.owner,
                                             title: window.title, quartzFrame: Self.components(window.quartzFrame),
                                             cocoaFrame: Self.components(window.frame), axID: item?.baseID,
                                             axPID: item?.pid, axBundleID: item?.bundleID,
                                             axFrame: item.map { Self.components($0.frame) },
                                             match: "excluded-system-privacy-indicator", duplicate: false)
        }
        let includedWindows = Set(windows.map(\.id))
        for window in all where (window.layer == 24 || window.layer == 25)
            && !includedWindows.contains(window.id) && !excludedIDs.contains(window.id) {
            let reason: String
            if window.pid == ownPID { reason = "own-process" }
            else if ownedIDs.contains(window.id) || window.title.contains("com.superbar.") { reason = "owned-status-renderer" }
            else if window.owner.lowercased().contains("windowserver") { reason = "windowserver-decoration" }
            else if !coordinates.isMenuExtraFrame(window.quartzFrame) { reason = "outside-menu-row-or-size" }
            else { reason = "overlaps-owned-status-frame" }
            var rejected = mapping(window, record: nil, match: "rejected-renderer", duplicate: false)
            rejected.rejectionReason = reason
            mappings.append(rejected)
        }
        var claimed = Set<CGWindowID>()
        var duplicates = Set<CGWindowID>()
        var ambiguousRecords = Set<Int>()
        // Match the tightest geometry first. AX and renderer PID agreement
        // only breaks equal scores; it cannot steal a neighboring icon.
        struct Pair { let record: Int; let window: Int; let score: CGFloat; let samePID: Bool }
        let pairs = windows.indices.flatMap { wi in
            records.indices.compactMap { ri -> Pair? in
                guard let score = MenuCoordinates.matchScore(records[ri].icon.frame, windows[wi].frame) else { return nil }
                return Pair(record: ri, window: wi, score: score, samePID: records[ri].icon.pid == windows[wi].pid)
            }
        }.sorted {
            if abs($0.score - $1.score) > 0.001 { return $0.score > $1.score }
            if $0.samePID != $1.samePID { return $0.samePID }
            return windows[$0.window].id < windows[$1.window].id
        }
        for pair in pairs {
            let window = windows[pair.window]
            guard !claimed.contains(window.id), records[pair.record].renderer == nil else { continue }
            // Reject a nearly tied alternative AX item instead of routing an
            // event to a guessed application identity.
            let alternatives = pairs.filter { $0.window == pair.window && $0.record != pair.record && records[$0.record].renderer == nil }
            if let other = alternatives.first, abs(pair.score - other.score) < 0.5,
               pair.samePID == other.samePID {
                ambiguousRecords.insert(pair.record); ambiguousRecords.insert(other.record)
                continue
            }
            records[pair.record].renderer = window
            records[pair.record].icon.windowID = window.id
            records[pair.record].icon.frame = window.frame
            claimed.insert(window.id)
        }
        for window in windows where !claimed.contains(window.id) {
            if let covered = records.indices.first(where: {
                let renderer = records[$0].renderer
                return MenuCaptureGeometry.duplicateRenderer(candidateFrame: window.frame, candidatePID: window.pid,
                                                             candidateTitle: window.title, existingFrame: renderer?.frame,
                                                             existingPID: renderer?.pid, existingTitle: renderer?.title)
            }) {
                duplicates.insert(window.id)
                mappings.append(mapping(window, record: records[covered], match: "duplicate-renderer", duplicate: true))
                continue
            }
            let zeroFrame = records.indices.filter {
                records[$0].renderer == nil && !MenuLayoutPlanner.usable(records[$0].icon.frame)
                    && records[$0].icon.pid == window.pid
            }
            if zeroFrame.count == 1, let index = zeroFrame.first {
                records[index].renderer = window
                records[index].icon.windowID = window.id
                records[index].icon.frame = window.frame
                claimed.insert(window.id)
            }
        }

        // Session continuity disambiguates unnamed extras without persisting
        // their transient CGWindowID as the icon's identity.
        var assigned = Set<String>()
        for index in records.indices {
            if records[index].semanticIdentifier == nil,
               let renderer = records[index].renderer,
               let old = previous.first(where: {
                   $0.windowID == renderer.id && $0.bundleID == records[index].icon.bundleID
               }), !assigned.contains(old.id) {
                records[index].icon.id = old.id
            }
            if !assigned.insert(records[index].icon.id).inserted {
                records[index].icon.id = unique(records[index].icon.id, used: &assigned)
            }
        }
        used = Set(records.map { $0.icon.id })
        for window in windows where !claimed.contains(window.id) && !duplicates.contains(window.id) {
            let app = NSRunningApplication(processIdentifier: window.pid)
            let bundle = app?.bundleIdentifier ?? "pid.\(window.pid)"
            let base = "\(bundle)|status-item"
            let old = previous.first { $0.windowID == window.id && $0.bundleID == bundle }
            let id: String
            if let old, used.insert(old.id).inserted { id = old.id }
            else { id = unique(base, used: &used) }
            let title = window.title.isEmpty ? app?.localizedName ?? window.owner : window.title
            records.append(Record(icon: MenuBarIcon(id: id, title: title, bundleID: bundle, pid: window.pid,
                                                   frame: window.frame, image: nil, windowID: window.id,
                                                   movable: !fixedSystemItem(bundle: bundle, identifier: nil, title: title)),
                                  element: nil, axFrame: nil, semanticIdentifier: nil, renderer: window))
        }
        for (index, record) in records.enumerated() {
            guard let renderer = record.renderer else {
                guard record.element != nil else { continue }
                let candidates = pairs.filter { $0.record == index }.map { windows[$0.window].id }
                let reason = !MenuLayoutPlanner.usable(record.axFrame ?? .zero) ? "ax-geometry-unavailable"
                    : ambiguousRecords.contains(index) ? "ambiguous-renderer-geometry"
                    : candidates.isEmpty ? "no-overlapping-renderer" : "renderer-claimed-by-another-ax-item"
                mappings.append(MenuWindowMappingSnapshot(windowID: 0, pid: record.icon.pid, owner: record.icon.bundleID,
                                                         title: record.icon.title,
                                                         quartzFrame: Self.components(coordinates.quartzRect(record.icon.frame)),
                                                         cocoaFrame: Self.components(record.icon.frame), axID: record.icon.id,
                                                         axPID: record.icon.pid, axBundleID: record.icon.bundleID,
                                                         axFrame: record.axFrame.map(Self.components), match: "unmatched-ax", duplicate: false,
                                                         rejectionReason: reason, candidateWindowIDs: Array(Set(candidates)).sorted(),
                                                         axTitle: record.icon.title))
                continue
            }
            mappings.append(mapping(renderer, record: record,
                                    match: record.element == nil ? "renderer-only" : renderer.pid == record.icon.pid ? "geometry-pid" : "geometry-cross-pid",
                                    duplicate: false))
        }
        return Snapshot(records: records.sorted {
            if $0.icon.frame.minX != $1.icon.frame.minX { return $0.icon.frame.minX < $1.icon.frame.minX }
            return $0.icon.id < $1.icon.id
        }, windows: all, mappings: mappings.sorted { $0.windowID < $1.windowID })
    }

    /// Per-window CG queries are empty for some remote renderers on macOS 26.
    /// Always enumerate the global list and filter a safely converted number.
    func allWindows() -> [Window] {
        let coordinates = MenuCoordinates.current
        guard let entries = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let id = CGWindowID(exactly: number.int64Value), id != 0,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let pid = pid_t(exactly: ownerPID.int64Value), pid > 0,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
            return Window(id: id, pid: pid, owner: entry[kCGWindowOwnerName as String] as? String ?? "",
                          title: entry[kCGWindowName as String] as? String ?? "",
                          layer: (entry[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0,
                          quartzFrame: rect, frame: coordinates.cocoaRect(rect),
                          isOnScreen: (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                          alpha: CGFloat((entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1))
        }
    }

    func window(_ id: CGWindowID) -> Window? { allWindows().first { $0.id == id } }

    func statusRenderer(_ item: NSStatusItem, windows: [Window]? = nil) -> Window? {
        let list = windows ?? allWindows()
        // On macOS 26 the NSStatusItem window is a local proxy (often -1 or
        // zero-sized), while Control Center owns the actual renderer. Its
        // title is redacted when screen-capture permission is unavailable.
        // Once resolved, identity does not depend on that optional title.
        if let name = item.autosaveName, !name.isEmpty {
            if let identity = statusRenderers[name], let cached = list.first(where: { $0.id == identity.id }) {
                if cached.pid == identity.pid, cached.layer == 24 || cached.layer == 25,
                   cached.title.isEmpty || cached.title == name,
                   !cached.owner.lowercased().contains("windowserver") {
                    if MenuLayoutPlanner.usable(cached.frame) { return cached }
                } else { statusRenderers.removeValue(forKey: name) }
            }
            let named = list.filter {
                $0.title == name && ($0.layer == 24 || $0.layer == 25)
                    && MenuLayoutPlanner.usable($0.frame)
                    && !$0.owner.lowercased().contains("windowserver")
            }
            if named.count == 1, let renderer = named.first {
                rememberStatusRenderer(renderer, item: item)
                return renderer
            }
            // A temporarily missing or zero-sized renderer retains its known
            // identity, but cannot be used until it appears with valid bounds.
            if !named.isEmpty { return nil }
        }
        if let number = item.button?.window?.windowNumber,
           let id = CGWindowID(exactly: number), id != 0,
           let window = list.first(where: { $0.id == id }), MenuLayoutPlanner.usable(window.frame) {
            rememberStatusRenderer(window, item: item)
            return window
        }
        guard let frame = Self.statusFrame(item) else { return nil }
        let candidates = list.compactMap { window -> (Window, CGFloat)? in
            guard window.layer == 24 || window.layer == 25,
                  !window.owner.lowercased().contains("windowserver"),
                  let score = MenuCoordinates.matchScore(frame, window.frame), score >= 80 else { return nil }
            return (window, score)
        }.sorted { $0.1 > $1.1 }
        guard let first = candidates.first else { return nil }
        if candidates.count > 1, first.1 - candidates[1].1 < 1 { return nil }
        rememberStatusRenderer(first.0, item: item)
        return first.0
    }

    private func rememberStatusRenderer(_ window: Window, item: NSStatusItem) {
        guard let name = item.autosaveName, !name.isEmpty else { return }
        statusRenderers[name] = StatusRendererIdentity(id: window.id, pid: window.pid)
    }

    static func statusFrame(_ item: NSStatusItem) -> CGRect? {
        guard let button = item.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return MenuLayoutPlanner.usable(frame) ? frame : nil
    }

    private func accessibleItems() -> [AccessibleItem] {
        var result: [AccessibleItem] = []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.sorted {
            let lhs = $0.bundleIdentifier ?? "", rhs = $1.bundleIdentifier ?? ""
            return lhs == rhs ? $0.processIdentifier < $1.processIdentifier : lhs < rhs
        }
        for app in apps where app.processIdentifier > 0 && app.processIdentifier != ownPID {
            if let bundle = Bundle.main.bundleIdentifier, app.bundleIdentifier == bundle { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.08)
            guard let extras = MenuAccessibility.attribute(element, kAXExtrasMenuBarAttribute) else { continue }
            let items = MenuAccessibility.menuItems(extras)
            for item in items {
                AXUIElementSetMessagingTimeout(item, 0.08)
                let frame = MenuAccessibility.frame(item) ?? .zero
                let identifier = MenuAccessibility.string(item, kAXIdentifierAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let semantic = identifier?.isEmpty == false ? identifier : nil
                guard MenuLayoutPlanner.usable(frame) || semantic != nil else { continue }
                let title = [MenuAccessibility.string(item, kAXTitleAttribute),
                             MenuAccessibility.string(item, kAXDescriptionAttribute), app.localizedName]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? "菜单栏图标"
                let bundle = app.bundleIdentifier ?? "pid.\(app.processIdentifier)"
                result.append(AccessibleItem(baseID: "\(bundle)|\(semantic ?? "status-item")", title: title,
                                             bundleID: bundle, pid: app.processIdentifier, frame: frame,
                                             element: item, identifier: semantic,
                                             movable: !fixedSystemItem(bundle: bundle, identifier: semantic, title: title)))
            }
        }
        return result
    }

    private func fixedSystemItem(bundle: String, identifier: String?, title: String) -> Bool {
        guard bundle.hasPrefix("com.apple.") else { return false }
        if let identifier {
            let component = identifier.lowercased().split(separator: ".").last.map(String.init) ?? ""
            return component == "clock" || (bundle == "com.apple.controlcenter"
                && ["controlcenter", "control-center"].contains(component))
        }
        let lower = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["clock", "时钟"].contains(lower) || (bundle == "com.apple.controlcenter" && ["control center", "控制中心"].contains(lower))
    }

    private func unique(_ base: String, used: inout Set<String>) -> String {
        if used.insert(base).inserted { return base }
        var index = 2
        while !used.insert("\(base)#\(index)").inserted { index += 1 }
        return "\(base)#\(index)"
    }
    private func mapping(_ window: Window, record: Record?, match: String, duplicate: Bool) -> MenuWindowMappingSnapshot {
        MenuWindowMappingSnapshot(windowID: window.id, pid: window.pid, owner: window.owner, title: window.title,
                                  quartzFrame: Self.components(window.quartzFrame), cocoaFrame: Self.components(window.frame),
                                  axID: record?.element == nil ? nil : record?.icon.id,
                                  axPID: record?.element == nil ? nil : record?.icon.pid,
                                  axBundleID: record?.element == nil ? nil : record?.icon.bundleID,
                                  axFrame: record?.axFrame.map(Self.components), match: match, duplicate: duplicate,
                                  axTitle: record?.element == nil ? nil : record?.icon.title)
    }
    static func components(_ rect: CGRect) -> [Double] {
        [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
    }
}

@MainActor enum MenuAccessibility {
    static func attribute(_ item: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(item, name as CFString, &value) == .success ? value : nil
    }
    static func string(_ item: AXUIElement, _ name: String) -> String? { attribute(item, name) as? String }
    static func elements(_ value: CFTypeRef) -> [AXUIElement] {
        if CFGetTypeID(value) == AXUIElementGetTypeID() { return [unsafeBitCast(value, to: AXUIElement.self)] }
        guard let array = value as? NSArray else { return [] }
        return array.compactMap { object in
            let value = object as CFTypeRef
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? unsafeBitCast(value, to: AXUIElement.self) : nil
        }
    }
    static func frame(_ item: AXUIElement) -> CGRect? {
        guard let position = attribute(item, kAXPositionAttribute), let size = attribute(item, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        return MenuCoordinates.current.cocoaRect(CGRect(origin: point, size: dimensions))
    }
    static func menuItems(_ value: CFTypeRef, depth: Int = 0) -> [AXUIElement] {
        guard depth < 6 else { return [] }
        return elements(value).flatMap { item -> [AXUIElement] in
            let role = string(item, kAXRoleAttribute)
            if role == kAXMenuBarItemRole { return [item] }
            if let children = attribute(item, kAXChildrenAttribute) {
                let leaves = menuItems(children, depth: depth + 1)
                if !leaves.isEmpty { return leaves }
            }
            guard role != kAXMenuBarRole, let bounds = frame(item), MenuLayoutPlanner.usable(bounds),
                  string(item, kAXIdentifierAttribute) != nil || string(item, kAXTitleAttribute) != nil else { return [] }
            return [item]
        }
    }
}
