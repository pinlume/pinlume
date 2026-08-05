import Foundation
import CoreGraphics
import CoreMedia
import ImageIO
import UniformTypeIdentifiers
import CoreVideo

/// Accumulates CVPixelBuffer frames and writes them as an animated GIF.
/// Each selected frame is copied immediately so the reader can recycle its
/// pixel buffer. Selection and frame duration use source PTS values, which is
/// essential for variable-frame-rate recordings.
final class GIFEncoder {

    enum Error: LocalizedError {
        case destinationUnavailable
        case unsupportedPixelFormat
        case imageCreationFailed
        case noFrames
        case finalizeFailed

        var errorDescription: String? {
            switch self {
            case .destinationUnavailable: return "Unable to create GIF destination"
            case .unsupportedPixelFormat: return "Unsupported GIF source pixel format"
            case .imageCreationFailed: return "Unable to create GIF frame"
            case .noFrames: return "No GIF frames were produced"
            case .finalizeFailed: return "Unable to finalize GIF"
            }
        }
    }

    private var destination: CGImageDestination?
    private let gifProperties: [CFString: Any]
    private var frameCount = 0
    private var pendingImage: CGImage?
    private var pendingTime: Double?
    private var timing: GIFFrameTiming
    private let lock = NSLock()

    init(url: URL, fps: Int) {
        timing = GIFFrameTiming(fps: fps)
        gifProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: 0, // 0 = infinite
            ] as [CFString: Any]
        ]
        destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, Int.max, nil)
        if let destination {
            CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)
        }
    }

    /// Adds a frame at its real media timestamp. The previous selected frame
    /// is written only when its succeeding PTS is known, so its GIF delay is
    /// accurate instead of a guessed constant.
    func addFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let destination else { throw Error.destinationUnavailable }
        let seconds = CMTimeGetSeconds(presentationTime)
        guard try timing.shouldSelect(presentationTime: seconds) else { return }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            throw Error.unsupportedPixelFormat
        }

        let image = try ownedImage(from: pixelBuffer)
        if let pendingImage, let pendingTime {
            CGImageDestinationAddImage(destination, pendingImage, frameProperties(delay: try timing.delay(from: pendingTime, to: seconds)) as CFDictionary)
            frameCount += 1
        }
        self.pendingImage = image
        self.pendingTime = seconds
    }

    /// Finalizes the destination and reports failure. Callers must not commit
    /// the temporary GIF unless this succeeds.
    func finish(finalPresentationTime: CMTime) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let destination else { throw Error.destinationUnavailable }
        guard let pendingImage else { throw Error.noFrames }
        let endTime = CMTimeGetSeconds(finalPresentationTime)
        let trailingDelay = try timing.trailingDelay(finalPresentationTime: endTime)
        CGImageDestinationAddImage(destination, pendingImage, frameProperties(delay: trailingDelay) as CFDictionary)
        frameCount += 1
        self.pendingImage = nil
        self.pendingTime = nil
        defer { self.destination = nil }
        guard frameCount > 0, CGImageDestinationFinalize(destination) else { throw Error.finalizeFailed }
    }

    private func frameProperties(delay: Float) -> [CFString: Any] {
        [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ] as [CFString: Any]
        ]
    }

    private func ownedImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw Error.imageCreationFailed }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let source = CGContext(
            data: baseAddress,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ), let sourceImage = source.makeImage(), let owned = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { throw Error.imageCreationFailed }

        owned.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = owned.makeImage() else { throw Error.imageCreationFailed }
        return image
    }
}
