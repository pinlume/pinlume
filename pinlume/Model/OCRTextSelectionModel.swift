import AppKit
import CoreText

struct OCRTextSelectionModel {
    private struct Position: Comparable, Equatable {
        let blockIndex: Int
        let utf16Offset: Int

        static func < (lhs: Position, rhs: Position) -> Bool {
            lhs.blockIndex == rhs.blockIndex
                ? lhs.utf16Offset < rhs.utf16Offset
                : lhs.blockIndex < rhs.blockIndex
        }
    }

    private var blocks: [RecognizedTextBlock] = []
    private var anchor: Position?
    private var active: Position?
    private(set) var textRects: [NSRect] = []
    private var characterRects: [[(range: NSRange, rect: NSRect)]] = []

    var hasSelection: Bool {
        guard let anchor, let active else { return false }
        return anchor != active
    }

    var fullText: String {
        guard !blocks.isEmpty else { return "" }
        var output = blocks[0].text
        for index in 1..<blocks.count {
            output += separator(between: blocks[index - 1], and: blocks[index])
            output += blocks[index].text
        }
        return output
    }

    var selectedText: String {
        guard let range = orderedSelection else { return "" }
        var output = ""
        for index in range.lower.blockIndex...range.upper.blockIndex {
            let text = blocks[index].text as NSString
            let start = index == range.lower.blockIndex ? range.lower.utf16Offset : 0
            let end = index == range.upper.blockIndex ? range.upper.utf16Offset : text.length
            guard end > start else { continue }
            if !output.isEmpty, index > range.lower.blockIndex {
                output += separator(between: blocks[index - 1], and: blocks[index])
            }
            output += text.substring(with: NSRange(location: start, length: end - start))
        }
        return output
    }

    var selectionRects: [NSRect] {
        guard let range = orderedSelection else { return [] }
        var rects: [NSRect] = []
        for index in range.lower.blockIndex...range.upper.blockIndex {
            let length = (blocks[index].text as NSString).length
            let start = index == range.lower.blockIndex ? range.lower.utf16Offset : 0
            let end = index == range.upper.blockIndex ? range.upper.utf16Offset : length
            guard end > start else { continue }
            let selectedRange = NSRange(location: start, length: end - start)
            let preciseRects = characterRects[index]
                .filter { NSIntersectionRange($0.range, selectedRange).length > 0 }
                .map(\.rect)
            if let first = preciseRects.first {
                rects.append(preciseRects.dropFirst().reduce(first) { $0.union($1) })
            } else {
                let rect = textRects[index]
                let minX = rect.minX + horizontalOffset(for: start, in: blocks[index].text, width: rect.width)
                let maxX = rect.minX + horizontalOffset(for: end, in: blocks[index].text, width: rect.width)
                rects.append(NSRect(
                    x: min(minX, maxX),
                    y: rect.minY,
                    width: max(1, abs(maxX - minX)),
                    height: rect.height
                ).intersection(rect))
            }
        }
        return rects.filter { !$0.isEmpty }
    }

    mutating func configure(blocks: [RecognizedTextBlock], imageRect: NSRect) {
        let ordered = StructuredOCRResult(blocks: blocks).blocks.filter(\.hasPositiveArea)
        self.blocks = ordered
        self.textRects = ordered.map { block in
            let box = block.normalizedBoundingBox
            return NSRect(
                x: imageRect.minX + box.minX * imageRect.width,
                y: imageRect.minY + box.minY * imageRect.height,
                width: box.width * imageRect.width,
                height: box.height * imageRect.height
            )
        }
        self.characterRects = ordered.map { block in
            let mapped = block.characterBoxes.compactMap { character -> (range: NSRange, rect: NSRect)? in
                let box = character.normalizedBoundingBox
                guard box.width > 0, box.height > 0,
                      box.minX.isFinite, box.minY.isFinite,
                      box.width.isFinite, box.height.isFinite,
                      block.normalizedBoundingBox.insetBy(dx: -0.02, dy: -0.02)
                        .intersects(box)
                else { return nil }
                return (
                    range: character.utf16Range,
                    rect: NSRect(
                        x: imageRect.minX + box.minX * imageRect.width,
                        y: imageRect.minY + box.minY * imageRect.height,
                        width: box.width * imageRect.width,
                        height: box.height * imageRect.height))
            }
            return hasUsableCharacterGeometry(mapped, text: block.text) ? mapped : []
        }
        clearSelection()
    }

    func containsText(at point: NSPoint) -> Bool {
        textRects.contains { $0.contains(point) }
    }

    mutating func beginSelection(at point: NSPoint) -> Bool {
        guard let position = position(at: point, nearest: false) else { return false }
        anchor = position
        active = position
        return true
    }

    mutating func extendSelection(to point: NSPoint) {
        guard anchor != nil, let position = position(at: point, nearest: true) else { return }
        active = position
    }

