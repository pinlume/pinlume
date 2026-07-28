import Cocoa

enum OverlayToolbarGeometry {
    enum Placement: Equatable {
        case below
        case above
        case inside
    }

    struct Frames {
        let placement: Placement
        let mainFrame: CGRect
        let moreFrame: CGRect?
        let optionsFrame: CGRect?

        var stackFrame: CGRect {
            [mainFrame, moreFrame, optionsFrame]
                .compactMap { $0 }
                .reduce(CGRect.null) { $0.union($1) }
        }
    }

    static func frames(
        anchorRect: CGRect,
        containerBounds bounds: CGRect,
        mainSize: CGSize,
        moreSize: CGSize? = nil,
        optionsSize: CGSize? = nil,
        reservedOptionsSize: CGSize? = nil,
        gap: CGFloat = 6,
        rowGap: CGFloat = 2,
        inset: CGFloat = 4
    ) -> Frames {
        let measuredOptionsSize = optionsSize ?? reservedOptionsSize
        let totalHeight = mainSize.height
            + (moreSize.map { rowGap + $0.height } ?? 0)
            + (measuredOptionsSize.map { rowGap + $0.height } ?? 0)
        let belowFits = anchorRect.minY - gap - totalHeight >= bounds.minY + inset
        let aboveFits = anchorRect.maxY + gap + totalHeight <= bounds.maxY - inset

        if belowFits {
            return stackedFrames(
                placement: .below,
                anchorRight: anchorRect.maxX,
                startY: anchorRect.minY - gap - mainSize.height,
                direction: -1,
                bounds: bounds,
                mainSize: mainSize,
                moreSize: moreSize,
                optionsSize: optionsSize,
                rowGap: rowGap,
                inset: inset
            )
        }

        if aboveFits {
            return stackedFrames(
                placement: .above,
                anchorRight: anchorRect.maxX,
                startY: anchorRect.maxY + gap,
                direction: 1,
                bounds: bounds,
                mainSize: mainSize,
                moreSize: moreSize,
                optionsSize: optionsSize,
                rowGap: rowGap,
                inset: inset
            )
        }

        let startY = max(bounds.minY + inset, min(anchorRect.minY + inset, bounds.maxY - totalHeight - inset))
        return stackedFrames(
            placement: .inside,
            anchorRight: anchorRect.maxX,
            startY: startY,
            direction: 1,
            bounds: bounds,
            mainSize: mainSize,
            moreSize: moreSize,
            optionsSize: optionsSize,
            rowGap: rowGap,
            inset: inset
        )
    }

    static func tooltipFrame(
        buttonFrame: CGRect,
        stackFrame: CGRect,
        tooltipSize: CGSize,
        containerBounds bounds: CGRect,
        gap: CGFloat = 4,
        inset: CGFloat = 2
    ) -> CGRect {
        let preferredX = buttonFrame.midX - tooltipSize.width / 2
        let x = max(bounds.minX + inset, min(preferredX, bounds.maxX - tooltipSize.width - inset))
        let aboveY = stackFrame.maxY + gap
        let y: CGFloat
        if aboveY + tooltipSize.height <= bounds.maxY - inset {
            y = aboveY
        } else {
            y = max(bounds.minY + inset, stackFrame.minY - tooltipSize.height - gap)
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: tooltipSize)
    }

    private static func stackedFrames(
        placement: Placement,
        anchorRight: CGFloat,
        startY: CGFloat,
        direction: CGFloat,
        bounds: CGRect,
        mainSize: CGSize,
        moreSize: CGSize?,
        optionsSize: CGSize?,
        rowGap: CGFloat,
        inset: CGFloat
    ) -> Frames {
        let main = CGRect(
            origin: CGPoint(x: clampedX(anchorRight: anchorRight, width: mainSize.width, bounds: bounds, inset: inset), y: startY),
            size: mainSize
        )
        var nextY = direction > 0 ? main.maxY + rowGap : main.minY - rowGap

        let more: CGRect?
        if let moreSize {
            let y = direction > 0 ? nextY : nextY - moreSize.height
            more = CGRect(
                origin: CGPoint(x: clampedX(anchorRight: anchorRight, width: moreSize.width, bounds: bounds, inset: inset), y: y),
                size: moreSize
            )
            nextY = direction > 0 ? more!.maxY + rowGap : more!.minY - rowGap
        } else {
            more = nil
        }

        let options: CGRect?
        if let optionsSize {
            let y = direction > 0 ? nextY : nextY - optionsSize.height
            options = CGRect(
                origin: CGPoint(x: clampedX(anchorRight: anchorRight, width: optionsSize.width, bounds: bounds, inset: inset), y: y),
                size: optionsSize
            )
        } else {
            options = nil
        }

        return Frames(placement: placement, mainFrame: main, moreFrame: more, optionsFrame: options)
    }

    private static func clampedX(anchorRight: CGFloat, width: CGFloat, bounds: CGRect, inset: CGFloat) -> CGFloat {
        max(bounds.minX + inset, min(anchorRight - width, bounds.maxX - width - inset))
    }
}
