import AppKit

struct ScreenTranslationSession {
    enum DisplayMode: String, Codable { case original, translated }
    let originalImage: NSImage
    let translatedImage: NSImage
    let translatedBlocks: [TranslatedTextBlock]
    let sourceLanguage: String
    let targetLanguage: String
    let globalFrame: NSRect
    var originalBlocks: [RecognizedTextBlock] = []
    var translatedSelectionBlocks: [RecognizedTextBlock] = []
    var displayMode: DisplayMode = .translated
    var comparisonEnabled = false

    var originalText: String {
        StructuredOCRResult(blocks: selectableOriginalBlocks).plainText
    }
    var translatedText: String {
        StructuredOCRResult(blocks: translatedBlocks.map {
            RecognizedTextBlock(text: $0.translatedText,
                normalizedBoundingBox: $0.block.normalizedBoundingBox,
                confidence: $0.block.confidence)
        }).plainText
    }

    var selectableOriginalBlocks: [RecognizedTextBlock] {
        originalBlocks.isEmpty ? translatedBlocks.map(\.block) : originalBlocks
    }

    var selectableTranslatedBlocks: [RecognizedTextBlock] {
        guard translatedSelectionBlocks.isEmpty else { return translatedSelectionBlocks }
        return translatedBlocks.map {
            RecognizedTextBlock(
                text: $0.translatedText,
                normalizedBoundingBox: $0.block.normalizedBoundingBox,
                confidence: $0.block.confidence)
        }
    }
}

struct TranslatedTextBlock: Codable, Equatable {
    let block: RecognizedTextBlock
    let translatedText: String
}

struct ScreenTranslationSessionState {
    private var token = 0
    mutating func begin() -> Int { token &+= 1; return token }
    mutating func cancel() { token &+= 1 }
    func accept(_ expected: Int) -> Bool { expected == token }
}

enum ScreenTranslationOverlayPhase: Equatable {
    case idle
    case processing
    case ready
}

struct ScreenTranslationOverlayState {
    private var token = 0
    private(set) var phase: ScreenTranslationOverlayPhase = .idle
    private(set) var displayMode: ScreenTranslationSession.DisplayMode = .original

    mutating func beginProcessing() -> Int {
        token &+= 1
        phase = .processing
        displayMode = .original
        return token
    }

    @discardableResult
    mutating func complete(token expected: Int) -> Bool {
        guard token == expected, phase == .processing else { return false }
        phase = .ready
        displayMode = .translated
        return true
    }

    mutating func toggleDisplay() {
        guard phase == .ready else { return }
        displayMode = displayMode == .original ? .translated : .original
    }

    mutating func cancel() {
        token &+= 1
        phase = .idle
        displayMode = .original
    }
}

enum ScreenTranslationKeyRoute: Equatable {
    case cancel
    case pin
    case blocked
}

enum ScreenTranslationInputGate {
    static func route(keyCode: UInt16, isReady: Bool) -> ScreenTranslationKeyRoute {
        switch keyCode {
        case 53: return .cancel
        case 36, 76: return isReady ? .pin : .blocked
        default: return .blocked
        }
    }
}
