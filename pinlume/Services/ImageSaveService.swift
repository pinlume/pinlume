import Cocoa
import os.log

private let imageSaveLog = OSLog(subsystem: AppIdentity.bundleIdentifier, category: "Pinlume-save")

enum SaveActionPreference: Int, CaseIterable {
    case saveToFolder = 0
    case askWhereToSave = 1

    static let userDefaultsKey = "saveAction"

    static var current: SaveActionPreference {
        get {
            guard UserDefaults.standard.object(forKey: userDefaultsKey) != nil else {
                return .saveToFolder
            }
            return SaveActionPreference(rawValue: UserDefaults.standard.integer(forKey: userDefaultsKey)) ?? .saveToFolder
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
        }
    }

    var title: String {
        switch self {
        case .saveToFolder:
            return L("Save to default folder")
        case .askWhereToSave:
            return L("Ask where to save")
        }
    }
}

enum ImageSaveService {
    typealias Completion = (Bool) -> Void

    private static let manualSaveDirectoryPathKey = "manualSaveDirectory"
    private static let manualSaveDirectoryBookmarkKey = "manualSaveDirectoryBookmark"
    private static let manualSaveFormatKey = "manualSaveImageFormat"

    static func save(
        _ image: NSImage,
        using action: SaveActionPreference = .current,
        windowTitle: String? = nil,
        panelLevel: NSWindow.Level? = nil,
        sheetWindow: NSWindow? = nil,
        activateApp: Bool = true,
        completion: Completion? = nil
    ) {
        switch action {
        case .saveToFolder:
            saveToConfiguredFolder(
                image,
                windowTitle: windowTitle,
                panelLevel: panelLevel,
                sheetWindow: sheetWindow,
                activateApp: activateApp,
                completion: completion)
        case .askWhereToSave:
            showSavePanel(
                for: image,
                windowTitle: windowTitle,
                panelLevel: panelLevel,
                sheetWindow: sheetWindow,
                activateApp: activateApp,
                completion: completion)
        }
    }

    static func saveToConfiguredFolder(
        _ image: NSImage,
        windowTitle: String? = nil,
        panelLevel: NSWindow.Level? = nil,
        sheetWindow: NSWindow? = nil,
        activateApp: Bool = true,
        completion: Completion? = nil
    ) {
        let filename = defaultFilename(windowTitle: windowTitle)
        if let dirURL = SaveDirectoryAccess.resolveIfAccessible() {
            writeImage(image, toDirectory: dirURL, filename: filename, securityScoped: true, completion: completion)
            return
        }

        requestSaveDirectoryAccess(
            panelLevel: panelLevel,
            sheetWindow: sheetWindow,
            activateApp: activateApp
        ) { dirURL, securityScoped in
            writeImage(image, toDirectory: dirURL, filename: filename, securityScoped: securityScoped, completion: completion)
        } cancellation: {
            completionOnMain(completion, false)
        }
    }

    static func showSavePanel(
        for image: NSImage,
        suggestedFilename: String? = nil,
        windowTitle: String? = nil,
        panelLevel: NSWindow.Level? = nil,
        sheetWindow: NSWindow? = nil,
        preferredScreen: NSScreen? = nil,
        activateApp: Bool = true,
        completion: Completion? = nil
    ) {
        showSavePanel(
            imageProvider: { image },
            suggestedFilename: suggestedFilename,
            windowTitle: windowTitle,
            panelLevel: panelLevel,
            sheetWindow: sheetWindow,
            preferredScreen: preferredScreen,
            activateApp: activateApp,
            completion: completion
        )
    }

