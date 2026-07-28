import CoreGraphics
import Foundation

enum PinZoomAnchorMode: String {
    case topLeft
    case mouse

    static let userDefaultsKey = "pinZoomAnchorMode"
}

enum PinZoomInputPreferences {
    static let wheelEnabledKey = "pinWheelZoomEnabled"
    static let magnifyEnabledKey = "pinMagnifyZoomEnabled"
    static let smoothEnabledKey = "pinSmoothZoomEnabled"

    static var isWheelZoomEnabled: Bool {
        UserDefaults.standard.object(forKey: wheelEnabledKey) as? Bool ?? true
    }

    static var isMagnifyZoomEnabled: Bool {
        UserDefaults.standard.object(forKey: magnifyEnabledKey) as? Bool ?? true
    }

    static var isSmoothZoomEnabled: Bool {
        UserDefaults.standard.object(forKey: smoothEnabledKey) as? Bool ?? true
    }
}

enum PinCaptureReturnAction {
    case pin
    case confirmAnnotations
    case copyToClipboard
}

enum PinToolbarToggleAction {
    case show
    case hide
    case ignore
}

enum PinToolbarConfirmAction {
    case confirmAnnotations
    case hideToolbar
}

enum PinCommandShortcutAction {
    case passThrough
    case save
    case copy
    case close
}

enum PinToolbarHideReason {
    case userToggle
    case explicitAction
    case temporaryInteraction
}

enum PinToolbarHideAction {
    case hideOnly
    case hideAndCancelTool
}

enum PinGeometry {
    nonisolated static let defaultShadowOutset: CGFloat = 24
    static let defaultCompactSize = CGSize(width: 55, height: 55)

    static func windowFrame(forVisualFrame frame: CGRect, shadowOutset: CGFloat) -> CGRect {
        frame.insetBy(dx: -shadowOutset, dy: -shadowOutset)
    }

    static func visualFrame(fromWindowFrame frame: CGRect, shadowOutset: CGFloat) -> CGRect {
        frame.insetBy(dx: shadowOutset, dy: shadowOutset)
    }

    /// Matches screenshot crop geometry: every edge is independently rounded
    /// to the display's physical-pixel grid.
    static func pixelAlignedVisualFrame(_ frame: CGRect, scale: CGFloat) -> CGRect {
        guard scale > 0 else { return frame }
        return CGRect(
            x: round(frame.origin.x * scale) / scale,
            y: round(frame.origin.y * scale) / scale,
            width: round(frame.size.width * scale) / scale,
            height: round(frame.size.height * scale) / scale
        )
    }

    /// NSPanel keeps an integral-point outer frame even on Retina displays.
    /// Keep the image/canvas at its requested backing-pixel coordinates inside
    /// that actual frame instead of accepting WindowServer's point rounding.
    static func displayFrame(
        forVisualFrame visualFrame: CGRect,
        inWindowFrame windowFrame: CGRect
    ) -> CGRect {
        CGRect(
            x: visualFrame.minX - windowFrame.minX,
            y: visualFrame.minY - windowFrame.minY,
            width: visualFrame.width,
            height: visualFrame.height
        )
    }

    static func viewPoint(forScreenPoint screenPoint: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(x: screenPoint.x - windowFrame.minX, y: screenPoint.y - windowFrame.minY)
    }

    static func screenPoint(forViewPoint viewPoint: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(x: windowFrame.minX + viewPoint.x, y: windowFrame.minY + viewPoint.y)
    }

    static func normalizedVisualPoint(
        viewPoint: CGPoint,
        visualSize: CGSize,
        shadowOutset: CGFloat
    ) -> CGPoint {
        guard visualSize.width > 0, visualSize.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return CGPoint(
            x: min(1, max(0, (viewPoint.x - shadowOutset) / visualSize.width)),
            y: min(1, max(0, (viewPoint.y - shadowOutset) / visualSize.height))
        )
    }

