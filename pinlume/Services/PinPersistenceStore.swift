import Cocoa

struct CodableRect: Codable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ rect: NSRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var nsRect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
}

struct CodablePoint: Codable, Equatable {
    let x: CGFloat
    let y: CGFloat

    init(_ point: NSPoint) {
        x = point.x
        y = point.y
    }

    var nsPoint: NSPoint { NSPoint(x: x, y: y) }
}

struct PersistedTranslationPinState: Codable {
    let originalImagePNG: Data?
    let translatedImagePNG: Data?
    let originalImageFileName: String?
    let translatedImageFileName: String?
    let translatedBlocks: [TranslatedTextBlock]
    let originalBlocks: [RecognizedTextBlock]
    let translatedSelectionBlocks: [RecognizedTextBlock]
    let sourceLanguage: String
    let targetLanguage: String
    let displayMode: ScreenTranslationSession.DisplayMode

    init(
        originalImagePNG: Data?, translatedImagePNG: Data?,
        originalImageFileName: String? = nil, translatedImageFileName: String? = nil,
        translatedBlocks: [TranslatedTextBlock],
        originalBlocks: [RecognizedTextBlock] = [],
        translatedSelectionBlocks: [RecognizedTextBlock] = [],
        sourceLanguage: String,
        targetLanguage: String, displayMode: ScreenTranslationSession.DisplayMode
    ) {
        self.originalImagePNG = originalImagePNG
        self.translatedImagePNG = translatedImagePNG
        self.originalImageFileName = originalImageFileName
        self.translatedImageFileName = translatedImageFileName
        self.translatedBlocks = translatedBlocks
        self.originalBlocks = originalBlocks
        self.translatedSelectionBlocks = translatedSelectionBlocks
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.displayMode = displayMode
    }

    private enum CodingKeys: String, CodingKey {
        case originalImageFileName, translatedImageFileName, translatedBlocks
        case originalBlocks, translatedSelectionBlocks
        case sourceLanguage, targetLanguage, displayMode
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        originalImagePNG = nil
        translatedImagePNG = nil
        originalImageFileName = try values.decodeIfPresent(String.self, forKey: .originalImageFileName)
        translatedImageFileName = try values.decodeIfPresent(String.self, forKey: .translatedImageFileName)
        translatedBlocks = try values.decode([TranslatedTextBlock].self, forKey: .translatedBlocks)
        originalBlocks = try values.decodeIfPresent(
            [RecognizedTextBlock].self, forKey: .originalBlocks) ?? translatedBlocks.map(\.block)
        translatedSelectionBlocks = try values.decodeIfPresent(
            [RecognizedTextBlock].self, forKey: .translatedSelectionBlocks) ?? []
        sourceLanguage = try values.decode(String.self, forKey: .sourceLanguage)
        targetLanguage = try values.decode(String.self, forKey: .targetLanguage)
        displayMode = try values.decodeIfPresent(
            ScreenTranslationSession.DisplayMode.self, forKey: .displayMode) ?? .translated
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(originalImageFileName, forKey: .originalImageFileName)
        try values.encodeIfPresent(translatedImageFileName, forKey: .translatedImageFileName)
        try values.encode(translatedBlocks, forKey: .translatedBlocks)
        if !originalBlocks.isEmpty { try values.encode(originalBlocks, forKey: .originalBlocks) }
        if !translatedSelectionBlocks.isEmpty {
            try values.encode(translatedSelectionBlocks, forKey: .translatedSelectionBlocks)
        }
        try values.encode(sourceLanguage, forKey: .sourceLanguage)
        try values.encode(targetLanguage, forKey: .targetLanguage)
        try values.encode(displayMode, forKey: .displayMode)
    }
}

enum PersistedPinKind: String, Codable {
    case ordinary
    case ocr
    case translation
}

struct PersistedPinRecord: Codable {
    let imagePNG: Data?
    let imageFileName: String?
    let visualFrame: CodableRect
    let normalVisualFrame: CodableRect?
    let compactCenter: CodablePoint?
    let compactActualCenter: CodablePoint?
    let isCompact: Bool?
    let shadowHidden: Bool
    let opacity: CGFloat
    let textContent: String?
    let translationState: PersistedTranslationPinState?
    let pinKind: PersistedPinKind
    let ocrBlocks: [RecognizedTextBlock]

