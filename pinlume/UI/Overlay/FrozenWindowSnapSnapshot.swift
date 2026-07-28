import Cocoa

nonisolated struct FrozenWindowSnapResult: Sendable {
    let rect: NSRect
    let windowID: CGWindowID?
    let supportsIndependentCapture: Bool
}

nonisolated struct FrozenWindowSnapCandidate: Sendable {
    let rect: NSRect
    let windowID: CGWindowID
    let ownerPID: Int
    let ownerName: String
    let windowName: String
    let layer: Int
    let zOrder: Int
    let isFloating: Bool
    let isSystemOwnedSurface: Bool
    let isPinlumePin: Bool
    let supportsIndependentCapture: Bool

    var area: CGFloat { rect.width * rect.height }

    var isQuickLook: Bool {
        let owner = ownerName.lowercased()
        let name = windowName.lowercased()
        return owner.contains("quicklook")
            || owner.contains("quick look")
            || name.contains("quicklook")
            || name.contains("quick look")
    }
}

/// Window Server candidates captured before the screenshot overlay closes
/// transient app menus. Mouse movement queries this immutable list only.
nonisolated struct FrozenWindowSnapSnapshot: @unchecked Sendable {
    static let empty = FrozenWindowSnapSnapshot(candidates: [])

    let candidates: [FrozenWindowSnapCandidate]

    var count: Int { candidates.count }

    static func capture(appKitReferenceTopY: CGFloat) -> FrozenWindowSnapSnapshot {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return .empty }

        var bundleIdentifiers: [Int: String] = [:]
        let candidates = windowList.enumerated().compactMap { zOrder, info in
            let ownerPID = (info[kCGWindowOwnerPID as String] as? Int) ?? 0
            let bundleIdentifier: String
            if let cached = bundleIdentifiers[ownerPID] {
                bundleIdentifier = cached
            } else {
                bundleIdentifier = NSRunningApplication(
                    processIdentifier: pid_t(ownerPID))?.bundleIdentifier?.lowercased() ?? ""
                bundleIdentifiers[ownerPID] = bundleIdentifier
            }
            return candidate(
                from: info,
                zOrder: zOrder,
                appKitReferenceTopY: appKitReferenceTopY,
                bundleIdentifier: bundleIdentifier)
        }
        return FrozenWindowSnapSnapshot(candidates: candidates)
    }

    private static func candidate(
        from info: [String: Any],
        zOrder: Int,
        appKitReferenceTopY: CGFloat,
        bundleIdentifier: String
    ) -> FrozenWindowSnapCandidate? {
        guard let layer = info[kCGWindowLayer as String] as? Int,
              let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
              let number = info[kCGWindowNumber as String] as? Int
        else { return nil }

        let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1
        let isFloating = layer > 0 && alpha >= 0.05
        let ownerName = (info[kCGWindowOwnerName as String] as? String) ?? ""
        let windowName = (info[kCGWindowName as String] as? String) ?? ""
        let ownerPID = (info[kCGWindowOwnerPID as String] as? Int) ?? 0
        let quickLook = isQuickLook(ownerName: ownerName, windowName: windowName)
        let pinlumeOwned = ownerName.lowercased().contains("Pinlume")
        guard shouldIncludeCandidate(
            layer: layer,
            alpha: alpha,
            isQuickLook: quickLook,
            isPinlumeOwned: pinlumeOwned)
        else { return nil }

        let width = bounds["Width"] ?? 0
        let height = bounds["Height"] ?? 0
        guard width > 10, height > 10 else { return nil }
        let rect = NSRect(
            x: bounds["X"] ?? 0,
            y: appKitReferenceTopY - (bounds["Y"] ?? 0) - height,
            width: width,
            height: height)
        let isPinlumePin = OverlaySelectionGeometry.isPinlumePinWindow(
            ownerName: ownerName,
            windowName: windowName)
        let systemOwned = isSystemOwnedSurface(
            ownerPID: ownerPID,
            bundleIdentifier: bundleIdentifier)
        let supportsIndependentCapture = supportsIndependentCapture(
            layer: layer,
            isSystemOwnedSurface: systemOwned,
            isQuickLook: quickLook,
            isPinlumePin: isPinlumePin)

        return FrozenWindowSnapCandidate(
            rect: rect,
            windowID: CGWindowID(number),
            ownerPID: ownerPID,
            ownerName: ownerName,
            windowName: windowName,
            layer: layer,
            zOrder: zOrder,
            isFloating: isFloating,
            isSystemOwnedSurface: systemOwned,
            isPinlumePin: isPinlumePin,
            supportsIndependentCapture: supportsIndependentCapture)
    }

    private static func isQuickLook(ownerName: String, windowName: String) -> Bool {
        let owner = ownerName.lowercased()
        let name = windowName.lowercased()
        return owner.contains("quicklook")
            || owner.contains("quick look")
            || name.contains("quicklook")
            || name.contains("quick look")
    }

    /// Negative layers are WindowServer desktop/chrome composition, not
    /// selectable app surfaces. Menus and status items use positive layers.
    static func shouldIncludeCandidate(
        layer: Int,
        alpha: CGFloat,
        isQuickLook: Bool,
        isPinlumeOwned: Bool
    ) -> Bool {
        guard layer >= 0 else { return false }
        return layer == 0 || alpha >= 0.05 || isQuickLook || isPinlumeOwned
    }

    static func supportsIndependentCapture(
        layer: Int,
        isSystemOwnedSurface: Bool,
        isQuickLook: Bool,
        isPinlumePin: Bool
    ) -> Bool {
        !isSystemOwnedSurface && (layer == 0 || isQuickLook || isPinlumePin)
    }

    /// Uses process identity rather than localized owner names. Small status
    /// items still pass geometry validation; only oversized edge hosts are rejected.
    private static func isSystemOwnedSurface(
        ownerPID: Int,
        bundleIdentifier: String
    ) -> Bool {
        ownerPID == 0
            || bundleIdentifier == "com.apple.systemuiserver"
            || bundleIdentifier == "com.apple.controlcenter"
            || bundleIdentifier == "com.apple.notificationcenterui"
    }

    func windowSnapResult(
        screenPoint: NSPoint,
        windowOrigin: NSPoint,
        viewBounds: NSRect,
        visibleBounds: NSRect
    ) -> FrozenWindowSnapResult? {
        var accepted: [(candidate: FrozenWindowSnapCandidate, rect: NSRect)] = []
        accepted.reserveCapacity(4)

        for candidate in candidates {
            var appKitRect = candidate.rect
            if candidate.isPinlumePin {
                appKitRect = appKitRect.insetBy(
                    dx: PinGeometry.defaultShadowOutset,
                    dy: PinGeometry.defaultShadowOutset)
            }
            guard appKitRect.width > 10,
                  appKitRect.height > 10,
                  containsHalfOpen(screenPoint, in: appKitRect)
            else { continue }

            let viewRect = NSRect(
                x: appKitRect.origin.x - windowOrigin.x,
                y: appKitRect.origin.y - windowOrigin.y,
                width: appKitRect.width,
                height: appKitRect.height)
            let isPinlumeOwned = candidate.ownerName.lowercased().contains("Pinlume")
            if isPinlumeOwned
                && viewRect.width >= viewBounds.width * 0.9
                && viewRect.height >= viewBounds.height * 0.9 {
                continue
            }
            if candidate.isFloating
                && viewRect.width >= viewBounds.width * 0.96
                && viewRect.height >= viewBounds.height * 0.96 {
                continue
            }
            guard let rect = OverlaySelectionGeometry.acceptedWindowSnapRect(
                viewRect,
                overlayBounds: viewBounds,
                visibleBounds: visibleBounds,
                minimumSize: candidate.isFloating
                    ? OverlaySelectionGeometry.minimumFloatingWindowSnapSize
                    : OverlaySelectionGeometry.minimumWindowSnapSize,
                isSystemOwnedSurface: candidate.isSystemOwnedSurface)
            else { continue }
            accepted.append((candidate, rect))
        }

        guard let frontmost = accepted.min(by: { $0.candidate.zOrder < $1.candidate.zOrder })
        else { return nil }

        // WindowServer also exposes transient input/cursor surfaces as tiny
        // positive-layer windows. They must remain selectable on their own
        // (for example, status items), but must not replace the actual app
        // window below when the pointer happens to cross one during capture.
        let prominentFloating = accepted
            .filter { floatingCandidateShouldOverrideRegularWindow($0) }
            .min { lhs, rhs in
                if lhs.candidate.layer != rhs.candidate.layer {
                    return lhs.candidate.layer > rhs.candidate.layer
                }
                return lhs.candidate.zOrder < rhs.candidate.zOrder
            }
        let frontmostRegular = accepted
            .filter { !$0.candidate.isFloating }
            .min(by: { $0.candidate.zOrder < $1.candidate.zOrder })
        let chosen: (candidate: FrozenWindowSnapCandidate, rect: NSRect)
        if let prominentFloating {
            chosen = prominentFloating
        } else if let frontmostRegular,
                  frontmostRegular.candidate.ownerName.lowercased() == "finder"
                    || frontmostRegular.candidate.isQuickLook {
            chosen = accepted
                .filter {
                    $0.candidate.ownerPID == frontmostRegular.candidate.ownerPID
                        && isLikelyFinderQuickLookPreview(
                            $0.candidate,
                            frontmost: frontmostRegular.candidate)
                }
                .min(by: { $0.candidate.area < $1.candidate.area })
                ?? frontmostRegular
        } else if let frontmostRegular {
            chosen = frontmostRegular
        } else {
            chosen = frontmost
        }

        return FrozenWindowSnapResult(
            rect: chosen.rect,
            windowID: chosen.candidate.windowID,
            supportsIndependentCapture: chosen.candidate.supportsIndependentCapture)
    }

    private func containsHalfOpen(_ point: NSPoint, in rect: NSRect) -> Bool {
        point.x >= rect.minX && point.x < rect.maxX
            && point.y >= rect.minY && point.y < rect.maxY
    }

    private func floatingCandidateShouldOverrideRegularWindow(
        _ entry: (candidate: FrozenWindowSnapCandidate, rect: NSRect)
    ) -> Bool {
        let candidate = entry.candidate
        guard candidate.isFloating else { return false }
        return candidate.isQuickLook
            || (entry.rect.width >= OverlaySelectionGeometry.minimumWindowSnapSize.width
                && entry.rect.height >= OverlaySelectionGeometry.minimumWindowSnapSize.height)
    }

    private func isLikelyFinderQuickLookPreview(
        _ candidate: FrozenWindowSnapCandidate,
        frontmost: FrozenWindowSnapCandidate
    ) -> Bool {
        if candidate.isQuickLook { return true }
        guard candidate.ownerName.lowercased() == "finder",
              candidate.windowID != frontmost.windowID
        else { return false }
        return candidate.windowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && candidate.area < frontmost.area * 0.85
            && candidate.rect.width >= 80
            && candidate.rect.height >= 80
    }
}