    static func normalizedVisualPoint(
        screenPoint: CGPoint,
        visualFrame: CGRect
    ) -> CGPoint {
        guard visualFrame.width > 0, visualFrame.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return CGPoint(
            x: min(1, max(0, (screenPoint.x - visualFrame.minX) / visualFrame.width)),
            y: min(1, max(0, (screenPoint.y - visualFrame.minY) / visualFrame.height))
        )
    }

    static func visualFrameForDrag(
        mouseScreen: CGPoint,
        imagePointOffset: CGPoint,
        visualSize: CGSize
    ) -> CGRect {
        CGRect(
            x: mouseScreen.x - imagePointOffset.x,
            y: mouseScreen.y - imagePointOffset.y,
            width: visualSize.width,
            height: visualSize.height
        )
    }

    static func zoomedVisualFrame(
        currentVisual: CGRect,
        baseVisualSize: CGSize,
        factor: CGFloat,
        anchorScreen: CGPoint,
        minScale: CGFloat,
        maxScale: CGFloat,
        snapToUnitDistance: CGFloat,
        snapCandidates: [CGRect]
    ) -> CGRect {
        zoomedVisualFrame(
            currentVisual: currentVisual,
            baseVisualSize: baseVisualSize,
            factor: factor,
            normalizedAnchor: normalizedVisualPoint(screenPoint: anchorScreen, visualFrame: currentVisual),
            anchorScreen: anchorScreen,
            minScale: minScale,
            maxScale: maxScale,
            snapToUnitDistance: snapToUnitDistance,
            snapCandidates: snapCandidates
        )
    }

    static func zoomedVisualFrame(
        currentVisual: CGRect,
        baseVisualSize: CGSize,
        factor: CGFloat,
        zoomSession: PinZoomSession,
        minScale: CGFloat,
        maxScale: CGFloat,
        snapToUnitDistance: CGFloat,
        snapCandidates: [CGRect]
    ) -> CGRect {
        zoomedVisualFrame(
            currentVisual: currentVisual,
            baseVisualSize: baseVisualSize,
            factor: factor,
            normalizedAnchor: zoomSession.normalizedAnchor,
            anchorScreen: zoomSession.anchorScreen,
            minScale: minScale,
            maxScale: maxScale,
            snapToUnitDistance: snapToUnitDistance,
            snapCandidates: snapCandidates
        )
    }

    static func zoomedVisualFrame(
        currentVisual: CGRect,
        baseVisualSize: CGSize,
        factor: CGFloat,
        normalizedAnchor: CGPoint,
        anchorScreen: CGPoint,
        minScale: CGFloat,
        maxScale: CGFloat,
        snapToUnitDistance: CGFloat,
        snapCandidates: [CGRect]
    ) -> CGRect {
        guard baseVisualSize.width > 0, baseVisualSize.height > 0 else {
            return currentVisual
        }

        let currentScale = currentVisual.width / baseVisualSize.width
        let newScale = min(maxScale, max(minScale, currentScale * factor))

        let newSize = CGSize(
            width: round(baseVisualSize.width * newScale),
            height: round(baseVisualSize.height * newScale)
        )
        var visual = CGRect(
            x: anchorScreen.x - normalizedAnchor.x * newSize.width,
            y: anchorScreen.y - normalizedAnchor.y * newSize.height,
            width: newSize.width,
            height: newSize.height
        )

        if !snapCandidates.isEmpty {
            visual = snappedVisualFrame(visual, screenFrames: snapCandidates, snapDistance: 8)
        }
        return visual
    }

