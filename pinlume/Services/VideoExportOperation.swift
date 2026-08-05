import Foundation
import AVFoundation

/// Owns the AVFoundation session, its task and its temporary output for one
/// export. A closed editor cancels this object; it never leaves a writer task
/// or security-scoped directory lease behind.
@MainActor
final class VideoExportOperation {
    enum Failure: LocalizedError {
        case exportFailed(Error?)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .exportFailed(let error): return error?.localizedDescription ?? "Video export failed"
            case .cancelled: return "Video export was cancelled"
            }
        }
    }

    private var lifecycle = VideoExportLifecycle()
    private var exportTask: Task<Void, Never>?
    private var exportSession: AVAssetExportSession?
    private var temporaryURL: URL?
    private var targetURL: URL?
    private var reservedTarget = false
    private var scopedDirectory: URL?
    private var cancellation = VideoExportCancellation()
    private var completion: ((Result<URL, Error>) -> Void)?
    private var afterWorkerStops: (() -> Void)?

    func start(
        session: AVAssetExportSession,
        temporaryURL: URL,
        targetURL: URL? = nil,
        reservedTarget: Bool = false,
        scopedDirectory: URL? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard lifecycle.begin() else { return }
        self.exportSession = session
        self.temporaryURL = temporaryURL
        self.targetURL = targetURL
        self.reservedTarget = reservedTarget
        self.scopedDirectory = scopedDirectory
        self.completion = completion
        cancellation.register { session.cancelExport() }

        exportTask = Task { [self] in
            await session.export()
            finish(session.status == .completed ? .success(temporaryURL) : .failure(Failure.exportFailed(session.error)))
        }
    }

    /// Owns callback-based AVAssetReader/Writer and GIF work with the same
    /// lifecycle as AVAssetExportSession. The worker must always invoke its
    /// callback; duplicate callbacks are collapsed before resuming the Task.
    func startExternal(
        temporaryURL: URL,
        targetURL: URL? = nil,
        reservedTarget: Bool = false,
        scopedDirectory: URL? = nil,
        work: @escaping (
            VideoExportCancellation,
            @escaping (Result<URL, Error>) -> Void
        ) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard lifecycle.begin() else { return }
        self.temporaryURL = temporaryURL
        self.targetURL = targetURL
        self.reservedTarget = reservedTarget
        self.scopedDirectory = scopedDirectory
        self.completion = completion
        let cancellation = cancellation

        exportTask = Task { [self] in
            let result: Result<URL, Error> = await withCheckedContinuation { continuation in
                let gate = CallbackGate { continuation.resume(returning: $0) }
                work(cancellation) { gate.finish($0) }
            }
            finish(result)
        }
    }

    /// Cancels without delivering UI work. Source cleanup is delayed until the
    /// reader/writer has acknowledged cancellation and can no longer touch it.
    @discardableResult
    func cancelAndCleanup(afterWorkerStops: (() -> Void)? = nil) -> Bool {
        guard lifecycle.cancelOnce() else { return false }
        completion = nil
        self.afterWorkerStops = afterWorkerStops
        cancellation.cancel()
        exportTask?.cancel()
        exportSession?.cancelExport()
        return true
    }

    private func finish(_ result: Result<URL, Error>) {
        if lifecycle.finishOnce() {
            if case .failure = result {
                cleanupTemporaryFile()
                cleanupReservedTarget()
            }
            let completion = completion
            completion?(result)
            releaseScopedDirectory()
            clearOperation()
            return
        }
        guard lifecycle.finishCancellationOnce() else { return }
        cleanupTemporaryFile()
        cleanupReservedTarget()
        releaseScopedDirectory()
        let sourceCleanup = afterWorkerStops
        clearOperation()
        sourceCleanup?()
    }

    private func cleanupTemporaryFile() {
        if let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
    }

    private func releaseScopedDirectory() {
        if let scopedDirectory { SaveDirectoryAccess.stopAccessing(url: scopedDirectory) }
        scopedDirectory = nil
    }

    private func cleanupReservedTarget() {
        guard reservedTarget, let targetURL,
              let size = try? FileManager.default.attributesOfItem(atPath: targetURL.path)[.size] as? NSNumber,
              size.intValue == 0 else { return }
        try? FileManager.default.removeItem(at: targetURL)
    }

    private func clearOperation() {
        exportTask = nil
        exportSession = nil
        temporaryURL = nil
        targetURL = nil
        reservedTarget = false
        completion = nil
        afterWorkerStops = nil
    }
}

private final class CallbackGate {
    private let lock = NSLock()
    private var completed = false
    private let completion: (Result<URL, Error>) -> Void

    init(completion: @escaping (Result<URL, Error>) -> Void) {
        self.completion = completion
    }

    func finish(_ result: Result<URL, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        completion(result)
    }
}
