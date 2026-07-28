import Foundation
import CoreGraphics

struct OCRTextParagraph: Equatable {
    let blocks: [RecognizedTextBlock]
    let text: String
    let normalizedBoundingBox: CGRect

    var recognizedBlock: RecognizedTextBlock {
        let confidence = blocks.isEmpty
            ? 0
            : blocks.map(\.confidence).reduce(0, +) / Float(blocks.count)
        return RecognizedTextBlock(
            text: text,
            normalizedBoundingBox: normalizedBoundingBox,
            confidence: confidence)
    }

    static func group(blocks: [RecognizedTextBlock]) -> [OCRTextParagraph] {
        let ordered = StructuredOCRResult(blocks: blocks).blocks
        var groups: [[RecognizedTextBlock]] = []

        for block in ordered {
            if let lastIndex = groups.indices.last,
               belongsToParagraph(block, after: groups[lastIndex]) {
                groups[lastIndex].append(block)
            } else {
                groups.append([block])
            }
        }

        return groups.map { paragraphBlocks in
            OCRTextParagraph(
                blocks: paragraphBlocks,
                text: StructuredOCRResult(blocks: paragraphBlocks).plainText,
                normalizedBoundingBox: paragraphBlocks
                    .map(\.normalizedBoundingBox)
                    .reduce(CGRect.null) { $0.union($1) })
        }
    }

    private static func belongsToParagraph(
        _ block: RecognizedTextBlock,
        after paragraph: [RecognizedTextBlock]
    ) -> Bool {
        guard let previous = paragraph.last else { return false }
        let currentRect = block.normalizedBoundingBox
        let previousRect = previous.normalizedBoundingBox
        let verticalGap = max(0, previousRect.minY - currentRect.maxY)
        let lineHeight = max(previousRect.height, currentRect.height)
        guard verticalGap <= max(0.04, lineHeight * 0.9) else { return false }

        let horizontalOverlap = max(
            0,
            min(previousRect.maxX, currentRect.maxX)
                - max(previousRect.minX, currentRect.minX))
        let smallerWidth = min(previousRect.width, currentRect.width)
        let overlapRatio = smallerWidth > 0 ? horizontalOverlap / smallerWidth : 0
        let leftAlignment = abs(previousRect.minX - currentRect.minX)
        let alignmentTolerance = max(0.08, min(previousRect.width, currentRect.width) * 0.3)
        return overlapRatio >= 0.2 || leftAlignment <= alignmentTolerance
    }
}
