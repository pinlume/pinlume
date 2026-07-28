import Foundation
import NaturalLanguage
import Combine
import SwiftUI
@preconcurrency import Translation

enum TranslationProvider: String {
    case apple = "apple"
    case google = "google"
}

enum TranslationService {

    // MARK: - Provider

    static var provider: TranslationProvider {
        get {
            if let raw = UserDefaults.standard.string(forKey: "translationProvider"),
               let p = TranslationProvider(rawValue: raw) { return p }
            return .google  // Google by default — Apple requires language pack downloads
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "translationProvider") }
    }

    static let googleTranslationAllowedKey = "googleTranslationAllowed"

    /// Explicit privacy gate for the network-backed Google provider.
    /// A missing value preserves the existing default behavior (Google allowed).
    static var googleTranslationAllowed: Bool {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: googleTranslationAllowedKey) != nil else { return true }
            return defaults.bool(forKey: googleTranslationAllowedKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: googleTranslationAllowedKey) }
    }

    /// Whether Apple Translation is available on this system.
    static var appleTranslationAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    // MARK: - Target language

    static var targetLanguage: String {
        get { UserDefaults.standard.string(forKey: "translateTargetLang") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "translateTargetLang") }
    }

    static let availableLanguages: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("ru", "Russian"),
        ("zh-CN", "Chinese (Simplified)"),
        ("zh-TW", "Chinese (Traditional)"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("ar", "Arabic"),
        ("tr", "Turkish"),
        ("sv", "Swedish"),
        ("da", "Danish"),
        ("fi", "Finnish"),
        ("nb", "Norwegian"),
        ("uk", "Ukrainian"),
        ("cs", "Czech"),
        ("ro", "Romanian"),
        ("hu", "Hungarian"),
        ("sk", "Slovak"),
        ("bg", "Bulgarian"),
        ("hr", "Croatian"),
        ("id", "Indonesian"),
        ("hi", "Hindi"),
        ("th", "Thai"),
        ("vi", "Vietnamese"),
    ]

    /// Display labels for the editable translation window. Keep the provider's
    /// supported codes unchanged, but show each language in its own language.
    static let menuLanguages: [(code: String, name: String)] = {
        let pinnedCodes = ["zh-CN", "en"]
        let pinned = pinnedCodes.compactMap { code in
            availableLanguages.first(where: { $0.code == code }).map {
                (code: $0.code, name: LanguageManager.displayName(forTranslationCode: $0.code))
            }
        }
        let others = availableLanguages
            .filter { !pinnedCodes.contains($0.code) }
            .map { (code: $0.code, name: LanguageManager.displayName(forTranslationCode: $0.code)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return pinned + others
    }()

    // MARK: - Translate a batch of strings (auto-detect source)

    /// Translates multiple strings using the selected provider.
    /// Calls completion on the main queue.
    static func translateBatch(
        texts: [String],
        sourceLang: String? = nil,
        targetLang: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard !texts.isEmpty else {
            completion(.success([]))
            return
        }

        switch provider {
        case .google:
            translateBatchGoogle(texts: texts, targetLang: targetLang, completion: completion)
        case .apple:
            if #available(macOS 15.0, *) {
                translateBatchApple(
                    texts: texts,
                    sourceLang: sourceLang,
                    targetLang: targetLang,
                    completion: completion)
            } else {
                completion(.failure(TranslationError.appleTranslation(
                    "Apple Translation requires macOS 15 or later."
                )))
            }
        }
    }

    // MARK: - Google Translate (unofficial endpoint)

    private static func translateBatchGoogle(
        texts: [String],
        targetLang: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard googleTranslationAllowed else {
            DispatchQueue.main.async {
                completion(.failure(TranslationError.googleTranslationDisabled))
            }
            return
        }

        var results = Array(repeating: "", count: texts.count)
        let group = DispatchGroup()
        var firstError: Error?
        let lock = NSLock()

        for (i, text) in texts.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                results[i] = text
                continue
            }
            group.enter()
            translateOneGoogle(text: trimmed, targetLang: targetLang) { result in
                lock.lock()
                switch result {
                case .success(let translated):
                    results[i] = translated
                case .failure(let error):
                    if firstError == nil { firstError = error }
                    results[i] = ""
                }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            if let error = firstError {
                completion(.failure(error))
            } else {
                completion(.success(results))
            }
        }
    }

    private static func translateOneGoogle(
        text: String,
        targetLang: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let request: URLRequest
        do {
            request = try makeGoogleRequest(text: text, targetLang: targetLang)
        } catch {
            completion(.failure(error))
            return
        }

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(TranslationError.noData))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let outer = json.first as? [[Any]] else {
                completion(.failure(TranslationError.parseError))
                return
            }
            let translated = outer.compactMap { $0.first as? String }.joined()
            guard !translated.isEmpty else {
                completion(.failure(TranslationError.emptyResult))
                return
            }
            completion(.success(translated))
        }.resume()
    }

    /// Builds the Google request only after the privacy preference has been checked.
    /// Keeping this seam separate lets callers prove that disabled mode cannot create
    /// a URL containing user text and leaves room for future provider transports.
    static func makeGoogleRequest(text: String, targetLang: String) throws -> URLRequest {
        guard googleTranslationAllowed else {
            throw TranslationError.googleTranslationDisabled
        }

        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl",     value: "auto"),
            URLQueryItem(name: "tl",     value: targetLang),
            URLQueryItem(name: "dt",     value: "t"),
            URLQueryItem(name: "q",      value: text),
        ]
        guard let url = components.url else {
            throw TranslationError.badURL
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        return request
    }

    // MARK: - Apple Translation (macOS 15.0+ via SwiftUI bridge)

    @available(macOS 15.0, *)
    private static func translateBatchApple(
        texts: [String],
        sourceLang: String?,
        targetLang: String,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        guard let sourceLang, !sourceLang.isEmpty, sourceLang != "auto" else {
            DispatchQueue.main.async {
                completion(.failure(TranslationError.appleTranslation(
                    NSLocalizedString(
                        "Could not determine the source language.",
                        comment: "Apple translation source language detection failed"))))
            }
            return
        }
        if sourceLang == targetLang {
            DispatchQueue.main.async { completion(.success(texts)) }
            return
        }
        let source = appleLocale(from: sourceLang)
        let target = appleLocale(from: targetLang)
        checkAppleLanguagePairAvailability(source: source, target: target) { status in
            switch status {
            case .installed:
                let config = TranslationSession.Configuration(source: source, target: target)
                Task { @MainActor in
                    TranslationBridge.shared.translate(
                        texts: texts, configuration: config, completion: completion)
                }
            case .supported:
                let sourceName = languageDisplayName(sourceLang)
                let targetName = languageDisplayName(targetLang)
                completion(.failure(TranslationError.appleTranslation(String(
                    format: NSLocalizedString(
                        "Apple translation needs the %@ → %@ language pack. Download it in System Settings.",
                        comment: "Apple translation language pack download required"),
                    sourceName, targetName))))
            case .unsupported:
                completion(.failure(TranslationError.appleTranslation(String(
                    format: NSLocalizedString(
                        "Apple translation does not support %@ → %@.",
                        comment: "Unsupported Apple translation language pair"),
                    languageDisplayName(sourceLang), languageDisplayName(targetLang)))))
            @unknown default:
                completion(.failure(TranslationError.appleTranslation(
                    NSLocalizedString(
                        "Apple translation language availability is unknown.",
                        comment: "Unknown Apple translation language availability"))))
            }
        }
    }

    @available(macOS 15.0, *)
    private static func checkAppleLanguagePairAvailability(
        source: Locale.Language,
        target: Locale.Language,
        completion: @escaping (LanguageAvailability.Status) -> Void
    ) {
        Task {
            let status = await LanguageAvailability().status(from: source, to: target)
            await MainActor.run { completion(status) }
        }
    }

    private static func languageDisplayName(_ code: String) -> String {
        guard let name = availableLanguages.first(where: { $0.code == code })?.name else {
            return code
        }
        return NSLocalizedString(name, comment: "Translation language name")
    }

    /// Map our language codes to Apple's Locale.Language.
    @available(macOS 15.0, *)
    private static func appleLocale(from code: String) -> Locale.Language {
        switch code {
        case "zh-CN": return Locale.Language(identifier: "zh-Hans")
        case "zh-TW": return Locale.Language(identifier: "zh-Hant")
        case "nb":    return Locale.Language(identifier: "no")
        default:      return Locale.Language(identifier: code)
        }
    }
}

