import Foundation
import NaturalLanguage

enum TranslationDirection: Equatable {
    case chineseToEnglish
    case englishToSimplifiedChinese
    case mixedToSimplifiedChinese
}

enum TranslationSegmentKind: Equatable {
    case passthrough
    case translatable
}

struct TranslationSegment: Equatable {
    let original: String
    let requestText: String
    let kind: TranslationSegmentKind
}

enum TranslationTextProcessor {
    static func detectedSourceLanguage(for text: String) -> String {
        let direction = automaticDirection(for: text)
        let containsKana = text.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value)
        }
        if containsKana { return "ja" }

        // Latin product names can dominate a short CJK phrase (for example,
        // "東京都 Apple Store").  Recognize the CJK portion separately before
        // falling back to the whole string so Kanji-only Japanese is not
        // classified as Chinese merely because it uses Han characters.
        let containsHan = text.unicodeScalars.contains { isHan($0.value) }
        let recognitionText: String
        if containsHan {
            recognitionText = String(text.unicodeScalars.filter {
                !isASCIILetter($0.value) && !($0.value >= 0x30 && $0.value <= 0x39)
            })
        } else {
            recognitionText = text
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(recognitionText)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        if containsHan,
           let japaneseConfidence = hypotheses[.japanese],
           japaneseConfidence >= 0.55 {
            return "ja"
        }
        if containsHan {
            if mixedSegments(for: text).contains(where: { $0.kind == .translatable }) {
                return "en"
            }
            if recognizer.dominantLanguage == .traditionalChinese,
               (hypotheses[.simplifiedChinese] ?? 0) < 0.10 {
                return "zh-TW"
            }
            return "zh-CN"
        }
        if let language = recognizer.dominantLanguage {
            switch language.rawValue {
            case "zh-Hans", "zh": return "zh-CN"
            case "zh-Hant":
                // Very short shared phrases such as “你好” are often labelled
                // Traditional with low confidence even though they contain no
                // script-specific characters. Keep the established Simplified
                // default when the Hans hypothesis remains meaningful.
                return (hypotheses[.simplifiedChinese] ?? 0) >= 0.10
                    ? "zh-CN" : "zh-TW"
            default: return language.rawValue
            }
        }
        return direction == .chineseToEnglish ? "zh-CN" : "en"
    }

    static func automaticTargetLanguage(for text: String) -> String {
        let source = detectedSourceLanguage(for: text)
        let direction = automaticDirection(for: text)
        return source.hasPrefix("zh") && direction != .mixedToSimplifiedChinese
            ? "en" : "zh-CN"
    }

    static func automaticDirection(for text: String) -> TranslationDirection {
        var containsChinese = false
        var containsEnglish = false

        for scalar in text.unicodeScalars {
            containsChinese = containsChinese || isHan(scalar.value)
            containsEnglish = containsEnglish || isASCIILetter(scalar.value)
            if containsChinese && containsEnglish { return .mixedToSimplifiedChinese }
        }

        return containsChinese ? .chineseToEnglish : .englishToSimplifiedChinese
    }

    static func segments(for text: String, direction: TranslationDirection) -> [TranslationSegment] {
        guard !text.isEmpty else { return [] }

        switch direction {
        case .chineseToEnglish, .englishToSimplifiedChinese:
            return [TranslationSegment(
                original: text,
                requestText: expandedIdentifiers(in: text),
                kind: .translatable
            )]
        case .mixedToSimplifiedChinese:
            return mixedSegments(for: text)
        }
    }

    static func segmentsForAutomaticTranslation(
        _ text: String,
        detectedSourceLanguage: String
    ) -> [TranslationSegment] {
        let direction = automaticDirection(for: text)
        if direction == .mixedToSimplifiedChinese {
            if detectedSourceLanguage == "en" || detectedSourceLanguage.hasPrefix("zh") {
                return mixedSegments(for: text)
            }
            return segments(for: text, direction: .englishToSimplifiedChinese)
        }
        return segments(for: text, direction: direction)
    }

    static func sentenceComparison(source: String, translated: String) -> String {
        let sourceSentences = sentences(in: source)
        let translatedSentences = sentences(in: translated)
        let count = max(sourceSentences.count, translatedSentences.count)
        guard count > 0 else { return "" }

        return (0..<count).compactMap { index -> String? in
            var pair: [String] = []
            if index < sourceSentences.count { pair.append(sourceSentences[index]) }
            if index < translatedSentences.count { pair.append(translatedSentences[index]) }
            return pair.isEmpty ? nil : pair.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private static func mixedSegments(for text: String) -> [TranslationSegment] {
        let expression = try! NSRegularExpression(pattern: "[A-Za-z0-9_]+")
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var cursor = text.startIndex
        var result: [TranslationSegment] = []
        var pendingEnglish: String?

        func append(_ original: String, kind: TranslationSegmentKind) {
            guard !original.isEmpty else { return }
            if kind == .passthrough, let last = result.last, last.kind == .passthrough {
                result[result.count - 1] = TranslationSegment(
                    original: last.original + original,
                    requestText: last.requestText + original,
                    kind: .passthrough
                )
                return
            }
            result.append(TranslationSegment(
                original: original,
                requestText: kind == .translatable ? expandedIdentifier(original) : original,
                kind: kind
            ))
        }

        func flushPendingEnglish() {
            guard let pending = pendingEnglish, !pending.isEmpty else { return }
            append(
                pending,
                kind: isTranslatableMixedEnglishRun(pending) ? .translatable : .passthrough)
            pendingEnglish = nil
        }

        func isEnglishJoiner(_ text: String) -> Bool {
            !text.isEmpty && text.unicodeScalars.allSatisfy {
                $0.value <= 0x7F && !isASCIILetter($0.value) && !($0.value >= 0x30 && $0.value <= 0x39)
            }
        }

        func splitEnglishJoinerPrefix(_ text: String) -> (joiner: String, remainder: String) {
            let boundary = text.unicodeScalars.firstIndex {
                $0.value > 0x7F || isASCIILetter($0.value) || ($0.value >= 0x30 && $0.value <= 0x39)
            } ?? text.unicodeScalars.endIndex
            return (
                String(text.unicodeScalars[..<boundary]),
                String(text.unicodeScalars[boundary...]))
        }

        for match in expression.matches(in: text, range: fullRange) {
            guard let range = Range(match.range, in: text) else { continue }
            let separator = String(text[cursor..<range.lowerBound])
            let candidate = String(text[range])
            let isWord = candidate.unicodeScalars.contains { isASCIILetter($0.value) }
            guard isWord else {
                flushPendingEnglish()
                append(separator + candidate, kind: .passthrough)
                cursor = range.upperBound
                continue
            }
            if let pending = pendingEnglish {
                if isEnglishJoiner(separator) {
                    pendingEnglish = pending + separator + candidate
                } else {
                    let parts = splitEnglishJoinerPrefix(separator)
                    pendingEnglish = pending + parts.joiner
                    flushPendingEnglish()
                    append(parts.remainder, kind: .passthrough)
                    pendingEnglish = candidate
                }
            } else {
                append(separator, kind: .passthrough)
                pendingEnglish = candidate
            }
            cursor = range.upperBound
        }
        let tail = String(text[cursor...])
        if let pending = pendingEnglish {
            let parts = splitEnglishJoinerPrefix(tail)
            pendingEnglish = pending + parts.joiner
            flushPendingEnglish()
            append(parts.remainder, kind: .passthrough)
        } else {
            append(tail, kind: .passthrough)
        }
        return result
    }

    private static func isTranslatableMixedEnglishRun(_ text: String) -> Bool {
        guard !text.contains("_") else { return false }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        var wordCount = 0
        var hasSentenceStructure = false
        let structuralTags: Set<NLTag> = [
            .verb, .adverb, .pronoun, .determiner, .preposition, .conjunction,
        ]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, _ in
            wordCount += 1
            if let tag, structuralTags.contains(tag) {
                hasSentenceStructure = true
            }
            return true
        }
        return wordCount > 1 && hasSentenceStructure
    }

    private static func expandedIdentifiers(in text: String) -> String {
        let expression = try! NSRegularExpression(pattern: "[A-Za-z0-9_]+")
        let source = text as NSString
        var result = text
        for match in expression.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        ).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: expandedIdentifier(String(result[range])))
        }
        return result
    }

    private static func expandedIdentifier(_ identifier: String) -> String {
        var result = identifier.replacingOccurrences(of: "_", with: " ")
        result = replacingMatches(
            in: result,
            pattern: "([A-Z]+)([A-Z][a-z])",
            template: "$1 $2"
        )
        result = replacingMatches(
            in: result,
            pattern: "([a-z0-9])([A-Z])",
            template: "$1 $2"
        )
        return result
    }

    private static func replacingMatches(
        in text: String,
        pattern: String,
        template: String
    ) -> String {
        let expression = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: template
        )
    }

    private static func sentences(in text: String) -> [String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        let range = text.startIndex..<text.endIndex
        let values = tokenizer.tokens(for: range).compactMap { tokenRange -> String? in
            let sentence = text[tokenRange].trimmingCharacters(in: .whitespacesAndNewlines)
            return sentence.isEmpty ? nil : sentence
        }
        return values.isEmpty ? [text.trimmingCharacters(in: .whitespacesAndNewlines)] : values
    }

    private static func isASCIILetter(_ value: UInt32) -> Bool {
        (65...90).contains(value) || (97...122).contains(value)
    }

    private static func isHan(_ value: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2FA1F).contains(value)
    }
}
