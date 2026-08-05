import CoreGraphics
import Foundation
import ImageIO

/// Disk-backed strips keep long captures from repeatedly allocating an ever-larger bitmap.
final class ScrollCaptureSpool {
    private let directory: URL
    private(set) var width = 0
    private(set) var totalHeight = 0
    private(set) var totalBytes = 0
    private var urls: [URL] = []

    init?() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pinlume-scroll-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.directory = directory
        } catch {
            return nil
        }
    }

    deinit { discard() }

    func append(_ image: CGImage) -> Bool {
        guard width == 0 || width == image.width else { return false }
        let url = directory.appendingPathComponent("\(urls.count).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return false }
        urls.append(url)
        width = image.width
        totalHeight += image.height
        totalBytes += image.bytesPerRow * image.height
        return true
    }

    func render() -> CGImage? {
        guard width > 0, totalHeight > 0,
              let context = CGContext(
                data: nil, width: width, height: totalHeight,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        var y = totalHeight
        for url in urls {
            guard let image = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { return nil }
            y -= image.height
            context.draw(image, in: CGRect(x: 0, y: y, width: image.width, height: image.height))
        }
        return context.makeImage()
    }

    func discard() {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