// MARK: - SwiftUI bridge for Apple Translation

/// Uses a hidden SwiftUI view with .translationTask() to obtain a TranslationSession.
/// This is the supported way to use the Translation framework from AppKit.
@available(macOS 15.0, *)
@MainActor
final class TranslationBridge: ObservableObject {
    static let shared = TranslationBridge()

    @Published var config: TranslationSession.Configuration?
    private var hostingView: NSView?
    private var pendingTexts: [String] = []
    private var pendingCompletion: ((Result<[String], Error>) -> Void)?

    private var translationID: UUID?

    func translate(
        texts: [String],
        configuration: TranslationSession.Configuration,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        // Cancel any in-flight translation before starting a new one
        if pendingCompletion != nil {
            cleanup()
        }

        let thisID = UUID()
        translationID = thisID
        pendingTexts = texts
        pendingCompletion = completion

        // Create hidden SwiftUI view and attach to a window
        let view = TranslationBridgeView(bridge: self)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: -1, y: -1, width: 1, height: 1)
        if let window = NSApp.windows.first(where: { $0.contentView != nil }) {
            window.contentView?.addSubview(hosting)
        }
        hostingView = hosting

        // Setting config triggers .translationTask
        config = configuration

        // Timeout: if session doesn't respond in 10s, report error
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self = self, self.translationID == thisID, self.pendingCompletion != nil else { return }
            let completion = self.pendingCompletion
            self.cleanup()
            completion?(.failure(TranslationError.appleTranslation("Apple Translation timed out. The language pack may need to be downloaded in System Settings.")))
        }
    }

    fileprivate func sessionReady(_ session: TranslationSession) {
        // Ignore stale sessions from cancelled translations
        guard pendingCompletion != nil else { return }
        let texts = pendingTexts
        let completion = pendingCompletion
        let activeID = translationID
        Task {
            do {
                var results = Array(repeating: "", count: texts.count)
                for (i, text) in texts.enumerated() {
                    // Bail if a new translation was started while we're iterating
                    let stillActive = await MainActor.run { self.translationID == activeID }
                    guard stillActive else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        results[i] = text
                        continue
                    }
                    let response = try await session.translate(trimmed)
                    results[i] = response.targetText
                }
                await MainActor.run {
                    guard self.translationID == activeID else { return }
                    self.cleanup()
                    completion?(.success(results))
                }
            } catch {
                await MainActor.run {
                    guard self.translationID == activeID else { return }
                    self.cleanup()
                    let desc = error.localizedDescription
                    let msg = "Apple Translation failed: \(desc). You can switch to Google Translate in Settings."
                    completion?(.failure(TranslationError.appleTranslation(msg)))
                }
            }
        }
    }

    private func cleanup() {
        hostingView?.removeFromSuperview()
        hostingView = nil
        pendingTexts = []
        pendingCompletion = nil
        config = nil
    }
}

@available(macOS 15.0, *)
private struct TranslationBridgeView: View {
    @ObservedObject var bridge: TranslationBridge

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(bridge.config) { session in
                await MainActor.run {
                    bridge.sessionReady(session)
                }
            }
    }
}

enum TranslationError: LocalizedError {
    case badURL, noData, parseError, emptyResult
    case googleTranslationDisabled
    case appleTranslation(String)
    var errorDescription: String? {
        switch self {
        case .badURL:      return "Invalid translation URL"
        case .noData:      return "No response from translation service"
        case .parseError:  return "Could not parse translation response"
        case .emptyResult: return "Translation returned empty result"
        case .googleTranslationDisabled:
            return NSLocalizedString(
                "Google translation is disabled in Settings.",
                comment: "Google translation privacy setting is disabled"
            )
        case .appleTranslation(let msg): return msg
        }
    }
}
