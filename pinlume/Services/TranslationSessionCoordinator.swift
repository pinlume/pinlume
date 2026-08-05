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
        _ texts: [String],
        _ sourceLanguage: String?,
        _ targetLanguage: String,
        _ progress: @escaping @MainActor (Int, String) -> Void,
        _ completion: @escaping @MainActor (Result<[String], Error>) -> Void
    ) -> TranslationRequestHandle

    private struct Plan {
        let input: String
        let segments: [TranslationSegment]
        let sourceLanguage: String?
        let segmentSourceLanguage: String?
        let targetLanguage: String
    }

    private let translator: Translator
    private var requestToken = 0
    private var activeRequest: TranslationRequestHandle?
    private(set) var lastInput: String?

    init(translator: @escaping Translator) {
        self.translator = translator
    }

    func translate(
        _ source: String,
        sourceLanguage: String?,
        targetLanguage: String?,
        progress: ((TranslationPresentation) -> Void)? = nil,
        completion: @escaping (TranslationPresentation) -> Void
    ) {
        let input = source.trimmingCharacters(in: .whitespacesAndNewlines)
        lastInput = input.isEmpty ? nil : input
        cancelPending()
        let token = requestToken
        guard !input.isEmpty else {
            completion(TranslationPresentation(sourceText: "", translatedText: "", status: nil, sourceLanguage: nil, targetLanguage: nil))
            return
        }
        start(
            Self.makePlan(input: input, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage),
            token: token,
            progress: progress,
            completion: completion)
    }

    func cancelPending() {
        requestToken &+= 1
        activeRequest?.cancel()
        activeRequest = nil
    }

    private nonisolated static func makePlan(
        input: String,
        sourceLanguage: String?,
        targetLanguage: String?
    ) -> Plan {
        let automatic = sourceLanguage == nil || sourceLanguage == "auto"
        let target = targetLanguage ?? TranslationTextProcessor.automaticTargetLanguage(for: input)
        let resolvedSource = automatic
            ? TranslationTextProcessor.detectedSourceLanguage(for: input)
            : sourceLanguage
        let direction = TranslationTextProcessor.automaticDirection(for: input)
        let baseSegments: [TranslationSegment]
        if automatic {
            baseSegments = target == "zh-CN"
                ? TranslationTextProcessor.segmentsForAutomaticTranslation(
                    input, detectedSourceLanguage: resolvedSource ?? "en")
                : TranslationTextProcessor.segments(
                    for: input, direction: .englishToSimplifiedChinese)
        } else {
            baseSegments = TranslationTextProcessor.segments(
                for: input, direction: .englishToSimplifiedChinese)
        }
        let segments = baseSegments.flatMap { segment in
            guard segment.kind == .translatable else { return [segment] }
            return TranslationTextProcessor.chunkedSegments(
                for: segment.original,
                direction: .englishToSimplifiedChinese)
        }
        return Plan(
            input: input,
            segments: segments,
            sourceLanguage: resolvedSource,
            segmentSourceLanguage: automatic && direction == .mixedToSimplifiedChinese
                ? "en" : resolvedSource,
            targetLanguage: target)
    }

    private func start(
        _ plan: Plan,
        token: Int,
        progress: ((TranslationPresentation) -> Void)?,
        completion: @escaping (TranslationPresentation) -> Void
    ) {
        let translatableIndices = plan.segments.indices.filter {
            plan.segments[$0].kind == .translatable
        }
        guard !translatableIndices.isEmpty else {
            completion(presentation(for: plan, output: [:], status: nil))
            return
        }

        var output: [Int: String] = [:]
        var completedSynchronously = false
        let handle = translator(
            translatableIndices.map { plan.segments[$0].requestText },
            plan.segmentSourceLanguage,
            plan.targetLanguage,
            { [weak self] providerIndex, value in
                guard let self,
                      token == self.requestToken,
                      translatableIndices.indices.contains(providerIndex) else { return }
                output[translatableIndices[providerIndex]] = value
                progress?(self.presentation(for: plan, output: output, status: nil))
            },
            { [weak self] result in
                completedSynchronously = true
                guard let self, token == self.requestToken else { return }
                self.activeRequest = nil
                var status: String?
                switch result {
                case .success(let values):
                    for (providerIndex, segmentIndex) in translatableIndices.enumerated() {
                        if providerIndex < values.count, !values[providerIndex].isEmpty {
                            output[segmentIndex] = values[providerIndex]
                        } else if output[segmentIndex] == nil {
                            output[segmentIndex] = plan.segments[segmentIndex].original
                            status = status ?? NSLocalizedString(
                                "Translation failed; original text shown.",
                                comment: "Translation fallback status")
                        }
                    }
                case .failure(let error):
                    status = error.localizedDescription
                    for segmentIndex in translatableIndices where output[segmentIndex] == nil {
                        output[segmentIndex] = plan.segments[segmentIndex].original
                    }
                }
                completion(self.presentation(for: plan, output: output, status: status))
            })
        if completedSynchronously {
            handle.cancel()
        } else {
            activeRequest = handle
        }
    }

    private func presentation(
        for plan: Plan,
        output: [Int: String],
        status: String?
    ) -> TranslationPresentation {
        var translated = ""
        for (index, segment) in plan.segments.enumerated() {
            if segment.kind == .passthrough {
                translated += segment.original
            } else if let value = output[index] {
                translated += value
            } else {
                break
            }
        }
        return TranslationPresentation(
            sourceText: plan.input,
            translatedText: translated,
            status: status,
            sourceLanguage: plan.sourceLanguage,
            targetLanguage: plan.targetLanguage)
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
