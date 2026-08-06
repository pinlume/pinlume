import Foundation
import Darwin

/// Shared output boundary for images, videos and GIFs.
/// A target is never deleted before its replacement has been generated and verified.
enum TransactionalOutput {
    struct Failure: Error {
        let temporaryURL: URL
        let underlyingError: Error
    }

    typealias Producer = (URL) throws -> Void
    typealias Validator = (URL) throws -> Void
    typealias Replacer = (URL, URL) throws -> URL?

    /// Atomically claims an unused user-visible name. The zero-byte reservation is
    /// replaced by `commit`; it prevents concurrent default saves from choosing
    /// the same filename.
    static func reserveUnique(in directory: URL, filename: String) throws -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        for index in 1...10_000 {
            let suffix = index == 1 ? "" : " (\(index))"
            let name = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            let url = directory.appendingPathComponent(name)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
            if descriptor >= 0 {
                close(descriptor)
                return url
            }
            if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    static func write(_ data: Data, to destination: URL, reservedDestination: Bool = false) throws {
        try commit(to: destination, reservedDestination: reservedDestination, produce: { temporaryURL in
            try data.write(to: temporaryURL, options: .atomic)
        }, validate: validateNonEmptyFile)
    }

    static func writeBatch(
        _ outputs: [(filename: String, data: Data)],
        to directory: URL
    ) throws -> [URL] {
        var destinations: [URL] = []
        destinations.reserveCapacity(outputs.count)
        do {
            for output in outputs {
                let destination = try reserveUnique(in: directory, filename: output.filename)
                destinations.append(destination)
                try write(output.data, to: destination, reservedDestination: true)
            }
        } catch {
            for destination in destinations {
                try? FileManager.default.removeItem(at: destination)
            }
            throw error
        }
        return destinations
    }

    /// Copies a complete source through the transaction boundary, then removes the
    /// source only after the destination has been validated and atomically committed.
    static func transfer(
        _ source: URL,
        to destination: URL,
        reservedDestination: Bool = false,
        validate: Validator = validateNonEmptyFile
    ) throws {
        if source.standardizedFileURL == destination.standardizedFileURL {
            try validate(source)
            return
        }
        try commit(to: destination, reservedDestination: reservedDestination, produce: { temporaryURL in
            try FileManager.default.copyItem(at: source, to: temporaryURL)
        }, validate: validate)
        try? FileManager.default.removeItem(at: source)
    }

    /// Commits a small data payload to the exact file selected by NSSavePanel.
    /// The staging file stays in the app-private temporary directory because a
    /// sandbox Save As grant does not authorize sibling files beside `destination`.
    static func writeFileScoped(_ data: Data, to destination: URL) throws {
        try commitFileScoped(to: destination, produce: { temporaryURL in
            try data.write(to: temporaryURL, options: .atomic)
        }, validate: validateNonEmptyFile)
    }

    /// Transfers a complete private artifact to the exact file selected by
    /// NSSavePanel, removing the source only after the selected file validates.
    static func transferFileScoped(
        _ source: URL,
        to destination: URL,
        validate: Validator = validateNonEmptyFile
    ) throws {
        if source.standardizedFileURL == destination.standardizedFileURL {
            try validate(source)
            return
        }
        try commitFileScoped(to: destination, produce: { temporaryURL in
            try FileManager.default.copyItem(at: source, to: temporaryURL)
        }, validate: validate)
        try? FileManager.default.removeItem(at: source)
    }

    /// A Save As panel authorizes only its selected file, not the destination
    /// directory. Generate and validate privately, then touch only that file.
    static func commitFileScoped(
        to destination: URL,
        produce: Producer,
        validate: Validator = validateNonEmptyFile
    ) throws {
        let fileManager = FileManager.default
        let temporaryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "pinlume-save-\(UUID().uuidString).\(destination.pathExtension)"
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try produce(temporaryURL)
        try validate(temporaryURL)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        try validate(destination)
    }

    static func commit(
        to destination: URL,
        reservedDestination: Bool = false,
        produce: Producer,
        validate: Validator = validateNonEmptyFile,
        replace: Replacer = { destination, temporaryURL in
            try FileManager.default.replaceItemAt(destination, withItemAt: temporaryURL)
        }
    ) throws {
        let fileManager = FileManager.default
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        let reserved = reservedDestination || !destinationExists
        if !destinationExists {
            _ = try reserveExact(destination)
        }
        let temporaryURL = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).partial-\(UUID().uuidString)"
        )
        do {
            try produce(temporaryURL)
            try validate(temporaryURL)
            _ = try replace(destination, temporaryURL)
        } catch {
            // Keep the fully or partially generated temporary file for recovery.
            // A unique-name reservation is only a zero-byte claim and is safe to release.
            if reserved, (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue == 0 {
                try? fileManager.removeItem(at: destination)
            }
            throw Failure(temporaryURL: temporaryURL, underlyingError: error)
        }
    }

    nonisolated static func validateNonEmptyFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
    }

    private static func reserveExact(_ url: URL) throws -> URL {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        close(descriptor)
        return url
    }
}
