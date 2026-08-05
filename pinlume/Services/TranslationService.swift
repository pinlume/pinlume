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
    static let googleMaximumEncodedRequestBytes = 16_000

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
    @discardableResult
    static func translateBatch(
        texts: [String],
        sourceLang: String? = nil,
        targetLang: String,
        progress: ((Int, String) -> Void)? = nil,
        completion: @escaping (Result<[String], Error>) -> Void
    ) -> TranslationRequestHandle {
        let gate = TranslationCompletionGate(completion)
        let finish: (Result<[String], Error>) -> Void = { result in
            DispatchQueue.main.async { gate.finish(result) }
        }
        guard !texts.isEmpty else {
            finish(.success([]))
            return TranslationRequestHandle()
        }

        switch provider {
        case .google:
            return translateBatchGoogle(
                texts: texts,
                targetLang: targetLang,
                progress: progress,
                completion: finish)
        case .apple:
            if #available(macOS 15.0, *) {
                return translateBatchApple(
                    texts: texts,
                    sourceLang: sourceLang,
                    targetLang: targetLang,
                    progress: progress,
                    completion: finish)
            } else {
                finish(.failure(TranslationError.appleTranslation(
                    NSLocalizedString(
                        "Apple Translation requires macOS 15 or later.",
                        comment: "Apple Translation availability"
                    )
                )))
                return TranslationRequestHandle()
            }
        }
    }

    // MARK: - Google Translate (unofficial endpoint)

    private static func translateBatchGoogle(
        texts: [String],
        targetLang: String,
        progress: ((Int, String) -> Void)?,
        completion: @escaping (Result<[String], Error>) -> Void
    ) -> TranslationRequestHandle {
        let handle = TranslationRequestHandle()
        guard googleTranslationAllowed else {
            DispatchQueue.main.async {
                completion(.failure(TranslationError.googleTranslationDisabled))
            }
            return handle
        }
        let operation = GoogleBatchOperation(
            texts: texts,
            targetLanguage: targetLang,
            progress: progress,
            completion: completion)
        handle.registerCancellation { operation.cancel() }
        operation.start { handle.finish() }
        return handle
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
        progress: ((Int, String) -> Void)?,
        completion: @escaping (Result<[String], Error>) -> Void
    ) -> TranslationRequestHandle {
        let handle = TranslationRequestHandle()
        guard let sourceLang, !sourceLang.isEmpty, sourceLang != "auto" else {
            DispatchQueue.main.async {
                completion(.failure(TranslationError.appleTranslation(
                    NSLocalizedString(
                        "Could not determine the source language.",
                        comment: "Apple translation source language detection failed"))))
            }
            return handle
        }
        if sourceLang == targetLang {
            DispatchQueue.main.async { completion(.success(texts)) }
            return handle
        }
        let source = appleLocale(from: sourceLang)
        let target = appleLocale(from: targetLang)
        checkAppleLanguagePairAvailability(source: source, target: target) { status in
            guard !handle.isCancelled else { return }
            switch status {
            case .installed:
                startInstalledTranslation(
                    texts: texts,
                    source: source,
                    target: target,
                    progress: progress,
                    completion: completion,
                    handle: handle)
            case .supported:
                Task { @MainActor in
                    let configuration = TranslationSession.Configuration(
                        source: source, target: target)
                    let requestID = TranslationBridge.shared.prepare(
                        configuration: configuration) { result in
                            guard !handle.isCancelled else { return }
                            switch result {
                            case .success:
                                checkAppleLanguagePairAvailability(
                                    source: source, target: target) { installedStatus in
                                        guard !handle.isCancelled else { return }
                                        guard installedStatus == .installed else {
                                            completion(.failure(
                                                TranslationError.appleLanguageDownloadDidNotFinish))
                                            return
                                        }
                                        startInstalledTranslation(
                                            texts: texts,
                                            source: source,
                                            target: target,
                                            progress: progress,
                                            completion: completion,
                                            handle: handle)
                                    }
                            case .failure(let error):
                                completion(.failure(error))
                            }
                        }
                    handle.registerCancellation {
                        Task { @MainActor in
                            TranslationBridge.shared.cancel(requestID: requestID)
                        }
                    }
                }
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
        return handle
    }

    @available(macOS 15.0, *)
    private static func startInstalledTranslation(
        texts: [String],
        source: Locale.Language,
        target: Locale.Language,
        progress: ((Int, String) -> Void)?,
        completion: @escaping (Result<[String], Error>) -> Void,
        handle: TranslationRequestHandle
    ) {
        guard !handle.isCancelled else { return }
        Task { @MainActor in
            let configuration = TranslationSession.Configuration(source: source, target: target)
            let requestID = TranslationBridge.shared.translateInstalled(
                texts: texts,
                configuration: configuration,
                progress: progress) { result in
                    guard !handle.isCancelled else { return }
                    handle.finish()
                    completion(result)
                }
            handle.registerCancellation {
                Task { @MainActor in
                    TranslationBridge.shared.cancel(requestID: requestID)
                }
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

private final class GoogleBatchOperation: @unchecked Sendable {
    private let texts: [String]
    private let targetLanguage: String
    private let progress: ((Int, String) -> Void)?
    private let completion: (Result<[String], Error>) -> Void
    private let lock = NSLock()
    private var results: [String]
    private var nextIndex = 0
    private var currentTask: URLSessionDataTask?
    private var cancelled = false
    private var finished = false
    private var onFinish: (() -> Void)?

    init(
        texts: [String],
        targetLanguage: String,
        progress: ((Int, String) -> Void)?,
        completion: @escaping (Result<[String], Error>) -> Void
    ) {
        self.texts = texts
        self.targetLanguage = targetLanguage
        self.progress = progress
        self.completion = completion
        results = Array(repeating: "", count: texts.count)
    }

    func start(onFinish: @escaping () -> Void) {
        lock.lock()
        self.onFinish = onFinish
        lock.unlock()
        advance()
    }

    func cancel() {
        lock.lock()
        guard !cancelled, !finished else {
            lock.unlock()
            return
        }
        cancelled = true
        currentTask?.cancel()
        currentTask = nil
        onFinish = nil
        lock.unlock()
    }

    private func advance() {
        lock.lock()
        guard !cancelled, !finished else {
            lock.unlock()
            return
        }
        while nextIndex < texts.count,
              texts[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results[nextIndex] = texts[nextIndex]
            nextIndex += 1
        }
        guard nextIndex < texts.count else {
            let completedResults = results
            lock.unlock()
            finish(.success(completedResults))
            return
        }
        let index = nextIndex
        let text = texts[index].trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()

        let request: URLRequest
        do {
            request = try TranslationService.makeGoogleRequest(text: text, targetLang: targetLanguage)
            guard (request.url?.absoluteString.utf8.count ?? Int.max)
                    <= TranslationService.googleMaximumEncodedRequestBytes else {
                finish(.failure(TranslationError.googleTextTooLong))
                return
            }
        } catch {
            finish(.failure(error))
            return
        }
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            self?.receive(data: data, response: response, error: error, index: index)
        }
        lock.lock()
        guard !cancelled, !finished else {
            lock.unlock()
            task.cancel()
            return
        }
        currentTask = task
        lock.unlock()
        task.resume()
    }

    private func receive(data: Data?, response: URLResponse?, error: Error?, index: Int) {
        lock.lock()
        currentTask = nil
        let shouldIgnore = cancelled || finished || index != nextIndex
        lock.unlock()
        guard !shouldIgnore else { return }
        if let error {
            finish(.failure(error))
            return
        }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            finish(.failure(TranslationError.httpStatus(
                (response as? HTTPURLResponse)?.statusCode ?? -1)))
            return
        }
        guard let data else {
            finish(.failure(TranslationError.noData))
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let outer = json.first as? [[Any]] else {
            finish(.failure(TranslationError.parseError))
            return
        }
        let translated = outer.compactMap { $0.first as? String }.joined()
        guard !translated.isEmpty else {
            finish(.failure(TranslationError.emptyResult))
            return
        }
        lock.lock()
        guard !cancelled, !finished, index == nextIndex else {
            lock.unlock()
            return
        }
        results[index] = translated
        nextIndex += 1
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.progress?(index, translated) }
        advance()
    }

    private func finish(_ result: Result<[String], Error>) {
        lock.lock()
        guard !cancelled, !finished else {
            lock.unlock()
            return
        }
        finished = true
        currentTask = nil
        let finishAction = onFinish
        onFinish = nil
        lock.unlock()
        DispatchQueue.main.async { [completion] in
            finishAction?()
            completion(result)
        }
    }
}

// MARK: - SwiftUI bridge for Apple Translation

/// Uses a hidden SwiftUI view with .translationTask() to obtain a TranslationSession.
/// This is the supported way to use the Translation framework from AppKit.
@available(macOS 15.0, *)
@MainActor
final class TranslationBridge {
    static let shared = TranslationBridge()

    private enum Operation {
        case prepare((Result<Void, Error>) -> Void)
        case translate(
            texts: [String],
            progress: ((Int, String) -> Void)?,
            completion: (Result<[String], Error>) -> Void)
    }

    private var hostingView: NSView?
    private var operation: Operation?
    private var requestID: UUID?
    private var timeout: DispatchWorkItem?
    private weak var hostWindow: NSWindow?
    private var hostWindowOriginalLevel: NSWindow.Level?

    func prepare(
        configuration: TranslationSession.Configuration,
        completion: @escaping (Result<Void, Error>) -> Void
    ) -> UUID {
        begin(
            operation: .prepare(completion),
            configuration: configuration,
            timeoutInterval: 40,
            lowersOverlay: true)
    }

    func translateInstalled(
        texts: [String],
        configuration: TranslationSession.Configuration,
        progress: ((Int, String) -> Void)?,
        completion: @escaping (Result<[String], Error>) -> Void
    ) -> UUID {
        begin(
            operation: .translate(
                texts: texts, progress: progress, completion: completion),
            configuration: configuration,
            timeoutInterval: 10,
            lowersOverlay: false)
    }

    func cancel(requestID: UUID) {
        guard self.requestID == requestID else { return }
        cleanup()
    }

    private func begin(
        operation: Operation,
        configuration: TranslationSession.Configuration,
        timeoutInterval: TimeInterval,
        lowersOverlay: Bool
    ) -> UUID {
        cleanup()
        let newRequestID = UUID()
        requestID = newRequestID
        self.operation = operation

        let view = TranslationBridgeView(
            bridge: self,
            requestID: newRequestID,
            configuration: configuration)
        let hosting = NSHostingView(rootView: view)
        if let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
           let contentView = window.contentView {
            hostWindow = window
            if lowersOverlay,
               window.level.rawValue >= NSWindow.Level.screenSaver.rawValue {
                hostWindowOriginalLevel = window.level
                window.level = .normal
            }
            hosting.frame = NSRect(
                x: contentView.bounds.midX - 0.5,
                y: contentView.bounds.midY - 0.5,
                width: 1,
                height: 1)
            hosting.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            contentView.addSubview(hosting)
        }
        hostingView = hosting

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.requestID == newRequestID else { return }
            let activeOperation = self.operation
            self.cleanup()
            switch activeOperation {
            case .prepare(let completion):
                completion(.failure(TranslationError.appleLanguageDownloadTimedOut))
            case .translate(_, _, let completion):
                completion(.failure(TranslationError.appleSessionTimedOut))
            case nil:
                break
            }
        }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + timeoutInterval,
            execute: timeout)
        return newRequestID
    }

    fileprivate func sessionReady(
        _ session: TranslationSession,
        requestID: UUID
    ) async {
        guard self.requestID == requestID, let operation else { return }
        timeout?.cancel()
        timeout = nil
        do {
            switch operation {
            case .prepare(let completion):
                try await session.prepareTranslation()
                guard self.requestID == requestID, !Task.isCancelled else { return }
                cleanup()
                completion(.success(()))
            case .translate(let texts, let progress, let completion):
                var results = Array(repeating: "", count: texts.count)
                for (i, text) in texts.enumerated() {
                    guard self.requestID == requestID, !Task.isCancelled else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        results[i] = text
                        continue
                    }
                    let response = try await session.translate(trimmed)
                    results[i] = response.targetText
                    progress?(i, response.targetText)
                }
                guard self.requestID == requestID else { return }
                cleanup()
                completion(.success(results))
            }
        } catch {
            guard self.requestID == requestID else { return }
            let activeOperation = self.operation
            cleanup()
            let wrapped = TranslationError.appleTranslation(String(
                format: NSLocalizedString(
                    "Apple Translation failed: %@",
                    comment: "Apple Translation failure with system detail"),
                error.localizedDescription))
            switch activeOperation {
            case .prepare(let completion):
                completion(.failure(wrapped))
            case .translate(_, _, let completion):
                completion(.failure(wrapped))
            case nil:
                break
            }
        }
    }

    private func cleanup() {
        requestID = nil
        timeout?.cancel()
        timeout = nil
        hostingView?.removeFromSuperview()
        hostingView = nil
        restoreHostWindowLevel()
        hostWindow = nil
        operation = nil
    }

    private func restoreHostWindowLevel() {
        if let window = hostWindow, let originalLevel = hostWindowOriginalLevel {
            window.level = originalLevel
        }
        hostWindowOriginalLevel = nil
    }
}

