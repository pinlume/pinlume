import Cocoa

// MARK: - Codable conformance for Annotation

/// Intermediate Codable representation of an Annotation.
/// Uses simple types (Data, [CGFloat], etc.) to avoid custom NSColor/NSImage coding.
struct CodableAnnotation: Codable {
    // Core
    let tool: Int  // AnnotationTool.rawValue
    let startX: CGFloat
    let startY: CGFloat
    let endX: CGFloat
    let endY: CGFloat
    let colorRGBA: [CGFloat]  // [r, g, b, a]
    let strokeWidth: CGFloat

    // Text
    var text: String?
    var attributedTextRTF: Data?  // RTF encoding of NSAttributedString
    var fontSize: CGFloat = 20
    var isBold: Bool = false
    var isItalic: Bool = false
    var isUnderline: Bool = false
    var isStrikethrough: Bool = false
    var textDrawRect: [CGFloat]?  // [x, y, w, h]
    var textBgColorRGBA: [CGFloat]?
    var textOutlineColorRGBA: [CGFloat]?
    var textGlyphStrokeColorRGBA: [CGFloat]?
    var textAlignment: Int = 0  // NSTextAlignment.rawValue
    var fontFamilyName: String?
    var textImagePNG: Data?

    // Number
    var number: Int?
    var numberFormat: Int = 0

    // Points (pencil/marker freeform paths)
    var points: [[CGFloat]]?  // [[x, y], ...]
    var pressures: [CGFloat]?  // per-point pressure (parallel to points)

    // Line/arrow bend points
    var controlPointXY: [CGFloat]?  // [x, y]
    var anchorPoints: [[CGFloat]]?  // [[x, y], ...]

    // Shape style
    var rotation: CGFloat = 0
    var rectCornerRadius: CGFloat = 0
    var lineStyle: Int = 0
    var arrowStyle: Int = 0
    var arrowReversed: Bool = false
    var rectFillStyle: Int = 0
    var outlineColorRGBA: [CGFloat]?

    // Stamp
    var stampImagePNG: Data?

    // Censor (pixelate/blur) baked result
    var bakedBlurPNG: Data?

    // Loupe
    var loupeMagnification: CGFloat?
    var loupeSourceRect: [CGFloat]?      // [x, y, w, h] for the rooted source circle
    var loupeOutlineEnabled: Bool = false

    // Misc
    var measureInPoints: Bool = false
    var censorMode: Int = 0
    var censorShape: Int?
    var censorStrength: CGFloat?
    var groupID: String?  // UUID string
    var randomSeed: UInt32 = 0  // 0 = legacy capture, regenerate at decode
    var dimOpacity: CGFloat = 0.55  // highlight (spotlight) dim strength
}

extension CodableAnnotation {
    private enum CodingKeys: String, CodingKey {
        case tool, startX, startY, endX, endY, colorRGBA, strokeWidth
        case text, attributedTextRTF, fontSize, isBold, isItalic, isUnderline, isStrikethrough
        case textDrawRect, textBgColorRGBA, textOutlineColorRGBA, textGlyphStrokeColorRGBA, textAlignment, fontFamilyName, textImagePNG
        case number, numberFormat, points, pressures, controlPointXY, anchorPoints
        case rotation, rectCornerRadius, lineStyle, arrowStyle, arrowReversed, rectFillStyle, outlineColorRGBA
        case stampImagePNG, bakedBlurPNG, loupeMagnification, loupeSourceRect, loupeOutlineEnabled
        case measureInPoints, censorMode, censorShape, censorStrength, groupID, randomSeed, dimOpacity
    }

    /// Core geometry/tool fields are deliberately strict: without them an
    /// annotation cannot be positioned safely. Every later presentation field
    /// is optional for compatibility with pre-feature history JSON.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tool = try c.decode(Int.self, forKey: .tool)
        startX = try c.decode(CGFloat.self, forKey: .startX)
        startY = try c.decode(CGFloat.self, forKey: .startY)
        endX = try c.decode(CGFloat.self, forKey: .endX)
        endY = try c.decode(CGFloat.self, forKey: .endY)
        colorRGBA = try c.decode([CGFloat].self, forKey: .colorRGBA)
        strokeWidth = try c.decode(CGFloat.self, forKey: .strokeWidth)

