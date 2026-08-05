import Cocoa

struct HistoryEntry {
    let id: String           // UUID filename (without extension)
    let fileExtension: String // "png" or "jpg"
    let timestamp: Date       // creation time
    /// Last time the entry was edited & saved from the editor (nil = never).
    var lastEditedAt: Date? = nil
    var pixelWidth: Int
    var pixelHeight: Int
    var hasAnnotations: Bool = false  // true if editable raw data is saved alongside
    var thumbnail: NSImage?  // lazily cached, tiny

    /// The time used for "order by last edit": the most recent of edit/creation.
    var effectiveSortDate: Date { lastEditedAt ?? timestamp }

    var timeAgoString: String {
        let seconds = Int(-timestamp.timeIntervalSinceNow)
        if seconds < 5 { return L("just now") }
        if seconds < 60 { return String(format: L("%ds ago"), seconds) }
        let minutes = seconds / 60
        if minutes < 60 { return String(format: L("%dm ago"), minutes) }
        let hours = minutes / 60
        if hours < 24 { return String(format: L("%dh ago"), hours) }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: timestamp)
    }
}

class ScreenshotHistory {

    static let shared = ScreenshotHistory()

    private(set) var entries: [HistoryEntry] = []

    private let historyDir: URL
    private let indexStore: ScreenshotHistoryIndexStore
    private let historyIOQueue = DispatchQueue(label: "com.xiegang.Pinlume.history-io", qos: .utility)
    private var writeGeneration = 0
    private let artifactLifecycle = HistoryArtifactLifecycle()

    var maxEntries: Int {
        if UserDefaults.standard.bool(forKey: "historyUnlimited") { return Int.max }
        if let stored = UserDefaults.standard.object(forKey: "historySize") as? Int {
            return stored
        }
        return 10  // default
    }