    mutating func selectAll() {
        guard let last = blocks.indices.last else { return }
        anchor = Position(blockIndex: 0, utf16Offset: 0)
        active = Position(blockIndex: last, utf16Offset: (blocks[last].text as NSString).length)
    }

    mutating func clearSelection() {
        anchor = nil
        active = nil
    }

    private var orderedSelection: (lower: Position, upper: Position)? {
        guard hasSelection, let anchor, let active else { return nil }
        return anchor < active ? (anchor, active) : (active, anchor)
    }

    private func position(at point: NSPoint, nearest: Bool) -> Position? {
        let blockIndex: Int?
        if let exact = textRects.firstIndex(where: { $0.contains(point) }) {
            blockIndex = exact
        } else if nearest {
            blockIndex = textRects.indices.min { lhs, rhs in
                squaredDistance(from: point, to: textRects[lhs])
                    < squaredDistance(from: point, to: textRects[rhs])
            }
        } else {
            blockIndex = nil
        }
        guard let index = blockIndex else { return nil }
        let rect = textRects[index]
        if let precise = precisePosition(at: point, blockIndex: index) {
            return precise
        }
        let fraction = rect.width > 0 ? min(1, max(0, (point.x - rect.minX) / rect.width)) : 0
        return Position(
            blockIndex: index,
            utf16Offset: stringOffset(forHorizontalFraction: fraction, in: blocks[index].text)
        )
    }

    private func precisePosition(at point: NSPoint, blockIndex: Int) -> Position? {
        let glyphs = characterRects[blockIndex]
        guard !glyphs.isEmpty else { return nil }
        let containingGlyphs = glyphs.filter { $0.rect.contains(point) }
        let glyph = containingGlyphs.min(by: {
                abs($0.rect.midX - point.x) < abs($1.rect.midX - point.x)
            }) ?? glyphs.min(by: {
                squaredDistance(from: point, to: $0.rect)
                    < squaredDistance(from: point, to: $1.rect)
            })
        guard let glyph else { return nil }
        let offset = point.x < glyph.rect.midX
            ? glyph.range.location : NSMaxRange(glyph.range)
        return Position(blockIndex: blockIndex, utf16Offset: offset)
    }

    /// Vision can return boxes for only the first character of a word or line.
    /// Treating such a partial set as precise makes every later click snap back
    /// to that first box. Use it only when every visible UTF-16 unit is covered;
    /// whitespace intentionally has no required box.
    private func hasUsableCharacterGeometry(
        _ boxes: [(range: NSRange, rect: NSRect)],
        text: String
    ) -> Bool {
        guard !boxes.isEmpty else { return false }
        for (offset, unit) in text.utf16.enumerated() {
            if let scalar = UnicodeScalar(unit),
               CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            guard boxes.contains(where: { NSLocationInRange(offset, $0.range) }) else {
                return false
            }
        }

        let visibleBoxes = boxes
            .filter { entry in
                let substring = (text as NSString).substring(with: entry.range)
                return !substring.unicodeScalars.allSatisfy {
                    CharacterSet.whitespacesAndNewlines.contains($0)
                }
            }
            .sorted { lhs, rhs in lhs.range.location < rhs.range.location }
        for (previous, current) in zip(visibleBoxes, visibleBoxes.dropFirst()) {
            guard current.rect.midX > previous.rect.midX else {
                return false
            }
        }
        return true
    }

    private func stringOffset(forHorizontalFraction fraction: CGFloat, in text: String) -> Int {
        let line = makeLine(text)
        let width = max(1, typographicWidth(of: line))
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: fraction * width, y: 0))
        let length = (text as NSString).length
        return index == kCFNotFound ? (fraction < 0.5 ? 0 : length) : min(length, max(0, index))
    }

    private func horizontalOffset(for utf16Offset: Int, in text: String, width: CGFloat) -> CGFloat {
        let line = makeLine(text)
        let lineWidth = typographicWidth(of: line)
        let length = (text as NSString).length
        guard lineWidth > 0, length > 0 else {
            return width * CGFloat(utf16Offset) / CGFloat(max(1, length))
        }
        let offset = CTLineGetOffsetForStringIndex(line, min(length, max(0, utf16Offset)), nil)
        return min(width, max(0, offset / lineWidth * width))
    }

    private func makeLine(_ text: String) -> CTLine {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 12)
        ])
        return CTLineCreateWithAttributedString(attributed)
    }

    private func typographicWidth(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    private func separator(between lhs: RecognizedTextBlock, and rhs: RecognizedTextBlock) -> String {
        let left = lhs.normalizedBoundingBox
        let right = rhs.normalizedBoundingBox
        let overlap = max(0, min(left.maxY, right.maxY) - max(left.minY, right.minY))
        let smallerHeight = min(left.height, right.height)
        return smallerHeight > 0 && overlap / smallerHeight >= 0.5 ? " " : "\n"
    }

    private func squaredDistance(from point: NSPoint, to rect: NSRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}