    static func showSavePanel(
        imageProvider: @escaping () -> NSImage?,
        suggestedFilename: String? = nil,
        windowTitle: String? = nil,
        panelLevel: NSWindow.Level? = nil,
        sheetWindow: NSWindow? = nil,
        preferredScreen: NSScreen? = nil,
        activateApp: Bool = true,
        completion: Completion? = nil
    ) {
        let initialFormat = lastManualSaveFormat()
        let requestStart = CFAbsoluteTimeGetCurrent()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ImageEncoder.utType(for: initialFormat)]
        panel.nameFieldStringValue = filename(
            suggestedFilename ?? defaultFilename(windowTitle: windowTitle),
            withFormat: initialFormat
        )
        panel.directoryURL = manualSaveDirectoryHint() ?? SaveDirectoryAccess.directoryHint()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        if let panelLevel {
            panel.level = panelLevel
        }
        let formatController = SavePanelFormatController(panel: panel, initialFormat: initialFormat)
        panel.accessoryView = formatController.view

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            let selectedFormat = formatController.selectedFormat
            os_log(
                "save panel response=%{public}ld elapsed=%.3f format=%{public}@",
                log: imageSaveLog,
                type: .info,
                response.rawValue,
                CFAbsoluteTimeGetCurrent() - requestStart,
                selectedFormat.rawValue
            )
            guard response == .OK,
                  let rawURL = panel.url
            else {
                completionOnMain(completion, false)
                return
            }
            let imageStart = CFAbsoluteTimeGetCurrent()
            guard let image = imageProvider() else {
                os_log("save image provider failed", log: imageSaveLog, type: .error)
                completionOnMain(completion, false)
                return
            }
            os_log(
                "save image provider done elapsed=%.3f size=%.0fx%.0f",
                log: imageSaveLog,
                type: .info,
                CFAbsoluteTimeGetCurrent() - imageStart,
                Double(image.size.width),
                Double(image.size.height)
            )
            let url = url(rawURL, withFormat: selectedFormat)
            saveManualDefaults(directory: url.deletingLastPathComponent(), format: selectedFormat)
            DispatchQueue.global(qos: .userInitiated).async {
                let encodeStart = CFAbsoluteTimeGetCurrent()
                guard let imageData = ImageEncoder.encode(image, format: selectedFormat) else {
                    os_log("save encode failed", log: imageSaveLog, type: .error)
                    completionOnMain(completion, false)
                    return
                }
                do {
                    try TransactionalOutput.write(imageData, to: url)
                    os_log(
                        "save write success elapsed=%.3f bytes=%{public}d",
                        log: imageSaveLog,
                        type: .info,
                        CFAbsoluteTimeGetCurrent() - encodeStart,
                        imageData.count
                    )
                    completionOnMain(completion, true)
                } catch {
                    #if DEBUG
                    NSLog("Pinlume: failed to save screenshot to \(url.path): \(error.localizedDescription)")
                    #endif
                    reportWriteFailure(error)
                    completionOnMain(completion, false)
                }
            }
        }

        os_log("save panel present", log: imageSaveLog, type: .info)
        presentPanel(
            panel,
            sheetWindow: sheetWindow,
            preferredScreen: preferredScreen,
            activateApp: activateApp,
            completionHandler: handler
        )
    }

    private static func defaultFilename(windowTitle: String?) -> String {
        let template = UserDefaults.standard.string(forKey: FilenameFormatter.userDefaultsKey) ?? FilenameFormatter.defaultTemplate
        let base = FilenameFormatter.format(template: template, windowTitle: windowTitle)
        return "\(base).\(ImageEncoder.fileExtension)"
    }

    private static func filename(_ filename: String, withFormat format: ImageEncoder.Format) -> String {
        let base = (filename as NSString).deletingPathExtension
        return "\(base).\(ImageEncoder.fileExtension(for: format))"
    }

    fileprivate static func url(_ url: URL, withFormat format: ImageEncoder.Format) -> URL {
        let expectedExtension = ImageEncoder.fileExtension(for: format)
        guard url.pathExtension.lowercased() != expectedExtension else { return url }
        return url.deletingPathExtension().appendingPathExtension(expectedExtension)
    }

    fileprivate static func lastManualSaveFormat() -> ImageEncoder.Format {
        if let raw = UserDefaults.standard.string(forKey: manualSaveFormatKey),
           let format = ImageEncoder.Format(rawValue: raw),
           ImageEncoder.isFormatAvailable(format) {
            return format
        }
        return ImageEncoder.format
    }

    private static func manualSaveDirectoryHint() -> URL? {
        if let path = UserDefaults.standard.string(forKey: manualSaveDirectoryPathKey) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func saveManualDefaults(directory: URL, format: ImageEncoder.Format) {
        UserDefaults.standard.set(format.rawValue, forKey: manualSaveFormatKey)
        UserDefaults.standard.set(format.rawValue, forKey: "imageFormat")
        UserDefaults.standard.set(directory.path, forKey: manualSaveDirectoryPathKey)
        if let bookmark = try? directory.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: manualSaveDirectoryBookmarkKey)
        }
    }

    private static func writeImage(
        _ image: NSImage,
        toDirectory dirURL: URL,
        filename: String,
        securityScoped: Bool,
        completion: Completion?
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            defer { if securityScoped { SaveDirectoryAccess.stopAccessing(url: dirURL) } }
            guard let imageData = ImageEncoder.encode(image) else {
                completionOnMain(completion, false)
                return
            }

            do {
                let fileURL = try TransactionalOutput.reserveUnique(in: dirURL, filename: filename)
                try TransactionalOutput.write(imageData, to: fileURL, reservedDestination: true)
                completionOnMain(completion, true)
            } catch {
                #if DEBUG
                NSLog("Pinlume: failed to save screenshot to \(dirURL.appendingPathComponent(filename).path): \(error.localizedDescription)")
                #endif
                reportWriteFailure(error)
                completionOnMain(completion, false)
            }
        }
    }

    private static func requestSaveDirectoryAccess(
        panelLevel: NSWindow.Level?,
        sheetWindow: NSWindow?,
        activateApp: Bool,
        completion: @escaping (URL, Bool) -> Void,
        cancellation: @escaping () -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = L("Choose a folder")
        panel.directoryURL = SaveDirectoryAccess.directoryHint()
        if let panelLevel {
            panel.level = panelLevel
        }

        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else {
                cancellation()
                return
            }
            SaveDirectoryAccess.save(url: url)
            if let scopedURL = SaveDirectoryAccess.resolveIfAccessible() {
                completion(scopedURL, true)
                return
            }
            let securityScoped = url.startAccessingSecurityScopedResource()
            completion(url, securityScoped)
        }

        presentPanel(panel, sheetWindow: sheetWindow, activateApp: activateApp, completionHandler: handler)
    }

    private static func presentPanel(
        _ panel: NSSavePanel,
        sheetWindow: NSWindow?,
        preferredScreen: NSScreen? = nil,
        activateApp: Bool,
        completionHandler: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if activateApp {
            NSApp.activate(ignoringOtherApps: true)
        }

        DispatchQueue.main.async {
            if activateApp {
                NSApp.activate(ignoringOtherApps: true)
            }
            if let sheetWindow {
                let frame = sheetWindow.frame
                os_log(
                    "save panel begin sheet hostFrame=(%.0f,%.0f %.0fx%.0f)",
                    log: imageSaveLog,
                    type: .info,
                    frame.origin.x,
                    frame.origin.y,
                    frame.width,
                    frame.height
                )
                panel.beginSheetModal(for: sheetWindow, completionHandler: completionHandler)
            } else {
                positionPanel(panel, on: preferredScreen)
                panel.begin(completionHandler: completionHandler)
            }
        }
    }

    private static func positionPanel(_ panel: NSSavePanel, on screen: NSScreen?) {
        guard let screen else { return }
        let visibleFrame = screen.visibleFrame
        let size = panel.frame.size
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        let origin = NSPoint(
            x: min(max(visibleFrame.midX - size.width / 2, visibleFrame.minX), maxX),
            y: min(max(visibleFrame.midY - size.height / 2, visibleFrame.minY), maxY)
        )
        panel.setFrameOrigin(origin)
    }

    private static func reportWriteFailure(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert(error: error)
            alert.messageText = L("Save failed")
            alert.runModal()
        }
    }

    private static func completionOnMain(_ completion: Completion?, _ success: Bool) {
        guard let completion else { return }
        DispatchQueue.main.async {
            completion(success)
        }
    }
}