        text = try c.decodeIfPresent(String.self, forKey: .text)
        attributedTextRTF = try c.decodeIfPresent(Data.self, forKey: .attributedTextRTF)
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 20
        isBold = try c.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
        isItalic = try c.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
        isUnderline = try c.decodeIfPresent(Bool.self, forKey: .isUnderline) ?? false
        isStrikethrough = try c.decodeIfPresent(Bool.self, forKey: .isStrikethrough) ?? false
        textDrawRect = try c.decodeIfPresent([CGFloat].self, forKey: .textDrawRect)
        textBgColorRGBA = try c.decodeIfPresent([CGFloat].self, forKey: .textBgColorRGBA)
        textOutlineColorRGBA = try c.decodeIfPresent([CGFloat].self, forKey: .textOutlineColorRGBA)
        textGlyphStrokeColorRGBA = try c.decodeIfPresent([CGFloat].self, forKey: .textGlyphStrokeColorRGBA)
        textAlignment = try c.decodeIfPresent(Int.self, forKey: .textAlignment) ?? 0
        fontFamilyName = try c.decodeIfPresent(String.self, forKey: .fontFamilyName)
        textImagePNG = try c.decodeIfPresent(Data.self, forKey: .textImagePNG)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        numberFormat = try c.decodeIfPresent(Int.self, forKey: .numberFormat) ?? 0
        points = try c.decodeIfPresent([[CGFloat]].self, forKey: .points)
        pressures = try c.decodeIfPresent([CGFloat].self, forKey: .pressures)
        controlPointXY = try c.decodeIfPresent([CGFloat].self, forKey: .controlPointXY)
        anchorPoints = try c.decodeIfPresent([[CGFloat]].self, forKey: .anchorPoints)
        rotation = try c.decodeIfPresent(CGFloat.self, forKey: .rotation) ?? 0
        rectCornerRadius = try c.decodeIfPresent(CGFloat.self, forKey: .rectCornerRadius) ?? 0
        lineStyle = try c.decodeIfPresent(Int.self, forKey: .lineStyle) ?? 0
        arrowStyle = try c.decodeIfPresent(Int.self, forKey: .arrowStyle) ?? 0
        arrowReversed = try c.decodeIfPresent(Bool.self, forKey: .arrowReversed) ?? false
        rectFillStyle = try c.decodeIfPresent(Int.self, forKey: .rectFillStyle) ?? 0
        outlineColorRGBA = try c.decodeIfPresent([CGFloat].self, forKey: .outlineColorRGBA)
        stampImagePNG = try c.decodeIfPresent(Data.self, forKey: .stampImagePNG)
        bakedBlurPNG = try c.decodeIfPresent(Data.self, forKey: .bakedBlurPNG)
        loupeMagnification = try c.decodeIfPresent(CGFloat.self, forKey: .loupeMagnification)
        loupeSourceRect = try c.decodeIfPresent([CGFloat].self, forKey: .loupeSourceRect)
        loupeOutlineEnabled = try c.decodeIfPresent(Bool.self, forKey: .loupeOutlineEnabled) ?? false
        measureInPoints = try c.decodeIfPresent(Bool.self, forKey: .measureInPoints) ?? false
        censorMode = try c.decodeIfPresent(Int.self, forKey: .censorMode) ?? 0
        censorShape = try c.decodeIfPresent(Int.self, forKey: .censorShape)
        censorStrength = try c.decodeIfPresent(CGFloat.self, forKey: .censorStrength)
        groupID = try c.decodeIfPresent(String.self, forKey: .groupID)
        randomSeed = try c.decodeIfPresent(UInt32.self, forKey: .randomSeed) ?? 0
        dimOpacity = try c.decodeIfPresent(CGFloat.self, forKey: .dimOpacity) ?? 0.55
    }
}

extension Annotation {