    static func topLeftAnchoredZoomedVisualFrame(
        currentVisual: CGRect,
        baseVisualSize: CGSize,
        factor: CGFloat,
        minScale: CGFloat,
        maxScale: CGFloat
    ) -> CGRect {
        guard baseVisualSize.width > 0, baseVisualSize.height > 0 else {
            return currentVisual
        }

        let currentScale = currentVisual.width / baseVisualSize.width
        let newScale = min(maxScale, max(minScale, currentScale * factor))
        let newSize = CGSize(
            width: round(baseVisualSize.width * newScale),
            height: round(baseVisualSize.height * newScale)
        )
        return CGRect(
            x: currentVisual.minX,
            y: currentVisual.maxY - newSize.height,
            width: newSize.width,
            height: newSize.height
        )
    }

    static func acceptsZoomEvent(pointerInside: Bool, sessionActive: Bool) -> Bool {
        pointerInside || sessionActive
    }

    static func acceptsTopLeftZoomEvent(pointerInside: Bool, continuationActive: Bool) -> Bool {
        acceptsZoomEvent(pointerInside: pointerInside, sessionActive: continuationActive)
    }

    static func canvasPoint(
        forViewPoint viewPoint: CGPoint,
        visualSize: CGSize,
        canvasSize: CGSize,
        shadowOutset: CGFloat
    ) -> CGPoint {
        let normalized = normalizedVisualPoint(
            viewPoint: viewPoint,
            visualSize: visualSize,
            shadowOutset: shadowOutset
        )
        return CGPoint(
            x: normalized.x * canvasSize.width,
            y: normalized.y * canvasSize.height
        )
    }

    /// Returns the first point where a drag segment enters an image rectangle.
    /// A pointer that began outside a pin must not create a measurement until
    /// it crosses into the actual image content.
    static func measurementEntryPoint(
        from previousPoint: CGPoint,
        to currentPoint: CGPoint,
        in imageRect: CGRect
    ) -> CGPoint? {
        let bounds = imageRect.standardized
        guard !bounds.isEmpty, bounds.contains(currentPoint) else { return nil }
        guard !bounds.contains(previousPoint) else { return previousPoint }

        let dx = currentPoint.x - previousPoint.x
        let dy = currentPoint.y - previousPoint.y
        var candidates: [(t: CGFloat, point: CGPoint)] = []

        if dx != 0 {
            for x in [bounds.minX, bounds.maxX] {
                let t = (x - previousPoint.x) / dx
                let y = previousPoint.y + t * dy
                if (0...1).contains(t), y >= bounds.minY, y <= bounds.maxY {
                    candidates.append((t, CGPoint(x: x, y: y)))
                }
            }
        }
        if dy != 0 {
            for y in [bounds.minY, bounds.maxY] {
                let t = (y - previousPoint.y) / dy
                let x = previousPoint.x + t * dx
                if (0...1).contains(t), x >= bounds.minX, x <= bounds.maxX {
                    candidates.append((t, CGPoint(x: x, y: y)))
                }
            }
        }
        return candidates.min { $0.t < $1.t }?.point
    }

    static func toolbarFrame(
        forVisualFrame visualFrame: CGRect,
        toolbarSize: CGSize,
        screenFrame: CGRect,
        gap: CGFloat,
        inset: CGFloat
    ) -> CGRect {
        OverlayToolbarGeometry.frames(
            anchorRect: visualFrame,
            containerBounds: screenFrame,
            mainSize: toolbarSize,
            gap: gap,
            inset: inset
        ).mainFrame
    }

    static func captureReturnAction(
        hasPendingAnnotationConfirmation: Bool,
        shiftHeld: Bool
    ) -> PinCaptureReturnAction {
        if shiftHeld {
            return .copyToClipboard
        }
        return hasPendingAnnotationConfirmation ? .confirmAnnotations : .pin
    }

    static func toolbarToggleAction(isVisible: Bool, isCompact: Bool) -> PinToolbarToggleAction {
        if isCompact { return .ignore }
        return isVisible ? .hide : .show
    }

    static func shouldRestoreToolbarAfterDrag(wasVisible: Bool, isCompact: Bool) -> Bool {
        wasVisible && !isCompact
    }

    static func shouldHideToolbarOnDeselect(wasVisible: Bool) -> Bool {
        false
    }

