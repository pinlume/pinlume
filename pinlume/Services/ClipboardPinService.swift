import AppKit
import ImageIO

enum ClipboardPinResult {
    case image(NSImage)
    case text(NSImage, String)
    case unsupported
}

enum ClipboardPinService {

    static func image(from item: NSPasteboardItem) -> ClipboardPinResult {
        if let image = imageFromItem(item) {
            return .image(image)
        }
        if let text = textImageFromItem(item) {
            return .text(text.image, text.content)
        }
        return .unsupported
    }

    private static func imageFromItem(_ item: NSPasteboardItem) -> NSImage? {
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
            NSPasteboard.PasteboardType("public.heif"),
            NSPasteboard.PasteboardType("com.compuserve.gif"),
        ]

        for type in imageTypes {
            guard let data = item.data(forType: type),
                  imageDataFitsBudget(data),
                  let image = NSImage(data: data),
                  isUsable(image) else { continue }
            return image
        }

        if let fileURL = fileURLFromItem(item),
           fileFitsBudget(fileURL),
           let image = NSImage(contentsOf: fileURL),
           isUsable(image) {
            return image
        }

        return nil
    }

    private static func textImageFromItem(_ item: NSPasteboardItem) -> (image: NSImage, content: String)? {
        if let data = item.data(forType: .html),
           let attributed = ClipboardTextPinRenderer.attributedString(html: data),
           !ClipboardTextPinRenderer.containsAttachments(attributed) {
            if let image = ClipboardTextPinRenderer.render(attributed) {
                return (image, attributed.string)
            }
        }

        if let data = item.data(forType: .rtf),
           let attributed = ClipboardTextPinRenderer.attributedString(rtf: data),
           let image = ClipboardTextPinRenderer.render(attributed) {
            return (image, attributed.string)
        }

        let rtfdType = NSPasteboard.PasteboardType("com.apple.flat-rtfd")
        if let data = item.data(forType: rtfdType),
           let attributed = ClipboardTextPinRenderer.attributedString(rtfd: data),
           let image = ClipboardTextPinRenderer.render(attributed) {
            return (image, attributed.string)
        }

        if let string = item.string(forType: .string),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let safeString = ClipboardTextPinRenderer.safePlainText(string)
            let attributed = ClipboardTextPinRenderer.plainAttributedString(safeString)
            if let image = ClipboardTextPinRenderer.render(attributed, fallbackBackground: .white) {
                return (image, safeString)
            }
        }

        return nil
    }

    private static func fileURLFromItem(_ item: NSPasteboardItem) -> URL? {
        if let value = item.string(forType: .fileURL),
           let url = URL(string: value),
           url.isFileURL {
            return url
        }

        let urlTypes: [NSPasteboard.PasteboardType] = [
            NSPasteboard.PasteboardType("public.file-url"),
            NSPasteboard.PasteboardType("NSURLPboardType"),
        ]
        for type in urlTypes {
            if let value = item.string(forType: type),
               let url = URL(string: value),
               url.isFileURL {
                return url
            }
        }

        return nil
    }

    private static func isUsable(_ image: NSImage) -> Bool {
        image.isValid && image.size.width > 0 && image.size.height > 0
            && ClipboardTextPinRenderer.imageFitsBudget(image)
    }

    private static func fileFitsBudget(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return false }
        guard size >= 0 && size <= ClipboardTextPinRenderer.ImportBudget.maxImageBytes else { return false }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return pixelPropertiesFitBudget(properties)
    }

    private static func imageDataFitsBudget(_ data: Data) -> Bool {
        guard data.count <= ClipboardTextPinRenderer.ImportBudget.maxImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return pixelPropertiesFitBudget(properties)
    }

    private static func pixelPropertiesFitBudget(_ properties: [CFString: Any]) -> Bool {
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        let pixels = Int64(width) * Int64(height)
        return width > 0 && height > 0 && pixels <= Int64(ClipboardTextPinRenderer.ImportBudget.maxImagePixels)
    }
}