    private init() {
        historyDir = AppIdentity.applicationSupportDirectory
            .appendingPathComponent("history", isDirectory: true)
        indexStore = ScreenshotHistoryIndexStore(historyDirectory: historyDir)

        // Startup can quarantine a corrupt index and atomically write a rebuilt
        // one. Keep those mutations on the same serial boundary as every later
        // history artifact/index write and delete. `sync` preserves the existing
        // invariant that entries are ready before the singleton is published.
        let startup = historyIOQueue.sync { [historyDir, indexStore] in
            if !FileManager.default.fileExists(atPath: historyDir.path) {
                try? FileManager.default.createDirectory(
                    at: historyDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            return indexStore.prepareForStartup()
        }
        loadIndex(startup.entries, applyingRetentionPolicy: startup.state == .valid)
        if startup.shouldPruneOrphanedFiles {
            pruneOrphanedFiles()
        }
    }

    /// Delete files in the history directory that aren't referenced by
    /// any entry in `index.json`. Catches orphans from past bugs where a
    /// `_preview.png` / `_raw.png` / `_annotations.json` was written but
    /// never cleaned up. Runs once at startup off the main thread via
    /// the shared `DirectorySweeper` helper.
    private func pruneOrphanedFiles() {
        let dir = historyDir
        let validIDs = Set(entries.map { $0.id })
        historyIOQueue.async {
            DirectorySweeper.sweep(
                directory: dir,
                // No age filter — orphan detection is by UUID-prefix
                // lookup against `index.json`, not mtime.
                olderThan: nil,
                shouldDelete: { name in
                    self.indexStore.isOrphanedArtifact(named: name, validIDs: validIDs)
                }
            )
        }
    }

    // MARK: - Public API

    /// Add a screenshot to history.
    /// - Parameters:
    ///   - image: The composited image (annotations baked in) used for display, clipboard, and sharing.
    ///   - rawImage: The raw screenshot without annotations (optional — for editable history).
    ///   - annotations: Live annotation objects (optional — serialized to JSON for editable history).
    ///   - editState: Live post-processing settings (optional — serialized for non-destructive editing).
    func add(image: NSImage, rawImage: NSImage? = nil, annotations: [Annotation]? = nil, editState: CaptureEditState? = nil) {
        let max = maxEntries
        guard max > 0 else { return }

        let id = UUID().uuidString
        let ext = "png"

        // Capture metadata on main thread (cheap)
        let size = image.size
        let pixelSize = ImageEncoder.pixelSize(of: image)

        let hasAnns = annotations != nil && !(annotations!.isEmpty)
        let hasEditState = editState?.hasPostProcessing == true
        let hasEditableData = rawImage != nil && (hasAnns || hasEditState)

        // Create entry with a placeholder thumbnail (tiny, fast)
        let entry = HistoryEntry(
            id: id,
            fileExtension: ext,
            timestamp: Date(),
            pixelWidth: pixelSize?.width ?? Int(size.width),
            pixelHeight: pixelSize?.height ?? Int(size.height),
            hasAnnotations: hasEditableData,
            thumbnail: NSImage(size: NSSize(width: 1, height: 1))
        )
        entries.insert(entry, at: 0)

        // Prune oldest entries beyond max
        while entries.count > max {
            let removed = entries.removeLast()
            deleteFiles(for: removed.id, ext: removed.fileExtension)
        }

        // Serialize annotations on main thread (fast — just JSON encoding)
        let annotationData: Data? = hasAnns ? AnnotationSerializer.encode(annotations!) : nil
        let editStateData: Data? = {
            guard hasEditState, let editState else { return nil }
            return try? JSONEncoder().encode(editState)
        }()

        // Move all expensive work off main thread: thumbnail, preview, PNG encoding, index save
        let fileURL = historyDir.appendingPathComponent("\(id).\(ext)")
        let thumbURL = historyDir.appendingPathComponent("\(id)_thumb.png")
        let previewURL = historyDir.appendingPathComponent("\(id)_preview.png")
        let rawURL = historyDir.appendingPathComponent("\(id)_raw.png")
        let annURL = historyDir.appendingPathComponent("\(id)_annotations.json")
        let editURL = historyDir.appendingPathComponent("\(id)_edit.json")
        let generation = writeGeneration
        let artifactGeneration = artifactLifecycle.beginWrite(for: id)
        historyIOQueue.async { [weak self] in
            guard let self = self else { return }
            let thumb = self.makeThumbnail(image: image, maxWidth: 36)
            let preview = self.makePreview(image: image)

            // Briefly hold the thumbnail in memory so the menu bar can render
            // it before the disk write lands. Cleared once the disk file is
            // safely on-disk — subsequent reads go through loadThumbnail's
            // disk path so we don't pin every entry's bitmap forever.
            DispatchQueue.main.async {
                guard self.writeGeneration == generation,
                      self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                if let idx = self.entries.firstIndex(where: { $0.id == id }) {
                    self.entries[idx].thumbnail = thumb
                }
                self.saveIndex()
            }

            guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
            // Write composited image
            if let imageData = ImageEncoder.encodePNGPreservingSourcePixels(image) {
                guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                try? imageData.write(to: fileURL, options: .atomic)
            }
            if let thumbPng = ImageEncoder.encodePNGPreservingSourcePixels(thumb) {
                guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                try? thumbPng.write(to: thumbURL, options: .atomic)
            }
            if let prevPng = ImageEncoder.encodePNGPreservingSourcePixels(preview) {
                guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                try? prevPng.write(to: previewURL, options: .atomic)
            }

            // Write raw image + annotations if available
            if let raw = rawImage,
               let rawData = ImageEncoder.encodePNGPreservingSourcePixels(raw) {
                guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                try? rawData.write(to: rawURL, options: .atomic)
            }
            if let annData = annotationData {
                guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                try? annData.write(to: annURL, options: .atomic)
            }
            if let editData = editStateData {
                guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                try? editData.write(to: editURL, options: .atomic)
            }

            // Disk artifacts are now on disk — drop the in-memory thumbnail.
            // loadThumbnail() will read from disk on next access.
            DispatchQueue.main.async {
                guard self.writeGeneration == generation,
                      self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                if let idx = self.entries.firstIndex(where: { $0.id == id }) {
                    self.entries[idx].thumbnail = nil
                }
            }
        }
    }

    /// Update an existing history entry in-place (for "Done" in editor).
    /// Rewrites the composited image, raw image, annotations, thumbnail, and preview.
    /// Whether the history panel orders entries by last-edit time (default on).
    /// When off, entries stay in creation order (newest created first).
    static var orderByLastEdit: Bool {
        UserDefaults.standard.object(forKey: "historyOrderByLastEdit") as? Bool ?? true
    }

    /// Re-sort `entries` to honor the current ordering preference. When ordering
    /// by last edit, sort by the most recent of edit/creation, descending. When
    /// off, restore creation order (newest first). Stable for equal dates.
    func applyHistoryOrderPreference(persist: Bool = false) {
        if Self.orderByLastEdit {
            entries.sort { $0.effectiveSortDate > $1.effectiveSortDate }
        } else {
            entries.sort { $0.timestamp > $1.timestamp }
        }
        if persist { saveIndex() }
    }

    func updateEntry(id: String, compositedImage: NSImage, rawImage: NSImage?, annotations: [Annotation]?, editState: CaptureEditState? = nil) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }

        let hasAnns = annotations != nil && !(annotations!.isEmpty)
        let hasEditState = editState?.hasPostProcessing == true
        let hasEditableData = rawImage != nil && (hasAnns || hasEditState)
        entries[idx].hasAnnotations = hasEditableData
        // Stamp the edit time (used for last-edit ordering). The actual reorder
        // happens at the end, after all entries[idx] field updates, so the index
        // stays valid here.
        entries[idx].lastEditedAt = Date()
        if let pixelSize = ImageEncoder.pixelSize(of: compositedImage) {
            entries[idx].pixelWidth = pixelSize.width
            entries[idx].pixelHeight = pixelSize.height
        }

        let annotationData: Data? = hasAnns ? AnnotationSerializer.encode(annotations!) : nil
        let editStateData: Data? = {
            guard hasEditState, let editState else { return nil }
            return try? JSONEncoder().encode(editState)
        }()

        let ext = entries[idx].fileExtension
        let fileURL = historyDir.appendingPathComponent("\(id).\(ext)")
        let thumbURL = historyDir.appendingPathComponent("\(id)_thumb.png")
        let previewURL = historyDir.appendingPathComponent("\(id)_preview.png")
        let rawURL = historyDir.appendingPathComponent("\(id)_raw.png")
        let annURL = historyDir.appendingPathComponent("\(id)_annotations.json")
        let editURL = historyDir.appendingPathComponent("\(id)_edit.json")
        let generation = writeGeneration
        let artifactGeneration = artifactLifecycle.beginWrite(for: id)

        // Update thumbnail in memory immediately
        let thumb = makeThumbnail(image: compositedImage, maxWidth: 36)
        entries[idx].thumbnail = thumb
        // When ordering by last edit, float the just-edited entry to the top.
        if Self.orderByLastEdit, idx != 0 {
            let edited = entries.remove(at: idx)
            entries.insert(edited, at: 0)
        }

        historyIOQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
            // Composited image
            if let data = ImageEncoder.encodePNGPreservingSourcePixels(compositedImage) {
                guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                try? data.write(to: fileURL, options: .atomic)
            }
            // Thumbnail + preview
            if let thumbPng = ImageEncoder.encodePNGPreservingSourcePixels(thumb) {
                guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                try? thumbPng.write(to: thumbURL, options: .atomic)
            }
            let preview = self.makePreview(image: compositedImage)
            if let prevPng = ImageEncoder.encodePNGPreservingSourcePixels(preview) {
                guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                try? prevPng.write(to: previewURL, options: .atomic)
            }
            // Raw image + annotations
            if let raw = rawImage,
               let rawData = ImageEncoder.encodePNGPreservingSourcePixels(raw) {
                guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                try? rawData.write(to: rawURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: rawURL)
            }
            if let annData = annotationData {
                guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                try? annData.write(to: annURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: annURL)
            }
            if let editData = editStateData {
                guard self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                try? editData.write(to: editURL, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: editURL)
            }

            // Disk artifacts updated — drop the in-memory thumbnail so the
            // next read pulls the fresh on-disk version through loadThumbnail.
            DispatchQueue.main.async {
                guard self.writeGeneration == generation,
                      self.artifactLifecycle.isLive(id: id, generation: artifactGeneration) else { return }
                if let idx = self.entries.firstIndex(where: { $0.id == id }) {
                    self.entries[idx].thumbnail = nil
                }
                self.saveIndex()
            }
        }
    }

    func pruneToMax() {
        let max = maxEntries
        if max <= 0 {
            clear()
        } else {
            while entries.count > max {
                let removed = entries.removeLast()
                deleteFiles(for: removed.id, ext: removed.fileExtension)
            }
            saveIndex()
        }
    }

    func removeEntry(id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        artifactLifecycle.tombstone(entry.id)
        deleteFiles(for: entry.id, ext: entry.fileExtension)
        saveIndex()
    }

    func clear(completion: @escaping () -> Void = {}) {
        writeGeneration &+= 1
        entries.forEach { artifactLifecycle.tombstone($0.id) }
        entries.removeAll()
        let directory = historyDir
        historyIOQueue.async {
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            ) else {
                DispatchQueue.main.async(execute: completion)
                return
            }
            contents.forEach { try? FileManager.default.removeItem(at: $0) }
            DispatchQueue.main.async(execute: completion)
        }
    }

    func copyEntry(at index: Int) {
        guard index >= 0, index < entries.count else { return }
        let entry = entries[index]
        let fileURL = historyDir.appendingPathComponent("\(entry.id).\(entry.fileExtension)")
        guard let imageData = try? Data(contentsOf: fileURL),
              let image = NSImage(data: imageData) else { return }
        ImageEncoder.copyToClipboard(image, sourceFileURL: fileURL)
    }

    func loadImage(for entry: HistoryEntry) -> NSImage? {
        let fileURL = historyDir.appendingPathComponent("\(entry.id).\(entry.fileExtension)")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return NSImage(data: data)
    }

    func fileURL(for entry: HistoryEntry) -> URL {
        historyDir.appendingPathComponent("\(entry.id).\(entry.fileExtension)")
    }

    /// Load the raw (un-annotated) screenshot for editable history entries.
    func loadRawImage(for entry: HistoryEntry) -> NSImage? {
        guard entry.hasAnnotations else { return nil }
        let rawURL = historyDir.appendingPathComponent("\(entry.id)_raw.png")
        guard let data = try? Data(contentsOf: rawURL) else { return nil }
        return NSImage(data: data)
    }

    /// Load saved annotations for editable history entries.
    func loadAnnotations(for entry: HistoryEntry) -> [Annotation]? {
        guard entry.hasAnnotations else { return nil }
        let annURL = historyDir.appendingPathComponent("\(entry.id)_annotations.json")
        guard let data = try? Data(contentsOf: annURL) else { return [] }
        return AnnotationSerializer.decode(data)
    }

    /// Load saved post-processing settings for editable history entries.
    func loadEditState(for entry: HistoryEntry) -> CaptureEditState? {
        guard entry.hasAnnotations else { return nil }
        let editURL = historyDir.appendingPathComponent("\(entry.id)_edit.json")
        guard let data = try? Data(contentsOf: editURL) else { return nil }
        return try? JSONDecoder().decode(CaptureEditState.self, from: data)
    }

    func loadThumbnail(for entry: HistoryEntry) -> NSImage? {
        if let thumb = entry.thumbnail { return thumb }
        let thumbURL = historyDir.appendingPathComponent("\(entry.id)_thumb.png")
        return NSImage(contentsOf: thumbURL)
    }

    /// Load a mid-size preview suitable for history panel cards (~240pt wide).
    /// Falls back to disk thumbnail scaled up, or full image if needed.
    func loadPreview(for entry: HistoryEntry) -> NSImage? {
        // Try preview file first
        let previewURL = historyDir.appendingPathComponent("\(entry.id)_preview.png")
        if let preview = NSImage(contentsOf: previewURL) { return preview }

        // Fall back to full image, scaled down
        guard let full = loadImage(for: entry) else { return nil }
        return makePreview(image: full)
    }

    private func makePreview(image: NSImage, maxDimension: CGFloat = 240) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1.0)
        let previewSize = NSSize(width: round(size.width * scale), height: round(size.height * scale))
        let preview = NSImage(size: previewSize, flipped: false) { _ in
            image.draw(in: NSRect(origin: .zero, size: previewSize), from: .zero, operation: .copy, fraction: 1.0)
            return true
        }
        return preview
    }

    // MARK: - Persistence

    private func saveIndex() {
        let indexEntries = entries.map {
            ScreenshotHistoryIndexEntry(id: $0.id, fileExtension: $0.fileExtension, timestamp: $0.timestamp,
                                        pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                                        hasAnnotations: $0.hasAnnotations ? true : nil,
                                        lastEditedAt: $0.lastEditedAt)
        }
        historyIOQueue.async { [indexStore] in _ = indexStore.save(indexEntries) }
    }

    private func loadIndex(_ indexEntries: [ScreenshotHistoryIndexEntry], applyingRetentionPolicy: Bool) {
        entries = indexEntries.compactMap { ie in
            // Only include entries whose image file still exists
            let ext = ie.fileExtension
            let fileURL = historyDir.appendingPathComponent("\(ie.id).\(ext)")
            guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
            return HistoryEntry(id: ie.id, fileExtension: ext, timestamp: ie.timestamp, lastEditedAt: ie.lastEditedAt, pixelWidth: ie.pixelWidth, pixelHeight: ie.pixelHeight, hasAnnotations: ie.hasAnnotations ?? false, thumbnail: nil)
        }

        // Apply the persisted ordering preference on load so the panel reflects
        // it immediately (when off, this is a no-op — array stays creation-order).
        applyHistoryOrderPreference()

        // Retention deletes user files, so it only runs after the index was
        // successfully verified. A recovered/corrupt index is preserved intact.
        guard applyingRetentionPolicy else { return }
        let max = maxEntries
        if max <= 0 {
            clear()
        } else {
            while entries.count > max {
                let removed = entries.removeLast()
                deleteFiles(for: removed.id, ext: removed.fileExtension)
            }
            if entries.count < indexEntries.count {
                saveIndex()
            }
        }
    }

    // MARK: - File helpers

    private func deleteFiles(for id: String, ext: String = "png") {
        artifactLifecycle.tombstone(id)
        let fileURL = historyDir.appendingPathComponent("\(id).\(ext)")
        let thumbURL = historyDir.appendingPathComponent("\(id)_thumb.png")
        let previewURL = historyDir.appendingPathComponent("\(id)_preview.png")
        let rawURL = historyDir.appendingPathComponent("\(id)_raw.png")
        let annURL = historyDir.appendingPathComponent("\(id)_annotations.json")
        let editURL = historyDir.appendingPathComponent("\(id)_edit.json")
        historyIOQueue.async {
            let fm = FileManager.default
            [fileURL, thumbURL, previewURL, rawURL, annURL, editURL].forEach { try? fm.removeItem(at: $0) }
        }
    }

    private func makeThumbnail(image: NSImage, maxWidth: CGFloat) -> NSImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(maxWidth / size.width, maxWidth / size.height)
        let thumbSize = NSSize(width: size.width * scale, height: size.height * scale)
        let thumb = NSImage(size: thumbSize, flipped: false) { _ in
            image.draw(in: NSRect(origin: .zero, size: thumbSize), from: .zero, operation: .copy, fraction: 1.0)
            return true
        }
        return thumb
    }
}
