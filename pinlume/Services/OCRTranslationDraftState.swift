import Foundation

/// Keeps editable OCR source and translation text independent while rejecting
/// provider completions that became stale after any user edit.
struct OCRTranslationDraftState {
    enum DisplayedDraft: Equatable {
        case source
        case translated
    }

    private(set) var sourceDraft: String
    private(set) var translatedDraft: String?
    private(set) var displayedDraft: DisplayedDraft = .source
    private var requestGeneration = TranslationRequestGeneration()

    init(sourceDraft: String) {
        self.sourceDraft = sourceDraft
    }

    var visibleText: String {
        switch displayedDraft {
        case .source:
            return sourceDraft
        case .translated:
            return translatedDraft ?? sourceDraft
        }
    }

    mutating func beginTranslation() -> TranslationRequestToken {
        requestGeneration.begin()
    }

    func contains(_ token: TranslationRequestToken) -> Bool {
        requestGeneration.contains(token)
    }

    @discardableResult
    mutating func acceptTranslation(_ text: String, token: TranslationRequestToken) -> Bool {
        guard requestGeneration.contains(token) else { return false }
        requestGeneration.invalidate()
        translatedDraft = text
        displayedDraft = .translated
        return true
    }

    mutating func editVisibleText(_ text: String) {
        requestGeneration.invalidate()
        switch displayedDraft {
        case .source:
            sourceDraft = text
            translatedDraft = nil
        case .translated:
            translatedDraft = text
        }
    }

    mutating func showSource() {
        requestGeneration.invalidate()
        displayedDraft = .source
    }

    @discardableResult
    mutating func showTranslation() -> Bool {
        guard translatedDraft != nil else { return false }
        requestGeneration.invalidate()
        displayedDraft = .translated
        return true
    }

    mutating func invalidateTranslation(clearTranslatedDraft: Bool = false) {
        requestGeneration.invalidate()
        if clearTranslatedDraft {
            translatedDraft = nil
            displayedDraft = .source
        }
    }

    mutating func restoreVisibleDraft(_ text: String, displayedDraft: DisplayedDraft) {
        requestGeneration.invalidate()
        self.displayedDraft = displayedDraft
        switch displayedDraft {
        case .source:
            sourceDraft = text
        case .translated:
            translatedDraft = text
        }
    }
}