    init(
        imagePNG: Data?,
        imageFileName: String? = nil,
        visualFrame: CodableRect,
        normalVisualFrame: CodableRect?,
        compactCenter: CodablePoint?,
        compactActualCenter: CodablePoint?,
        isCompact: Bool?,
        shadowHidden: Bool,
        opacity: CGFloat,
        textContent: String?,
        translationState: PersistedTranslationPinState? = nil,
        pinKind: PersistedPinKind = .ordinary,
        ocrBlocks: [RecognizedTextBlock] = []
    ) {
        self.imagePNG = imagePNG
        self.imageFileName = imageFileName
        self.visualFrame = visualFrame
        self.normalVisualFrame = normalVisualFrame
        self.compactCenter = compactCenter
        self.compactActualCenter = compactActualCenter
        self.isCompact = isCompact
        self.shadowHidden = shadowHidden
        self.opacity = opacity
        self.textContent = textContent
        self.translationState = translationState
        self.pinKind = translationState == nil ? pinKind : .translation
        self.ocrBlocks = ocrBlocks
    }

    private enum CodingKeys: String, CodingKey {
        case imagePNG, imageFileName, visualFrame, normalVisualFrame, compactCenter
        case compactActualCenter, isCompact, shadowHidden, opacity, textContent, translationState
        case pinKind, ocrBlocks
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        imagePNG = try values.decodeIfPresent(Data.self, forKey: .imagePNG)
        imageFileName = try values.decodeIfPresent(String.self, forKey: .imageFileName)
        visualFrame = try values.decode(CodableRect.self, forKey: .visualFrame)
        normalVisualFrame = try values.decodeIfPresent(CodableRect.self, forKey: .normalVisualFrame)
        compactCenter = try values.decodeIfPresent(CodablePoint.self, forKey: .compactCenter)
        compactActualCenter = try values.decodeIfPresent(CodablePoint.self, forKey: .compactActualCenter)
        isCompact = try values.decodeIfPresent(Bool.self, forKey: .isCompact)
        shadowHidden = try values.decode(Bool.self, forKey: .shadowHidden)
        opacity = try values.decode(CGFloat.self, forKey: .opacity)
        textContent = try values.decodeIfPresent(String.self, forKey: .textContent)
        translationState = try values.decodeIfPresent(PersistedTranslationPinState.self, forKey: .translationState)
        pinKind = try values.decodeIfPresent(PersistedPinKind.self, forKey: .pinKind)
            ?? (translationState == nil ? .ordinary : .translation)
        ocrBlocks = try values.decodeIfPresent(
            [RecognizedTextBlock].self, forKey: .ocrBlocks) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(imageFileName, forKey: .imageFileName)
        try values.encode(visualFrame, forKey: .visualFrame)
        try values.encodeIfPresent(normalVisualFrame, forKey: .normalVisualFrame)
        try values.encodeIfPresent(compactCenter, forKey: .compactCenter)
        try values.encodeIfPresent(compactActualCenter, forKey: .compactActualCenter)
        try values.encodeIfPresent(isCompact, forKey: .isCompact)
        try values.encode(shadowHidden, forKey: .shadowHidden)
        try values.encode(opacity, forKey: .opacity)
        try values.encodeIfPresent(textContent, forKey: .textContent)
        try values.encodeIfPresent(translationState, forKey: .translationState)
        if pinKind != .ordinary { try values.encode(pinKind, forKey: .pinKind) }
        if !ocrBlocks.isEmpty { try values.encode(ocrBlocks, forKey: .ocrBlocks) }
    }
}

enum PinPersistenceStore {
    private static let productionDirectory: URL = {
        let dir = AppIdentity.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }()

    static func load() -> [PersistedPinRecord] { load(from: productionDirectory) }

    static func save(_ records: [PersistedPinRecord]) { save(records, to: productionDirectory) }

    static func clear() { clear(at: productionDirectory) }