private final class SavePanelFormatController: NSObject {
    let view: NSView
    private weak var panel: NSSavePanel?
    private let popup: NSPopUpButton
    private let formats: [ImageEncoder.Format]

    var selectedFormat: ImageEncoder.Format {
        let index = popup.indexOfSelectedItem
        guard formats.indices.contains(index) else { return ImageEncoder.format }
        return formats[index]
    }

    init(panel: NSSavePanel, initialFormat: ImageEncoder.Format) {
        self.panel = panel
        self.formats = ImageEncoder.availableFormats
        self.popup = NSPopUpButton(frame: .zero, pullsDown: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 32))
        self.view = container
        super.init()

        popup.frame = NSRect(x: 35, y: 2, width: 190, height: 26)
        popup.addItems(withTitles: formats.map(Self.menuTitle(for:)))
        let selected = formats.firstIndex(of: initialFormat) ?? formats.firstIndex(of: ImageEncoder.format) ?? 0
        popup.selectItem(at: selected)
        popup.target = self
        popup.action = #selector(formatChanged(_:))
        container.addSubview(popup)
        applySelectedFormat()
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        applySelectedFormat()
    }

    private func applySelectedFormat() {
        guard let panel else { return }
        let format = selectedFormat
        panel.allowedContentTypes = [ImageEncoder.utType(for: format)]
        panel.nameFieldStringValue = ImageSaveService.url(
            URL(fileURLWithPath: panel.nameFieldStringValue),
            withFormat: format
        ).lastPathComponent
    }

    nonisolated private static func menuTitle(for format: ImageEncoder.Format) -> String {
        switch format {
        case .png:
            return "PNG (*.png)"
        case .jpeg:
            return "JPEG (*.jpg *.jpeg)"
        case .heic:
            return "HEIC (*.heic)"
        case .webp:
            return "WebP (*.webp)"
        case .avif:
            return "AVIF (*.avif)"
        }
    }
}