    static func toolbarConfirmAction(hasActiveAnnotationTool: Bool) -> PinToolbarConfirmAction {
        hasActiveAnnotationTool ? .confirmAnnotations : .hideToolbar
    }

    static func commandShortcutAction(keyCode: UInt16) -> PinCommandShortcutAction {
        switch keyCode {
        case 1:
            return .save
        case 8:
            return .copy
        case 12:
            return .close
        default:
            return .passThrough
        }
    }

    static func toolbarHideAction(reason: PinToolbarHideReason) -> PinToolbarHideAction {
        switch reason {
        case .userToggle, .explicitAction:
            return .hideAndCancelTool
        case .temporaryInteraction:
            return .hideOnly
        }
    }

    static func snappedVisualFrame(
        _ visual: CGRect,
        screenFrames: [CGRect],
        snapDistance: CGFloat
    ) -> CGRect {
        guard let screenFrame = screenFrames.first(where: { $0.intersects(visual) }) ?? screenFrames.first else {
            return visual
        }

        var result = visual
        if abs(result.minX - screenFrame.minX) <= snapDistance {
            result.origin.x = screenFrame.minX
        }
        if abs(result.maxX - screenFrame.maxX) <= snapDistance {
            result.origin.x = screenFrame.maxX - result.width
        }
        if abs(result.minY - screenFrame.minY) <= snapDistance {
            result.origin.y = screenFrame.minY
        }
        if abs(result.maxY - screenFrame.maxY) <= snapDistance {
            result.origin.y = screenFrame.maxY - result.height
        }

        return result
    }

    static func compactVisualFrame(
        around point: CGPoint,
        within visualFrame: CGRect,
        compactSize: CGSize
    ) -> CGRect {
        let width = max(1, compactSize.width)
        let height = max(1, compactSize.height)

        let x: CGFloat
        if visualFrame.width <= width {
            x = visualFrame.midX - width / 2
        } else {
            x = min(max(point.x - width / 2, visualFrame.minX), visualFrame.maxX - width)
        }

        let y: CGFloat
        if visualFrame.height <= height {
            y = visualFrame.midY - height / 2
        } else {
            y = min(max(point.y - height / 2, visualFrame.minY), visualFrame.maxY - height)
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func restoredVisualFrame(
        compactVisualFrame: CGRect,
        normalVisualSize: CGSize,
        compactActualCenter: CGPoint
    ) -> CGRect {
        CGRect(
            x: compactVisualFrame.midX - compactActualCenter.x * normalVisualSize.width,
            y: compactVisualFrame.midY - compactActualCenter.y * normalVisualSize.height,
            width: normalVisualSize.width,
            height: normalVisualSize.height
        )
    }
}

struct PinZoomSession {
    let anchorScreen: CGPoint
    let normalizedAnchor: CGPoint
}

struct PinShiftDoubleClickRecognizer {
    private var pendingTimestamp: TimeInterval?
    private var pendingPoint: CGPoint = .zero

    mutating func shouldToggle(
        timestamp: TimeInterval,
        point: CGPoint,
        clickCount: Int,
        isShift: Bool,
        doubleClickInterval: TimeInterval = 0.5,
        maxDistance: CGFloat = 8
    ) -> Bool {
        guard isShift else {
            pendingTimestamp = nil
            return false
        }

        if clickCount >= 2 {
            pendingTimestamp = nil
            return clickCount.isMultiple(of: 2)
        }

        if let previousTimestamp = pendingTimestamp {
            let dt = timestamp - previousTimestamp
            let dx = point.x - pendingPoint.x
            let dy = point.y - pendingPoint.y
            if dt >= 0 && dt <= doubleClickInterval && hypot(dx, dy) <= maxDistance {
                pendingTimestamp = nil
                return true
            }
        }

        pendingTimestamp = timestamp
        pendingPoint = point
        return false
    }
}
