import Cocoa
import UniformTypeIdentifiers

/// Emoji data for the stamp tool — shared by StampToolHandler, EmojiPickerView, ToolOptionsRowView.
enum StampEmojis {
    static let defaultSize: CGFloat = 64
    static let minimumSize: CGFloat = 8
    static let maximumSize: CGFloat = 512

    static func clampedSize(_ value: CGFloat) -> CGFloat {
        min(max(value, minimumSize), maximumSize)
    }

    static func bounds(for image: NSImage, centeredAt point: NSPoint, size: CGFloat) -> NSRect {
        let stampSize = clampedSize(size)
        let aspect = image.size.width / max(image.size.height, 1)
        let width = aspect >= 1 ? stampSize : stampSize * aspect
        let height = aspect >= 1 ? stampSize / aspect : stampSize
        return NSRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    }

    static let categories: [(String, [String])] = [
        (
            "😀",
            [  // Faces & People
                "😀", "😂", "🤣", "😍", "🤔", "😎", "🤯", "😱",
                "😤", "🥳", "🤡", "💩", "👻", "🤖", "👽", "😈",
                "🙈", "🙉", "🙊", "💪", "👏", "🙌", "🤝", "🫡",
            ]
        ),
        (
            "👆",
            [  // Hands & Gestures
                "👆", "👇", "👈", "👉", "👍", "👎", "✊", "👊",
                "🤞", "✌️", "🤟", "🫵", "☝️", "👋", "🖐️", "✋",
            ]
        ),
        (
            "✅",
            [  // Symbols & Status
                "✅", "❌", "⚠️", "❓", "❗", "⛔", "🚫", "💯",
                "✏️", "🗑️", "📌", "🔒", "🔓", "🏷️", "📎", "🔗",
                "⬆️", "⬇️", "⬅️", "➡️", "↩️", "🔄", "➕", "➖",
            ]
        ),
        (
            "🔥",
            [  // Objects & Reactions
                "🔥", "💡", "⭐", "❤️", "💀", "🐛", "🎯", "🚀",
                "🎉", "💣", "🧨", "⚡", "💥", "🔔", "📢", "🏆",
                "🛑", "🚧", "🏗️", "🧪", "🔬", "💻", "📱", "🖥️",
            ]
        ),
        (
            "🚩",
            [  // Flags & Markers
                "🚩", "🏁", "📍", "💬", "💭", "🗯️", "👁️", "👀",
                "🔍", "🔎", "📝", "📋", "📊", "📈", "📉", "🗂️",
            ]
        ),
    ]

    static let common = [
        "👆", "👇", "👈", "👉",  // point at things
        "✅", "❌", "⚠️", "❓",  // approve / reject / warn / question
        "🔥", "🐛", "💀", "🎉",  // reactions: hot, bug, dead, celebrate
        "👀", "💡", "🎯", "⭐",  // look here, idea, bullseye, star
        "❤️", "👍", "👎", "🚀",  // love, thumbs, launch
    ]

    /// Render an emoji string to an NSImage.
    static func renderEmoji(_ emoji: String, size: CGFloat = 128) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size * 0.85)]
        let str = emoji as NSString
        let strSize = str.size(withAttributes: attrs)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            str.draw(
                at: NSPoint(x: (size - strSize.width) / 2, y: (size - strSize.height) / 2),
                withAttributes: attrs)
            return true
        }
        img.setName(emoji)
        return img
    }

    /// Show a file picker to load a custom stamp image.
    static func loadStampImage(completion: @escaping (NSImage) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.level = NSWindow.Level(258)
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                let image = NSImage(contentsOf: url)
            else { return }
            completion(image)
        }
    }
}

/// Handles stamp (emoji/image) tool interaction.
/// Click-to-place: creates a stamp annotation immediately on mouseDown.
final class StampToolHandler: AnnotationToolHandler {

    let tool: AnnotationTool = .stamp

    func start(at point: NSPoint, canvas: AnnotationCanvas) -> Annotation? {
        // Auto-select first emoji if nothing selected
        if canvas.currentStampImage == nil {
            canvas.currentStampImage = StampEmojis.renderEmoji(StampEmojis.common[0])
            canvas.currentStampEmoji = StampEmojis.common[0]
        }
        guard let img = canvas.currentStampImage else { return nil }

        let stampRect = StampEmojis.bounds(for: img, centeredAt: point, size: canvas.currentStampSize)
        let annotation = Annotation(
            tool: .stamp,
            startPoint: stampRect.origin,
            endPoint: NSPoint(x: stampRect.maxX, y: stampRect.maxY),
            color: .clear, strokeWidth: 0
        )
        annotation.stampImage = img

        // Stamp is instant. Do not route it through the generic commit path:
        // that path copies a full-size cached bitmap for every click, which is
        // more expensive than a small stamp on a large pinned image.
        canvas.annotations.append(annotation)
        canvas.undoStack.append(.added(annotation))
        canvas.redoStack.removeAll()
        canvas.annotationDidCommit(annotation)
        canvas.setNeedsDisplay()
        return nil  // nil = don't set as activeAnnotation
    }

    func update(to point: NSPoint, shiftHeld: Bool, canvas: AnnotationCanvas) {
        // No drag behavior
    }

    func finish(canvas: AnnotationCanvas) {
        // No finish behavior — stamp committed in start()
    }
}
