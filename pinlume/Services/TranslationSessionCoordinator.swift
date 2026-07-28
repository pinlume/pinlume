import Foundation

struct TranslationPresentation: Equatable {
    let sourceText: String
    let translatedText: String
    let status: String?
    let sourceLanguage: String?
    let targetLanguage: String?
}

@MainActor
final class TranslationSessionCoordinator {
    typealias Translator = @MainActor (
        _ text: String,
        _ sourceLanguage: String?,
        _ targetLanguage: String,
        _ completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) -> Void

    private let translator: Translator
    private var requestToken = 0
    private(set) var lastInput: String?

    init(translator: @escaping Translator) {
        self.translator = translator
    }

    func translate(
        _ source: String,
        sourceLanguage: String?,
        targetLanguage: String?,
        completion: @escaping (TranslationPresentation) -> Void
    ) {
        let input = source.trimmingCharacters(in: .whitespacesAndNewlines)
        lastInput = input.isEmpty ? nil : input
        requestToken &+= 1
        let token = requestToken
        guard !input.isEmpty else {
            completion(TranslationPresentation(sourceText: "", translatedText: "", status: nil, sourceLanguage: nil, targetLanguage: nil))
            return
        }

        let automatic = sourceLanguage == nil || sourceLanguage == "auto"
        let automaticTarget = TranslationTextProcessor.automaticTargetLanguage(for: input)
        let target = targetLanguage ?? automaticTarget
        let resolvedSource = automatic
            ? TranslationTextProcessor.detectedSourceLanguage(for: input)
            : sourceLanguage
        let segments: [TranslationSegment] = automatic
            ? (target == "zh-CN"
                ? TranslationTextProcessor.segmentsForAutomaticTranslation(
                    input, detectedSourceLanguage: resolvedSource ?? "en")
                : TranslationTextProcessor.segments(
                    for: input, direction: .englishToSimplifiedChinese))
            : [TranslationSegment(original: input, requestText: input, kind: .translatable)]
        var output = Array(repeating: "", count: segments.count)
        var failureStatus: String?

        func finishIfCurrent() {
            guard token == requestToken else { return }
            completion(TranslationPresentation(
                sourceText: input,
                translatedText: output.joined(),
                status: failureStatus,
                sourceLanguage: resolvedSource,
                targetLanguage: target))
        }

        func process(_ index: Int) {
            guard token == requestToken else { return }
            guard index < segments.count else { finishIfCurrent(); return }
            let segment = segments[index]
            guard segment.kind == .translatable else {
                output[index] = segment.original
                process(index + 1)
                return
            }
            let segmentSource = automatic
                && TranslationTextProcessor.automaticDirection(for: input) == .mixedToSimplifiedChinese
                ? "en" : resolvedSource
            translator(segment.requestText, segmentSource, target) { result in
                guard token == self.requestToken else { return }
                switch result {
                case .success(let value) where !value.isEmpty:
                    output[index] = value
                case .failure(let error):
                    output[index] = segment.original
                    if failureStatus == nil {
                        failureStatus = error.localizedDescription
                    }
                default:
                    output[index] = segment.original
                    if failureStatus == nil {
                        failureStatus = "Translation failed; original text shown."
                    }
                }
                process(index + 1)
            }
        }
        process(0)
    }

    func cancelPending() {
        requestToken &+= 1
    }
}

struct TranslationSwapContext {
    let lastResolvedSource: String?
    let lastResolvedTarget: String?
    let currentResult: String
    let rawTranslation: String
}

enum TranslationSwapDecision: Equatable {
    case apply(sourceLanguage: String, targetLanguage: String, sourceText: String)
    case preserveEditedResult
    case unavailable
}

enum TranslationSwapResolver {
    static func resolve(_ context: TranslationSwapContext) -> TranslationSwapDecision {
        guard !context.rawTranslation.isEmpty,
              context.currentResult == context.rawTranslation else {
            return context.rawTranslation.isEmpty ? .unavailable : .preserveEditedResult
        }
        guard let source = context.lastResolvedSource,
              let target = context.lastResolvedTarget,
              source != target else { return .unavailable }
        return .apply(sourceLanguage: target, targetLanguage: source, sourceText: context.rawTranslation)
    }
}
