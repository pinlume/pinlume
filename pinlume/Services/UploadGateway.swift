#if !OFFLINE
import Cocoa

@MainActor
enum UploadConfirmation {
    static let preferenceKey = "uploadConfirmEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: preferenceKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    static func confirmIfNeeded(presentingWindow: NSWindow?) -> Bool {
        guard isEnabled else { return true }
        let provider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
        let title = provider == "gdrive" ? L("Upload to Google Drive?")
            : provider == "s3" ? L("Upload to S3?") : L("Upload to imgbb.com?")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = L("Your screenshot will be uploaded.")
        alert.addButton(withTitle: L("Upload"))
        alert.addButton(withTitle: L("Cancel"))
        alert.alertStyle = .informational
        let level = presentingWindow?.level
        presentingWindow?.level = .normal
        let response = alert.runModal()
        if let level { presentingWindow?.level = level }
        return response == .alertFirstButtonReturn
    }
}

@MainActor
final class UploadGateway {
    static let shared = UploadGateway()

    struct Result {
        let link: String
        let deleteURL: String
    }

    enum Payload {
        case image(NSImage)
        case video(URL)
    }

    typealias Progress = (Double) -> Void
    typealias Completion = (Swift.Result<Result, Error>) -> Void

    private init() {}

    /// Settings uses the same transport boundary as capture UI. The payload is
    /// fixed diagnostic text, so the explicit Test Connection click is the
    /// consent action and does not need the screenshot upload confirmation.
    func testS3Connection(completion: @escaping (Swift.Result<Void, Error>) -> Void) {
        guard S3Uploader.shared.isConfigured else {
            completion(.failure(Self.error("S3 not configured — check Settings")))
            return
        }
        let data = Data("Pinlume connection test".utf8)
        let filename = ".pinlume_test_\(UUID().uuidString.prefix(8)).txt"
        S3Uploader.shared.upload(
            data: data,
            filename: filename,
            contentType: "text/plain"
        ) { result in
            completion(result.map { _ in () })
        }
    }

    /// The only UI-facing network gate. A cancelled confirmation returns before
    /// provider validation or a transport call, so rejected uploads issue zero requests.
    @discardableResult
    func upload(
        _ payload: Payload,
        presentingWindow: NSWindow? = nil,
        onStart: (() -> Void)? = nil,
        onProgress: Progress? = nil,
        completion: @escaping Completion
    ) -> Bool {
        guard UploadConfirmation.confirmIfNeeded(presentingWindow: presentingWindow) else { return false }
        let provider = UserDefaults.standard.string(forKey: "uploadProvider") ?? "imgbb"
        guard provider != "gdrive" || GoogleDriveUploader.shared.isSignedIn else {
            completion(.failure(Self.error("Google Drive not signed in")))
            return false
        }
        guard provider != "s3" || S3Uploader.shared.isConfigured else {
            completion(.failure(Self.error("S3 not configured — check Settings")))
            return false
        }
        guard !(payload.isVideo && provider == "imgbb") else {
            completion(.failure(Self.error("Video upload requires Google Drive or S3")))
            return false
        }

        onStart?()
        switch (provider, payload) {
        case ("gdrive", .image(let image)):
            GoogleDriveUploader.shared.onProgress = onProgress
            GoogleDriveUploader.shared.uploadImage(image) { result in
                completion(result.map { Result(link: $0, deleteURL: "") })
            }
        case ("gdrive", .video(let url)):
            GoogleDriveUploader.shared.onProgress = onProgress
            GoogleDriveUploader.shared.uploadVideo(url: url) { result in
                completion(result.map { Result(link: $0, deleteURL: "") })
            }
        case ("s3", .image(let image)):
            S3Uploader.shared.onProgress = onProgress
            S3Uploader.shared.uploadImage(image) { result in
                completion(result.map { Result(link: $0, deleteURL: "") })
            }
        case ("s3", .video(let url)):
            S3Uploader.shared.onProgress = onProgress
            S3Uploader.shared.uploadVideo(url: url) { result in
                completion(result.map { Result(link: $0, deleteURL: "") })
            }
        case (_, .image(let image)):
            ImageUploader.upload(image: image) { result in
                completion(result.map { Result(link: $0.link, deleteURL: $0.deleteURL) })
            }
        default:
            completion(.failure(Self.error("Unsupported upload payload")))
        }
        return true
    }

    static func performAfterConfirmation(_ confirmed: Bool, transport: () -> Void) -> Bool {
        UploadGatewayGate.performAfterConfirmation(confirmed, transport: transport)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "UploadGateway", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension UploadGateway.Payload {
    var isVideo: Bool {
        if case .video = self { return true }
        return false
    }
}
#endif
