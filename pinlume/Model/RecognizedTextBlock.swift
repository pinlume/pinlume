import Foundation
import CoreGraphics

struct OCRTextCharacterBox: Equatable, Codable {
    let utf16Range: NSRange
    let normalizedBoundingBox: CGRect

    private enum CodingKeys: String, CodingKey {
        case location, length, x, y, width, height
    }

    init(utf16Range: NSRange, normalizedBoundingBox: CGRect) {
        self.utf16Range = utf16Range
        self.normalizedBoundingBox = normalizedBoundingBox
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        utf16Range = NSRange(
            location: try values.decode(Int.self, forKey: .location),
            length: try values.decode(Int.self, forKey: .length))
        normalizedBoundingBox = CGRect(
            x: try values.decode(CGFloat.self, forKey: .x),
            y: try values.decode(CGFloat.self, forKey: .y),
            width: try values.decode(CGFloat.self, forKey: .width),
            height: try values.decode(CGFloat.self, forKey: .height))
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(utf16Range.location, forKey: .location)
        try values.encode(utf16Range.length, forKey: .length)
        try values.encode(normalizedBoundingBox.minX, forKey: .x)
        try values.encode(normalizedBoundingBox.minY, forKey: .y)
        try values.encode(normalizedBoundingBox.width, forKey: .width)
        try values.encode(normalizedBoundingBox.height, forKey: .height)
    }
}

struct RecognizedTextBlock: Equatable, Codable {
    let text: String
    let normalizedBoundingBox: CGRect
    let confidence: Float
    let characterBoxes: [OCRTextCharacterBox]

    var hasPositiveArea: Bool {
        normalizedBoundingBox.width > 0 && normalizedBoundingBox.height > 0
    }

    private enum CodingKeys: String, CodingKey {
        case text, x, y, width, height, confidence, characterBoxes
    }

    init(
        text: String, normalizedBoundingBox: CGRect, confidence: Float,
        characterBoxes: [OCRTextCharacterBox] = []
    ) {
        self.text = text
        self.normalizedBoundingBox = normalizedBoundingBox
        self.confidence = confidence
        self.characterBoxes = characterBoxes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        normalizedBoundingBox = CGRect(
            x: try container.decode(CGFloat.self, forKey: .x),
            y: try container.decode(CGFloat.self, forKey: .y),
            width: try container.decode(CGFloat.self, forKey: .width),
            height: try container.decode(CGFloat.self, forKey: .height))
        confidence = try container.decode(Float.self, forKey: .confidence)
        characterBoxes = try container.decodeIfPresent(
            [OCRTextCharacterBox].self, forKey: .characterBoxes) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(normalizedBoundingBox.origin.x, forKey: .x)
        try container.encode(normalizedBoundingBox.origin.y, forKey: .y)
        try container.encode(normalizedBoundingBox.size.width, forKey: .width)
        try container.encode(normalizedBoundingBox.size.height, forKey: .height)
        try container.encode(confidence, forKey: .confidence)
        if !characterBoxes.isEmpty {
            try container.encode(characterBoxes, forKey: .characterBoxes)
        }
    }

    static func == (lhs: RecognizedTextBlock, rhs: RecognizedTextBlock) -> Bool {
        lhs.text == rhs.text &&
            lhs.normalizedBoundingBox.origin.x == rhs.normalizedBoundingBox.origin.x &&
            lhs.normalizedBoundingBox.origin.y == rhs.normalizedBoundingBox.origin.y &&
            lhs.normalizedBoundingBox.size.width == rhs.normalizedBoundingBox.size.width &&
            lhs.normalizedBoundingBox.size.height == rhs.normalizedBoundingBox.size.height &&
            lhs.confidence == rhs.confidence &&
            lhs.characterBoxes == rhs.characterBoxes
    }
}

struct StructuredOCRResult: Equatable {
    let blocks: [RecognizedTextBlock]
    let plainText: String

    init(blocks: [RecognizedTextBlock]) {
        let cleanedBlocks = blocks.compactMap { block -> RecognizedTextBlock? in
            var start = block.text.startIndex
            var end = block.text.endIndex
            while start < end, block.text[start].isWhitespace {
                block.text.formIndex(after: &start)
            }
            while end > start {
                let previous = block.text.index(before: end)
                guard block.text[previous].isWhitespace else { break }
                end = previous
            }
            let text = String(block.text[start..<end])
            guard !text.isEmpty else { return nil }
            let trimmedRange = NSRange(
                location: block.text[..<start].utf16.count,
                length: text.utf16.count)
            let characterBoxes = block.characterBoxes.compactMap { character -> OCRTextCharacterBox? in
                let intersection = NSIntersectionRange(character.utf16Range, trimmedRange)
                guard intersection.length > 0 else { return nil }
                return OCRTextCharacterBox(
                    utf16Range: NSRange(
                        location: intersection.location - trimmedRange.location,
                        length: intersection.length),
                    normalizedBoundingBox: character.normalizedBoundingBox)
            }
            return RecognizedTextBlock(
                text: text,
                normalizedBoundingBox: block.normalizedBoundingBox,
                confidence: block.confidence,
                characterBoxes: characterBoxes)
        }

        let lines = Self.groupIntoVisualLines(cleanedBlocks)
        self.blocks = lines.flatMap { $0.sorted(by: Self.isLeftOf) }
        self.plainText = lines
            .map { $0.sorted(by: Self.isLeftOf).map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    private static func groupIntoVisualLines(_ blocks: [RecognizedTextBlock]) -> [[RecognizedTextBlock]] {
        var lines: [[RecognizedTextBlock]] = []
        let topToBottom = blocks.sorted {
            let lhsY = $0.normalizedBoundingBox.midY
            let rhsY = $1.normalizedBoundingBox.midY
            if lhsY != rhsY { return lhsY > rhsY }
            return isLeftOf($0, $1)
        }

        for block in topToBottom {
            if let index = lines.firstIndex(where: { belongsToSameVisualLine(block, $0) }) {
                lines[index].append(block)
            } else {
                lines.append([block])
            }
        }

        return lines.sorted { lhs, rhs in
            let lhsY = lhs.map { $0.normalizedBoundingBox.midY }.reduce(0, +) / CGFloat(lhs.count)
            let rhsY = rhs.map { $0.normalizedBoundingBox.midY }.reduce(0, +) / CGFloat(rhs.count)
            return lhsY > rhsY
        }
    }

    private static func belongsToSameVisualLine(
        _ block: RecognizedTextBlock,
        _ line: [RecognizedTextBlock]
    ) -> Bool {
        guard !block.text.contains("\n"), !line.contains(where: { $0.text.contains("\n") }) else {
            return false
        }

        return line.contains { existingBlock in
            let lhs = block.normalizedBoundingBox
            let rhs = existingBlock.normalizedBoundingBox
            let overlap = max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
            let smallerHeight = min(lhs.height, rhs.height)
            return smallerHeight > 0 && overlap / smallerHeight >= 0.5
        }
    }

    nonisolated private static func isLeftOf(
        _ lhs: RecognizedTextBlock,
        _ rhs: RecognizedTextBlock
    ) -> Bool {
        let lhsX = lhs.normalizedBoundingBox.minX
        let rhsX = rhs.normalizedBoundingBox.minX
        if lhsX != rhsX { return lhsX < rhsX }
        return lhs.normalizedBoundingBox.maxY > rhs.normalizedBoundingBox.maxY
    }
}