@available(macOS 15.0, *)
private struct TranslationBridgeView: View {
    let bridge: TranslationBridge
    let requestID: UUID
    let configuration: TranslationSession.Configuration

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(configuration) { session in
                await bridge.sessionReady(session, requestID: requestID)
            }
    }
}

enum TranslationError: LocalizedError {
    case badURL, noData, parseError, emptyResult, cancelled
    case googleTranslationDisabled
    case googleTextTooLong
    case httpStatus(Int)
    case appleLanguageDownloadTimedOut
    case appleLanguageDownloadDidNotFinish
    case appleSessionTimedOut
    case appleTranslation(String)
    var errorDescription: String? {
        switch self {
        case .badURL:
            return NSLocalizedString(
                "Invalid translation URL", comment: "Translation URL error")
        case .noData:
            return NSLocalizedString(
                "No response from translation service", comment: "Empty translation response")
        case .parseError:
            return NSLocalizedString(
                "Could not parse translation response", comment: "Translation parse error")
        case .emptyResult:
            return NSLocalizedString(
                "Translation returned empty result", comment: "Empty translated text")
        case .cancelled:
            return NSLocalizedString(
                "Translation request was superseded", comment: "Superseded translation request")
        case .googleTranslationDisabled:
            return NSLocalizedString(
                "Google translation is disabled in Settings.",
                comment: "Google translation privacy setting is disabled"
            )
        case .googleTextTooLong:
            return NSLocalizedString(
                "The text exceeds Google Translate's single-request limit. Shorten it and try again.",
                comment: "Google translation encoded request is too long")
        case .httpStatus(let statusCode):
            return String(
                format: NSLocalizedString(
                    "Google Translate returned HTTP error %d.",
                    comment: "Google translation HTTP status error"),
                statusCode)
        case .appleLanguageDownloadTimedOut:
            return NSLocalizedString(
                "Apple language download timed out. The download may continue in System Settings.",
                comment: "Apple language preparation timeout")
        case .appleLanguageDownloadDidNotFinish:
            return NSLocalizedString(
                "Apple language download did not finish. Please try again after the download completes.",
                comment: "Apple language preparation did not install resources")
        case .appleSessionTimedOut:
            return NSLocalizedString(
                "Apple Translation timed out. Please try again.",
                comment: "Apple Translation session startup timeout")
        case .appleTranslation(let msg): return msg
        }
    }
}
