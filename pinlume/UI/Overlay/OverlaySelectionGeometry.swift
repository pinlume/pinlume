import Cocoa

enum OverlaySelectionGeometry {
    enum WindowSnapOutputSource: Equatable {
        case visibleScreen
        case independentWindow
    }

    enum WindowSnapPreviewSource: Equatable {
        case visibleScreen
        case independentWindow
    }

    enum DoubleClickAction {
        case passThrough
        case waitForSecondClick
        case copy
        case pin
    }

    enum CommandShortcutAction {
        case passThrough
        case save
    }

    enum CopyShortcutAction {
        case passThrough
        case copySelectedAnnotations
        case copyFullSelection
    }

    nonisolated static let minimumWindowSnapSize = CGSize(width: 80, height: 80)
    nonisolated static let minimumFloatingWindowSnapSize = CGSize(width: 24, height: 24)

    static func shouldFallbackToFullScreen(
        point: CGPoint,
        overlayBounds: CGRect,
        visibleBounds: CGRect
    ) -> Bool {
        containsInclusive(point, in: overlayBounds)
            && !containsInclusive(point, in: visibleBounds)
    }

    static func immediateSystemReservedSnapRect(
        point: CGPoint,
        overlayBounds: CGRect,
        visibleBounds: CGRect
    ) -> CGRect? {
        shouldFallbackToFullScreen(
            point: point,
            overlayBounds: overlayBounds,
            visibleBounds: visibleBounds
        ) ? overlayBounds : nil
    }

    static func containsInclusive(_ point: CGPoint, in rect: CGRect) -> Bool {
        point.x >= rect.minX
            && point.x <= rect.maxX
            && point.y >= rect.minY
            && point.y <= rect.maxY
    }

    /// Keeps a real Window Server candidate stable when a later query
    /// momentarily omits it. Window rectangles use half-open far edges so two
    /// adjacent status items never both own their shared boundary.
    static func shouldRetainConfirmedWindowSnap(
        point: CGPoint,
        currentRect: CGRect?,
        hasCurrentWindowIdentity: Bool,
        queryFoundWindow: Bool
    ) -> Bool {
        guard !queryFoundWindow,
              hasCurrentWindowIdentity,
              let rect = currentRect?.standardized,
              !rect.isNull,
              !rect.isEmpty
        else { return false }

        return point.x >= rect.minX
            && point.x < rect.maxX
            && point.y >= rect.minY
            && point.y < rect.maxY
    }

    nonisolated static func acceptedWindowSnapRect(
        _ rect: CGRect,
        overlayBounds: CGRect,
        visibleBounds: CGRect? = nil,
        minimumSize: CGSize = minimumWindowSnapSize,
        isSystemOwnedSurface: Bool = false
    ) -> CGRect? {
        let clipped = rect.intersection(overlayBounds)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }

        if let visibleBounds {
            let visibleIntersection = clipped.intersection(visibleBounds)
            let isSystemSurface = clipped.width >= overlayBounds.width * 0.65
                && (visibleIntersection.isNull || visibleIntersection.isEmpty)
            if isSystemSurface { return nil }
        }

        if isSystemOwnedSurface {
            let edgeTolerance: CGFloat = 1
            let touchesHorizontalEdge = abs(clipped.minY - overlayBounds.minY) <= edgeTolerance
                || abs(clipped.maxY - overlayBounds.maxY) <= edgeTolerance
            let touchesVerticalEdge = abs(clipped.minX - overlayBounds.minX) <= edgeTolerance
                || abs(clipped.maxX - overlayBounds.maxX) <= edgeTolerance
            let isHorizontalSystemStrip = touchesHorizontalEdge
                && clipped.width >= overlayBounds.width * 0.65
            let isVerticalSystemStrip = touchesVerticalEdge
                && clipped.height >= overlayBounds.height * 0.65
            if isHorizontalSystemStrip || isVerticalSystemStrip { return nil }
        }

        guard clipped.width >= minimumSize.width,
              clipped.height >= minimumSize.height else { return nil }

