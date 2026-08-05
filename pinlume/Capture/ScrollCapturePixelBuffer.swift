import CoreGraphics
import Foundation

struct ScrollCapturePixelLayout: Equatable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bytesPerPixel: Int
}

/// Keeps the provider bytes alive and scopes every raw pointer to `withUnsafeBytes`.
/// Scroll capture only accepts the 8-bit, 32-bit little-endian BGRA frames emitted by
/// `CGWindowListCreateImage`; silently treating another format as BGRA corrupts matching.
struct ScrollCapturePixelBuffer {
    let layout: ScrollCapturePixelLayout
    private let bytes: Data

    init?(image: CGImage) {
        guard image.bitsPerComponent == 8,
              image.bitsPerPixel == 32,
              image.bytesPerRow >= image.width * 4,
              image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little,
              image.alphaInfo == .premultipliedFirst || image.alphaInfo == .noneSkipFirst,
              let providerData = image.dataProvider?.data
        else { return nil }

        let layout = ScrollCapturePixelLayout(
            width: image.width,
            height: image.height,
            bytesPerRow: image.bytesPerRow,
            bytesPerPixel: image.bitsPerPixel / 8
        )
        guard CFDataGetLength(providerData) >= layout.bytesPerRow * layout.height else { return nil }
        self.layout = layout
        self.bytes = providerData as Data
    }

    func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer, ScrollCapturePixelLayout) -> Result) -> Result {
        bytes.withUnsafeBytes { body($0, layout) }
    }
}
