import AppKit
import CoreText

enum TranslatedImageRenderer {
    static func render(
        image: NSImage,
        blocks: [TranslatedTextBlock],
        completion: @escaping (NSImage, [RecognizedTextBlock]) -> Void
    ) {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            completion(image, [])
            return
        }
        let logicalSize = image.size
        DispatchQueue.global(qos: .userInitiated).async {
            let width = source.width, height = source.height
            guard let context = CGContext(data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                DispatchQueue.main.async { completion(image, []) }; return
            }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            var selectionBlocks: [RecognizedTextBlock] = []
            for item in blocks {
                let box = item.block.normalizedBoundingBox
                let drawRect = CGRect(x: box.minX * CGFloat(width), y: box.minY * CGFloat(height),
                    width: box.width * CGFloat(width), height: box.height * CGFloat(height))
                let sampleRect = ScreenTranslationGeometry.samplePixelRect(normalizedBox: box, pixelSize: CGSize(width: width, height: height))
                context.setFillColor(sampleAverageColor(in: source, region: sampleRect, alpha: 0.94))
                context.fill(drawRect)
                let text = item.translatedText.isEmpty ? item.block.text : item.translatedText
                let textRect = drawRect.insetBy(dx: min(6, drawRect.width * 0.03),
                                                dy: min(4, drawRect.height * 0.05))
                let textColor = preferredTextColor(
                    for: sampleAverageColor(in: source, region: sampleRect, alpha: 1))
                let fontSize = fittingFontSize(for: text, in: textRect)
                let attributed = attributedString(text, fontSize: fontSize, color: textColor)
                let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attributed),
                    CFRange(location: 0, length: attributed.length), CGPath(rect: textRect, transform: nil), nil)
                CTFrameDraw(frame, context)
                selectionBlocks.append(contentsOf: translatedSelectionBlocks(
                    text: text,
                    frame: frame,
                    confidence: item.block.confidence,
                    pixelSize: CGSize(width: width, height: height)))
            }
            guard let output = context.makeImage() else {
                DispatchQueue.main.async { completion(image, []) }
                return
            }
            DispatchQueue.main.async {
                completion(
                    NSImage(cgImage: output, size: logicalSize),
                    StructuredOCRResult(blocks: selectionBlocks).blocks)
            }
        }
    }

    private static func translatedSelectionBlocks(
        text: String,
        frame: CTFrame,
        confidence: Float,
        pixelSize: CGSize
    ) -> [RecognizedTextBlock] {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty, pixelSize.width > 0, pixelSize.height > 0 else { return [] }
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let source = text as NSString

        return zip(lines, origins).compactMap { line, origin in
            let lineRange = CTLineGetStringRange(line)
            guard lineRange.location != kCFNotFound, lineRange.length > 0 else { return nil }
            var contentLength = lineRange.length
            while contentLength > 0 {
                let codeUnit = source.character(at: lineRange.location + contentLength - 1)
                if codeUnit == 10 || codeUnit == 13 { contentLength -= 1 } else { break }
            }
            guard contentLength > 0 else { return nil }
            let contentRange = NSRange(location: lineRange.location, length: contentLength)
            let lineText = source.substring(with: contentRange)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let typographicWidth = CGFloat(CTLineGetTypographicBounds(
                line, &ascent, &descent, &leading))
            let lineRect = CGRect(
                x: origin.x,
                y: origin.y - descent,
                width: max(1, typographicWidth),
                height: max(1, ascent + descent + leading))
            let normalized = CGRect(
                x: lineRect.minX / pixelSize.width,
                y: lineRect.minY / pixelSize.height,
                width: lineRect.width / pixelSize.width,
                height: lineRect.height / pixelSize.height)

            var characterBoxes: [OCRTextCharacterBox] = []
            var globalOffset = contentRange.location
            while globalOffset < NSMaxRange(contentRange) {
                let composed = source.rangeOfComposedCharacterSequence(at: globalOffset)
                let clipped = NSIntersectionRange(composed, contentRange)
                guard clipped.length > 0 else { break }
                let start = CTLineGetOffsetForStringIndex(line, clipped.location, nil)
                let end = CTLineGetOffsetForStringIndex(line, NSMaxRange(clipped), nil)
                let characterRect = CGRect(
                    x: origin.x + min(start, end),
                    y: lineRect.minY,
                    width: max(1, abs(end - start)),
                    height: lineRect.height)
                characterBoxes.append(OCRTextCharacterBox(
                    utf16Range: NSRange(
                        location: clipped.location - contentRange.location,
                        length: clipped.length),
                    normalizedBoundingBox: CGRect(
                        x: characterRect.minX / pixelSize.width,
                        y: characterRect.minY / pixelSize.height,
                        width: characterRect.width / pixelSize.width,
                        height: characterRect.height / pixelSize.height)))
                globalOffset = NSMaxRange(clipped)
            }
            return RecognizedTextBlock(
                text: lineText,
                normalizedBoundingBox: normalized,
                confidence: confidence,
                characterBoxes: characterBoxes)
        }
    }

    private static func fittingFontSize(for text: String, in rect: CGRect) -> CGFloat {
        guard !text.isEmpty, rect.width > 1, rect.height > 1 else { return 7 }
        var lower: CGFloat = 7
        var upper: CGFloat = min(34, max(7, rect.height * 0.65))
        for _ in 0..<9 {
            let candidate = (lower + upper) / 2
            let attributed = attributedString(
                text, fontSize: candidate, color: CGColor(gray: 0, alpha: 1))
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: attributed.length),
                nil,
                CGSize(width: rect.width, height: .greatestFiniteMagnitude),
                nil)
            if suggested.height <= rect.height + 0.5 {
                lower = candidate
            } else {
                upper = candidate
            }
        }
        return floor(lower * 2) / 2
    }

    private static func attributedString(
        _ text: String,
        fontSize: CGFloat,
        color: CGColor
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = max(0, fontSize * 0.08)
        return NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String):
                CTFontCreateWithName("Helvetica" as CFString, fontSize, nil),
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): color,
            .paragraphStyle: paragraph,
        ])
    }

    private static func preferredTextColor(for background: CGColor) -> CGColor {
        let components = background.components ?? [1, 1, 1, 1]
        let red = components[0]
        let green = components.count > 2 ? components[1] : components[0]
        let blue = components.count > 2 ? components[2] : components[0]
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return CGColor(gray: luminance < 0.55 ? 0.96 : 0.08, alpha: 1)
    }

    private static func sampleAverageColor(
        in image: CGImage, region: CGRect, alpha: CGFloat
    ) -> CGColor {
        let x = max(0, min(Int(region.minX), image.width - 1))
        let y = max(0, min(Int(region.minY), image.height - 1))
        let width = min(max(1, Int(region.width)), image.width - x)
        let height = min(max(1, Int(region.height)), image.height - y)
        guard width > 0, height > 0,
              let cropped = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return CGColor(gray: 0.95, alpha: alpha) }

        let sampleWidth = 4, sampleHeight = 4
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        guard let context = CGContext(
            data: &pixels, width: sampleWidth, height: sampleHeight,
            bitsPerComponent: 8, bytesPerRow: sampleWidth * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return CGColor(gray: 0.95, alpha: alpha) }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
        let count = CGFloat(sampleWidth * sampleHeight)
        for index in 0..<(sampleWidth * sampleHeight) {
            let offset = index * 4
            red += CGFloat(pixels[offset]) / 255
            green += CGFloat(pixels[offset + 1]) / 255
            blue += CGFloat(pixels[offset + 2]) / 255
        }
        return CGColor(
            colorSpace: colorSpace,
            components: [red / count, green / count, blue / count, alpha])
            ?? CGColor(gray: 0.95, alpha: alpha)
    }
}