        return clipped
    }

    nonisolated static func isPinlumePinWindow(ownerName: String, windowName: String) -> Bool {
        ownerName.lowercased().contains("Pinlume")
            && windowName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "Pinlume plus pin"
    }

    static func clampedSelectionRect(_ rect: CGRect, overlayBounds: CGRect) -> CGRect {
        let clipped = rect.standardized.intersection(overlayBounds)
        if clipped.isNull || clipped.isEmpty {
            return .zero
        }
        return clipped
    }

    static func clampedMovedRect(_ rect: CGRect, overlayBounds: CGRect) -> CGRect {
        var rect = rect.standardized
        if rect.width > overlayBounds.width || rect.height > overlayBounds.height {
            return clampedSelectionRect(rect, overlayBounds: overlayBounds)
        }
        rect.origin.x = max(overlayBounds.minX, min(rect.origin.x, overlayBounds.maxX - rect.width))
        rect.origin.y = max(overlayBounds.minY, min(rect.origin.y, overlayBounds.maxY - rect.height))
        return rect
    }

    static func expandedSelectionRect(
        _ rect: CGRect,
        toInclude point: CGPoint,
        overlayBounds: CGRect
    ) -> CGRect {
        let rect = rect.standardized
        let clampedPoint = CGPoint(
            x: max(overlayBounds.minX, min(point.x, overlayBounds.maxX)),
            y: max(overlayBounds.minY, min(point.y, overlayBounds.maxY))
        )
        let expanded = CGRect(
            x: min(rect.minX, clampedPoint.x),
            y: min(rect.minY, clampedPoint.y),
            width: max(rect.maxX, clampedPoint.x) - min(rect.minX, clampedPoint.x),
            height: max(rect.maxY, clampedPoint.y) - min(rect.minY, clampedPoint.y)
        )
        return clampedSelectionRect(expanded, overlayBounds: overlayBounds)
    }

    static func doubleClickAction(
        clickCount: Int,
        isInsideSelection: Bool,
        hitTextAnnotation: Bool,
        textEditorIsEditing: Bool,
        hasPendingTextToolDoubleClick: Bool,
        shouldCopy: Bool
    ) -> DoubleClickAction {
        // Existing text always owns a double-click. The text tool remains
        // active after placement, so limiting this to `.select` pins instead
        // of reopening text for editing.
        if hitTextAnnotation && !textEditorIsEditing {
            return .passThrough
        }
        if textEditorIsEditing && !hasPendingTextToolDoubleClick {
            return .passThrough
        }
        if clickCount >= 2 {
            return shouldCopy && isInsideSelection ? .copy : .pin
        }
        return isInsideSelection ? .waitForSecondClick : .passThrough
    }

    static func commandShortcutAction(keyCode: UInt16, isSelectionActive: Bool) -> CommandShortcutAction {
        guard isSelectionActive, keyCode == 1 else { return .passThrough }
        return .save
    }

    static func copyShortcutAction(
        isSelectionActive: Bool,
        isDrawingToolActive: Bool,
        hasSelectedAnnotations: Bool
    ) -> CopyShortcutAction {
        guard isSelectionActive else { return .passThrough }
        if isDrawingToolActive || !hasSelectedAnnotations {
            return .copyFullSelection
        }
        return .copySelectedAnnotations
    }

    static func windowSnapOutputSource(
        ignoreOcclusion: Bool,
        selectionIsWindowSnap: Bool,
        hasIndependentWindowImage: Bool
    ) -> WindowSnapOutputSource {
        ignoreOcclusion && selectionIsWindowSnap && hasIndependentWindowImage
            ? .independentWindow : .visibleScreen
    }

    static func windowSnapPreviewSource(
        ignoreOcclusion: Bool,
        selectionIsWindowSnap: Bool,
        hasIndependentWindowImage: Bool,
        isSingleScreenSelection: Bool
    ) -> WindowSnapPreviewSource {
        ignoreOcclusion && selectionIsWindowSnap && hasIndependentWindowImage && isSingleScreenSelection
            ? .independentWindow : .visibleScreen
    }
}

enum OverlayShortcutAction: Equatable {
    case passThrough
    case save
    case undoSelection
    case undoAnnotations
}

enum OverlayShortcutRouting {
    static func commandShortcutAction(
        keyCode: UInt16,
        isSelectionActive: Bool,
        shiftHeld: Bool,
        hasSelectionUndoHistory: Bool
    ) -> OverlayShortcutAction {
        guard isSelectionActive else { return .passThrough }
        if keyCode == 1 { return .save }
        guard keyCode == 6, !shiftHeld else { return .passThrough }
        return hasSelectionUndoHistory ? .undoSelection : .undoAnnotations
    }
}