    static func load(from directory: URL) -> [PersistedPinRecord] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("pins.json")),
              let records = try? JSONDecoder().decode([PersistedPinRecord].self, from: data) else { return [] }

        let migrated = records.enumerated().compactMap { index, record -> PersistedPinRecord? in
            let translation = loadedTranslationState(record.translationState, from: directory)
            if record.translationState != nil && translation == nil { return nil }
            if let imagePNG = record.imagePNG {
                return recordWithImage(record, data: imagePNG,
                    fileName: "pin-\(index)-\(UUID().uuidString).png", translationState: translation)
            }
            guard let fileName = safeImageFileName(record.imageFileName),
                  let imageData = try? Data(contentsOf: imagesDirectory(for: directory).appendingPathComponent(fileName)) else {
                return nil
            }
            return recordWithImage(record, data: imageData, fileName: fileName, translationState: translation)
        }

        if records.contains(where: { $0.imagePNG != nil }) {
            save(migrated, to: directory)
        }
        return migrated
    }

    static func save(_ records: [PersistedPinRecord], to directory: URL) {
        let fileManager = FileManager.default
        let imagesDirectory = imagesDirectory(for: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let prepared = records.enumerated().compactMap { index, record -> PersistedPinRecord? in
            guard let imageData = record.imagePNG else { return nil }
            let fileName = safeImageFileName(record.imageFileName) ?? "pin-\(index)-\(UUID().uuidString).png"
            guard safeImageFileName(fileName) != nil else { return nil }
            do {
                try imageData.write(to: imagesDirectory.appendingPathComponent(fileName), options: .atomic)
                let translation = try preparedTranslationState(
                    record.translationState, recordIndex: index, imagesDirectory: imagesDirectory)
                return recordWithImage(record, data: nil, fileName: fileName, translationState: translation)
            } catch {
                return nil
            }
        }

        // An index is committed only after every new image is safely written.
        guard prepared.count == records.count,
              let indexData = try? JSONEncoder().encode(prepared),
              (try? indexData.write(to: directory.appendingPathComponent("pins.json"), options: .atomic)) != nil else { return }

        let referenced = Set(prepared.flatMap { record in
            [record.imageFileName, record.translationState?.originalImageFileName,
             record.translationState?.translatedImageFileName].compactMap { $0 }
        })
        let oldImages = (try? fileManager.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil)) ?? []
        for url in oldImages where url.pathExtension.lowercased() == "png" && !referenced.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    static func clear(at directory: URL) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("pins.json"))
        try? FileManager.default.removeItem(at: imagesDirectory(for: directory))
    }

    private static func imagesDirectory(for directory: URL) -> URL {
        directory.appendingPathComponent("images", isDirectory: true)
    }

    static func safeImageFileName(_ fileName: String?) -> String? {
        guard let fileName,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              fileName.lowercased().hasSuffix(".png"),
              !fileName.isEmpty else { return nil }
        return fileName
    }

    private static func loadedTranslationState(
        _ state: PersistedTranslationPinState?, from directory: URL
    ) -> PersistedTranslationPinState? {
        guard let state else { return nil }
        guard let originalName = safeImageFileName(state.originalImageFileName),
              let translatedName = safeImageFileName(state.translatedImageFileName),
              let originalData = try? Data(contentsOf: imagesDirectory(for: directory).appendingPathComponent(originalName)),
              let translatedData = try? Data(contentsOf: imagesDirectory(for: directory).appendingPathComponent(translatedName))
        else { return nil }
        return PersistedTranslationPinState(
            originalImagePNG: originalData, translatedImagePNG: translatedData,
            originalImageFileName: originalName, translatedImageFileName: translatedName,
            translatedBlocks: state.translatedBlocks,
            originalBlocks: state.originalBlocks,
            translatedSelectionBlocks: state.translatedSelectionBlocks,
            sourceLanguage: state.sourceLanguage,
            targetLanguage: state.targetLanguage, displayMode: state.displayMode)
    }

    private static func preparedTranslationState(
        _ state: PersistedTranslationPinState?, recordIndex: Int, imagesDirectory: URL
    ) throws -> PersistedTranslationPinState? {
        guard let state else { return nil }
        guard let originalData = state.originalImagePNG,
              let translatedData = state.translatedImagePNG else {
            throw CocoaError(.fileWriteUnknown)
        }
        let originalName = safeImageFileName(state.originalImageFileName)
            ?? "pin-\(recordIndex)-original-\(UUID().uuidString).png"
        let translatedName = safeImageFileName(state.translatedImageFileName)
            ?? "pin-\(recordIndex)-translated-\(UUID().uuidString).png"
        try originalData.write(to: imagesDirectory.appendingPathComponent(originalName), options: .atomic)
        try translatedData.write(to: imagesDirectory.appendingPathComponent(translatedName), options: .atomic)
        return PersistedTranslationPinState(
            originalImagePNG: nil, translatedImagePNG: nil,
            originalImageFileName: originalName, translatedImageFileName: translatedName,
            translatedBlocks: state.translatedBlocks,
            originalBlocks: state.originalBlocks,
            translatedSelectionBlocks: state.translatedSelectionBlocks,
            sourceLanguage: state.sourceLanguage,
            targetLanguage: state.targetLanguage, displayMode: state.displayMode)
    }

    private static func recordWithImage(
        _ record: PersistedPinRecord, data: Data?, fileName: String,
        translationState: PersistedTranslationPinState?
    ) -> PersistedPinRecord {
        PersistedPinRecord(
            imagePNG: data,
            imageFileName: fileName,
            visualFrame: record.visualFrame,
            normalVisualFrame: record.normalVisualFrame,
            compactCenter: record.compactCenter,
            compactActualCenter: record.compactActualCenter,
            isCompact: record.isCompact,
            shadowHidden: record.shadowHidden,
            opacity: record.opacity,
            textContent: record.textContent,
            translationState: translationState,
            pinKind: record.pinKind,
            ocrBlocks: record.ocrBlocks
        )
    }
}