    func toCodable() -> CodableAnnotation {
        var c = CodableAnnotation(
            tool: tool.rawValue,
            startX: startPoint.x,
            startY: startPoint.y,
            endX: endPoint.x,
            endY: endPoint.y,
            colorRGBA: Self.encodeColor(color),
            strokeWidth: strokeWidth
        )

        // Text
        c.text = text
        if let attrText = attributedText {
            c.attributedTextRTF = try? attrText.data(
                from: NSRange(location: 0, length: attrText.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }
        c.fontSize = fontSize
        c.isBold = isBold
        c.isItalic = isItalic
        c.isUnderline = isUnderline
        c.isStrikethrough = isStrikethrough
        if textDrawRect != .zero {
            c.textDrawRect = [textDrawRect.origin.x, textDrawRect.origin.y, textDrawRect.width, textDrawRect.height]
        }
        if let bg = textBgColor { c.textBgColorRGBA = Self.encodeColor(bg) }
        if let outline = textOutlineColor { c.textOutlineColorRGBA = Self.encodeColor(outline) }
        if let glyph = textGlyphStrokeColor { c.textGlyphStrokeColorRGBA = Self.encodeColor(glyph) }
        c.textAlignment = textAlignment.rawValue
        c.fontFamilyName = fontFamilyName
        if let img = textImage { c.textImagePNG = Self.encodeImage(img) }

        // Number
        c.number = number
        c.numberFormat = numberFormat.rawValue

        // Points
        if let pts = points {
            c.points = pts.map { [$0.x, $0.y] }
        }
        c.pressures = pressures

        // Control/anchor points
        if let cp = controlPoint { c.controlPointXY = [cp.x, cp.y] }
        if let anchors = anchorPoints {
            c.anchorPoints = anchors.map { [$0.x, $0.y] }
        }

        // Shape style
        c.rotation = rotation
        c.rectCornerRadius = rectCornerRadius
        c.lineStyle = lineStyle.rawValue
        c.arrowStyle = arrowStyle.rawValue
        c.arrowReversed = arrowReversed
        c.rectFillStyle = rectFillStyle.rawValue
        if let oc = outlineColor { c.outlineColorRGBA = Self.encodeColor(oc) }

        // Stamp
        if let stamp = stampImage { c.stampImagePNG = Self.encodeImage(stamp) }

        // Baked censor result (pixelate/blur/erase) — skip loupe since it
        // needs re-baking from the editor's source image at the correct coordinates.
        if tool != .loupe, let baked = bakedBlurNSImage { c.bakedBlurPNG = Self.encodeImage(baked) }

        // Loupe
        c.loupeMagnification = loupeMagnification
        if let r = loupeSourceRect {
            c.loupeSourceRect = [r.origin.x, r.origin.y, r.size.width, r.size.height]
        }
        c.loupeOutlineEnabled = loupeOutlineEnabled

        // Misc
        c.measureInPoints = measureInPoints
        c.censorMode = censorMode.rawValue
        c.censorShape = censorShape.rawValue
        c.censorStrength = censorStrength
        if let gid = groupID { c.groupID = gid.uuidString }
        c.randomSeed = randomSeed
        c.dimOpacity = dimOpacity

        return c
    }

    static func fromCodable(_ c: CodableAnnotation) -> Annotation? {
        guard let tool = AnnotationTool(rawValue: c.tool) else { return nil }
        let ann = Annotation(
            tool: tool,
            startPoint: NSPoint(x: c.startX, y: c.startY),
            endPoint: NSPoint(x: c.endX, y: c.endY),
            color: decodeColor(c.colorRGBA),
            strokeWidth: c.strokeWidth
        )

        // Text
        ann.text = c.text
        if let rtfData = c.attributedTextRTF {
            ann.attributedText = NSAttributedString(rtf: rtfData, documentAttributes: nil)
        }
        ann.fontSize = c.fontSize
        ann.isBold = c.isBold
        ann.isItalic = c.isItalic
        ann.isUnderline = c.isUnderline
        ann.isStrikethrough = c.isStrikethrough
        if let r = c.textDrawRect, r.count == 4 {
            ann.textDrawRect = NSRect(x: r[0], y: r[1], width: r[2], height: r[3])
        }
        if let rgba = c.textBgColorRGBA { ann.textBgColor = decodeColor(rgba) }
        if let rgba = c.textOutlineColorRGBA { ann.textOutlineColor = decodeColor(rgba) }
        if let rgba = c.textGlyphStrokeColorRGBA { ann.textGlyphStrokeColor = decodeColor(rgba) }
        ann.textAlignment = NSTextAlignment(rawValue: c.textAlignment) ?? .left
        ann.fontFamilyName = c.fontFamilyName
        if let data = c.textImagePNG { ann.textImage = NSImage(data: data) }

        // Number
        ann.number = c.number
        ann.numberFormat = NumberFormat(rawValue: c.numberFormat) ?? .decimal

        // Points
        if let pts = c.points {
            ann.points = pts.compactMap { p in
                guard p.count == 2 else { return nil }
                return NSPoint(x: p[0], y: p[1])
            }
        }
        ann.pressures = c.pressures

        // Control/anchor points
        if let cp = c.controlPointXY, cp.count == 2 {
            ann.controlPoint = NSPoint(x: cp[0], y: cp[1])
        }
        if let anchors = c.anchorPoints {
            ann.anchorPoints = anchors.compactMap { p in
                guard p.count == 2 else { return nil }
                return NSPoint(x: p[0], y: p[1])
            }
        }

        // Shape style
        ann.rotation = c.rotation
        ann.rectCornerRadius = c.rectCornerRadius
        ann.lineStyle = LineStyle(rawValue: c.lineStyle) ?? .solid
        ann.arrowStyle = ArrowStyle(rawValue: c.arrowStyle) ?? .single
        ann.arrowReversed = c.arrowReversed
        ann.rectFillStyle = RectFillStyle(rawValue: c.rectFillStyle) ?? .stroke
        if let rgba = c.outlineColorRGBA { ann.outlineColor = decodeColor(rgba) }

        // Stamp
        if let data = c.stampImagePNG { ann.stampImage = NSImage(data: data) }

        // Baked censor result
        if let data = c.bakedBlurPNG { ann.bakedBlurNSImage = NSImage(data: data) }

        // Loupe
        ann.loupeMagnification = c.loupeMagnification ?? 2.0
        if let r = c.loupeSourceRect, r.count == 4 {
            ann.loupeSourceRect = NSRect(x: r[0], y: r[1], width: r[2], height: r[3])
        }
        ann.loupeOutlineEnabled = c.loupeOutlineEnabled

        // Misc
        ann.measureInPoints = c.measureInPoints
        ann.censorMode = CensorMode(rawValue: c.censorMode) ?? .pixelate
        ann.censorShape = CensorShape(rawValue: c.censorShape ?? CensorShape.rectangle.rawValue) ?? .rectangle
        ann.censorStrength = CensorStrength.clamped(c.censorStrength ?? CensorStrength.defaultValue)
        // Highlight dim strength; older captures lack the field (decodes to the
        // struct default 0.55). Guard against a zero/invalid value.
        ann.dimOpacity = c.dimOpacity > 0 ? min(1, c.dimOpacity) : 0.55
        if let gidStr = c.groupID { ann.groupID = UUID(uuidString: gidStr) }
        // Legacy captures have seed=0; assign a fresh one so sketchy variation
        // remains deterministic per-load even for old data.
        ann.randomSeed = c.randomSeed != 0 ? c.randomSeed : UInt32.random(in: 1...UInt32.max)

        return ann
    }

    // MARK: - Helpers

    private static func encodeColor(_ color: NSColor) -> [CGFloat] {
        // Convert to sRGB to ensure consistent encoding regardless of display profile
        let c = color.usingColorSpace(.sRGB) ?? color
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent]
    }

    private static func decodeColor(_ rgba: [CGFloat]) -> NSColor {
        guard rgba.count >= 4 else { return .red }
        return NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3])
    }

    private static func encodeImage(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Batch encode/decode for history storage

enum AnnotationSerializer {

    static func encode(_ annotations: [Annotation]) -> Data? {
        let codables = annotations.map { $0.toCodable() }
        return try? JSONEncoder().encode(codables)
    }

    static func decode(_ data: Data) -> [Annotation]? {
        // Decode each JSON element independently: a malformed legacy item must
        // not make the rest of an editable capture disappear.
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let codables = raw.compactMap { item -> CodableAnnotation? in
            guard JSONSerialization.isValidJSONObject([item]),
                  let itemData = try? JSONSerialization.data(withJSONObject: [item]) else { return nil }
            return try? JSONDecoder().decode([CodableAnnotation].self, from: itemData).first
        }
        let annotations = codables.compactMap { Annotation.fromCodable($0) }
        return annotations.isEmpty ? nil : annotations
    }
}
