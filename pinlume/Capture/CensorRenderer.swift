import AppKit
import CoreImage

/// Shared pixelate/blur renderer. It converts canvas coordinates to source
/// pixels once and crops the CGImage directly—no TIFF/bitmap round trip.
final class CensorRenderer {
    private let cgImage: CGImage
    private let sourceBounds: NSRect
    /// Pixelation never touches Core Image, so keep its comparatively expensive
    /// context lazy and pay that cost only when the user actually chooses blur.
    private lazy var ciContext = CIContext(options: [.cacheIntermediates: false])
    let pixelScale: CGFloat

    init?(sourceImage: NSImage, sourceBounds: NSRect) {
        guard sourceBounds.width > 0, sourceBounds.height > 0,
              let cgImage = sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        self.cgImage = cgImage
        self.sourceBounds = sourceBounds
        pixelScale = max(
            1,
            min(
                CGFloat(cgImage.width) / sourceBounds.width,
                CGFloat(cgImage.height) / sourceBounds.height
            )
        )
    }

    func render(
        canvasRect: NSRect,
        mode: CensorMode,
        strength: CGFloat
    ) -> NSImage? {
        let clipped = canvasRect.intersection(sourceBounds)
        guard clipped.width > 0, clipped.height > 0 else { return nil }

        let output: CGImage?
        switch mode {
        case .blur:
            guard let crop = cgImage.cropping(to: pixelCropRect(for: clipped)) else { return nil }
            output = blur(crop, strength: strength)
        case .pixelate:
            output = pixelateRegion(pixelCropRect(for: clipped), strength: strength)
        case .solid, .erase:
            output = cgImage.cropping(to: pixelCropRect(for: clipped))
        }
        guard let output else { return nil }
        return NSImage(cgImage: output, size: clipped.size)
    }

    private func pixelCropRect(for rect: NSRect) -> CGRect {
        let scaleX = CGFloat(cgImage.width) / sourceBounds.width
        let scaleY = CGFloat(cgImage.height) / sourceBounds.height
        let x = (rect.minX - sourceBounds.minX) * scaleX
        // CGImage crops address rows from the top; AppKit canvas coordinates
        // address the same screenshot from the bottom.
        let y = (sourceBounds.maxY - rect.maxY) * scaleY
        let pixelRect = CGRect(
            x: floor(x),
            y: floor(y),
            width: ceil(rect.width * scaleX),
            height: ceil(rect.height * scaleY)
        ).intersection(CGRect(
            x: 0, y: 0,
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height)
        ))
        return pixelRect.integral
    }

    private func pixelate(_ image: CGImage, strength: CGFloat) -> CGImage? {
        let block = max(
            2,
            CensorStrength.pixelBlockSize(for: strength, pixelScale: pixelScale)
        )
        let tinyWidth = max(1, Int(ceil(Double(image.width) / Double(block))))
        let tinyHeight = max(1, Int(ceil(Double(image.height) / Double(block))))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let downsample = CGContext(
            data: nil,
            width: tinyWidth,
            height: tinyHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }
        downsample.interpolationQuality = .low
        downsample.draw(image, in: CGRect(x: 0, y: 0, width: tinyWidth, height: tinyHeight))
        guard let tiny = downsample.makeImage(),
              let output = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: bitmapInfo
              )
        else { return nil }
        output.interpolationQuality = .none
        output.draw(tiny, in: CGRect(
            x: 0, y: 0,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        ))
        return output.makeImage()
    }

    private func pixelateRegion(_ desiredRect: CGRect, strength: CGFloat) -> CGImage? {
        let block = CGFloat(max(
            2,
            CensorStrength.pixelBlockSize(for: strength, pixelScale: pixelScale)
        ))
        let imageBounds = CGRect(
            x: 0, y: 0,
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height)
        )
        let alignedRect = CGRect(
            x: floor(desiredRect.minX / block) * block,
            y: floor(desiredRect.minY / block) * block,
            width: ceil(desiredRect.maxX / block) * block
                - floor(desiredRect.minX / block) * block,
            height: ceil(desiredRect.maxY / block) * block
                - floor(desiredRect.minY / block) * block
        ).intersection(imageBounds).integral
        guard let alignedSource = cgImage.cropping(to: alignedRect),
              let alignedOutput = pixelate(alignedSource, strength: strength)
        else { return nil }
        let localDesired = CGRect(
            x: desiredRect.minX - alignedRect.minX,
            y: desiredRect.minY - alignedRect.minY,
            width: desiredRect.width,
            height: desiredRect.height
        ).integral
        return alignedOutput.cropping(to: localDesired)
    }

    private func blur(_ image: CGImage, strength: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        let radius = CensorStrength.blurRadius(
            for: strength,
            cropSize: CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        )
        let clamped = input.clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(radius, forKey: kCIInputRadiusKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(
            output,
            from: CGRect(
                x: 0, y: 0,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            )
        )
    }
}
