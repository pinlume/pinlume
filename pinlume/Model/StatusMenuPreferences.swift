import Foundation

enum CaptureMenuItemID: String, CaseIterable {
    case captureArea = "captureArea"
    case transparentAnnotation = "transparentAnnotation"
    case presentationDrawing = "presentationDrawing"
    case captureScreen = "captureScreen"
    case captureOCR = "captureOCR"
    case selectableOCRCapture = "selectableOCRCapture"
    case translationWindow = "translationWindow"
    case screenTranslationCapture = "screenTranslationCapture"
    case quickCapture = "quickCapture"
    case captureLastArea = "captureLastArea"
    case scrollCapture = "scrollCapture"
    case captureDelay = "captureDelay"
    case recordArea = "recordArea"
    case recordScreen = "recordScreen"
    case recentCaptures = "recentCaptures"
    case historyOverlay = "historyOverlay"
    case openImage = "openImage"
    case openVideo = "openVideo"
    case openFromClipboard = "openFromClipboard"
    case pinFromClipboard = "pinFromClipboard"
    case toggleAllPins = "toggleAllPins"

    static let userDefaultsKey = "captureMenuItemOrder"
    static let moreDefaultsKey = "statusMenuMoreItemOrder"
    static let enabledDefaultsKey = "statusMenuEnabledItemIDs"
    private static let enabledMigrationVersionKey = "statusMenuEnabledItemMigrationVersion"
    private static let enabledMigrationVersion = 2

    static let defaultPrimaryOrder: [CaptureMenuItemID] = [
        .captureArea,
        .transparentAnnotation,
        .presentationDrawing,
        .captureScreen,
        .captureOCR,
        .quickCapture,
        .pinFromClipboard,
        .toggleAllPins,
    ]

    static let defaultMoreOrder: [CaptureMenuItemID] = [
        .scrollCapture,
        .captureLastArea,
        .captureDelay,
        .selectableOCRCapture,
        .screenTranslationCapture,
        .translationWindow,
        .recordArea,
        .recordScreen,
        .recentCaptures,
        .historyOverlay,
        .openImage,
        .openVideo,
        .openFromClipboard,
    ]

    static let defaultOrder = defaultPrimaryOrder

    static var configurableItems: [CaptureMenuItemID] {
        defaultPrimaryOrder + defaultMoreOrder
    }

    static func orderedItems(defaults: UserDefaults = .standard) -> [CaptureMenuItemID] {
        primaryItems(defaults: defaults)
    }

    static func primaryItems(defaults: UserDefaults = .standard) -> [CaptureMenuItemID] {
        orderedList(key: userDefaultsKey, fallback: defaultPrimaryOrder, defaults: defaults)
    }

    static func moreItems(defaults: UserDefaults = .standard) -> [CaptureMenuItemID] {
        orderedList(key: moreDefaultsKey, fallback: defaultMoreOrder, defaults: defaults)
    }

    static func enabledItems(defaults: UserDefaults = .standard) -> Set<CaptureMenuItemID> {
        guard let saved = defaults.stringArray(forKey: enabledDefaultsKey) else {
            return Set(configurableItems)
        }
        var enabled = Set(saved.compactMap(CaptureMenuItemID.init(rawValue:)))
        if defaults.integer(forKey: enabledMigrationVersionKey) < enabledMigrationVersion {
            enabled.formUnion([
                .selectableOCRCapture,
                .screenTranslationCapture,
                .translationWindow,
                .transparentAnnotation,
                .presentationDrawing,
            ])
            defaults.set(
                configurableItems.filter { enabled.contains($0) }.map(\.rawValue),
                forKey: enabledDefaultsKey)
            defaults.set(enabledMigrationVersion, forKey: enabledMigrationVersionKey)
        }
        return enabled
    }

    static func isEnabled(_ item: CaptureMenuItemID, defaults: UserDefaults = .standard) -> Bool {
        enabledItems(defaults: defaults).contains(item)
    }

    static func setEnabled(_ item: CaptureMenuItemID, enabled: Bool, defaults: UserDefaults = .standard) {
        var items = enabledItems(defaults: defaults)
        if enabled {
            items.insert(item)
        } else {
            items.remove(item)
        }
        defaults.set(configurableItems.filter { items.contains($0) }.map(\.rawValue), forKey: enabledDefaultsKey)
    }

    static func saveOrder(_ items: [CaptureMenuItemID], defaults: UserDefaults = .standard) {
        save(primary: items, more: moreItems(defaults: defaults), defaults: defaults)
    }

    static func save(primary: [CaptureMenuItemID], more: [CaptureMenuItemID], defaults: UserDefaults = .standard) {
        let sanitizedPrimary = sanitized(primary)
        let sanitizedMore = sanitized(more).filter { !sanitizedPrimary.contains($0) }
        let missing = configurableItems.filter { !sanitizedPrimary.contains($0) && !sanitizedMore.contains($0) }
        defaults.set(sanitizedPrimary.map(\.rawValue), forKey: userDefaultsKey)
        defaults.set((sanitizedMore + missing).map(\.rawValue), forKey: moreDefaultsKey)
    }

    static func move(_ item: CaptureMenuItemID, toPrimary: Bool, defaults: UserDefaults = .standard) {
        var primary = primaryItems(defaults: defaults).filter { $0 != item }
        var more = moreItems(defaults: defaults).filter { $0 != item }
        if toPrimary {
            primary.append(item)
        } else {
            more.append(item)
        }
        save(primary: primary, more: more, defaults: defaults)
    }

    static func move(_ item: CaptureMenuItemID, inPrimary: Bool, offset: Int, defaults: UserDefaults = .standard) {
        var primary = primaryItems(defaults: defaults)
        var more = moreItems(defaults: defaults)
        var list = inPrimary ? primary : more
        guard let index = list.firstIndex(of: item) else { return }
        let target = index + offset
        guard target >= 0, target < list.count else { return }
        list.swapAt(index, target)
        if inPrimary {
            primary = list
        } else {
            more = list
        }
        save(primary: primary, more: more, defaults: defaults)
    }

    static func resetOrder(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: userDefaultsKey)
        defaults.removeObject(forKey: moreDefaultsKey)
        defaults.removeObject(forKey: enabledDefaultsKey)
        defaults.removeObject(forKey: enabledMigrationVersionKey)
    }

    private static func orderedList(key: String, fallback: [CaptureMenuItemID], defaults: UserDefaults) -> [CaptureMenuItemID] {
        let otherFallback = key == userDefaultsKey ? defaultMoreOrder : defaultPrimaryOrder
        let saved = defaults.stringArray(forKey: key) ?? []
        let isMigratingOldPrimaryOrder = key == userDefaultsKey && defaults.stringArray(forKey: moreDefaultsKey) == nil
        var result: [CaptureMenuItemID] = []
        for rawValue in saved {
            guard let item = CaptureMenuItemID(rawValue: rawValue),
                  configurableItems.contains(item),
                  (!isMigratingOldPrimaryOrder || fallback.contains(item)),
                  !result.contains(item) else { continue }
            result.append(item)
        }
        for item in fallback where !result.contains(item) {
            result.append(item)
        }
        for item in configurableItems where !result.contains(item) && !otherFallback.contains(item) {
            result.append(item)
        }
        return result.filter { !itemsInOtherList(key: key, defaults: defaults).contains($0) }
    }

    private static func itemsInOtherList(key: String, defaults: UserDefaults) -> [CaptureMenuItemID] {
        let otherKey = key == userDefaultsKey ? moreDefaultsKey : userDefaultsKey
        if key == moreDefaultsKey && defaults.stringArray(forKey: moreDefaultsKey) == nil {
            return []
        }
        guard let saved = defaults.stringArray(forKey: otherKey) else { return [] }
        return saved.compactMap(CaptureMenuItemID.init(rawValue:))
    }

    private static func sanitized(_ items: [CaptureMenuItemID]) -> [CaptureMenuItemID] {
        var result: [CaptureMenuItemID] = []
        for item in items where configurableItems.contains(item) && !result.contains(item) {
            result.append(item)
        }
        return result
    }
}

extension CaptureMenuItemID {
    var tag: Int {
        CaptureMenuItemID.configurableItems.firstIndex(of: self) ?? 0
    }

    static func fromTag(_ tag: Int) -> CaptureMenuItemID? {
        guard tag >= 0, tag < configurableItems.count else { return nil }
        return configurableItems[tag]
    }

    var displayTitle: String {
        switch self {
        case .captureArea: return L("Capture Area")
        case .transparentAnnotation: return L("Transparent Annotation")
        case .presentationDrawing: return L("Presentation Drawing")
        case .captureScreen: return L("Capture Screen")
        case .captureOCR: return L("Capture OCR & QR")
        case .selectableOCRCapture: return L("Selectable Text Capture")
        case .translationWindow: return L("Translation Window")
        case .screenTranslationCapture: return L("Screen Translation Capture")
        case .quickCapture: return L("Quick Capture")
        case .captureLastArea: return L("Capture Last Area")
        case .scrollCapture: return L("Scroll Capture")
        case .captureDelay: return L("Capture Delay")
        case .recordArea: return L("Record Area")
        case .recordScreen: return L("Record Screen")
        case .recentCaptures: return L("Recent Captures")
        case .historyOverlay: return L("Show History Panel")
        case .openImage: return L("Open Image...")
        case .openVideo: return L("Open Video...")
        case .openFromClipboard: return L("Open from Clipboard")
        case .pinFromClipboard: return L("Pin from Clipboard")
        case .toggleAllPins: return L("Hide/Show All Pins")
        }
    }

    var displaySymbolName: String {
        switch self {
        case .captureArea: return "crop"
        case .transparentAnnotation: return "pencil.and.outline"
        case .presentationDrawing: return "pencil.tip.crop.circle"
        case .captureScreen: return "desktopcomputer"
        case .captureOCR: return "text.viewfinder"
        case .selectableOCRCapture: return "text.cursor"
        case .translationWindow: return "translate"
        case .screenTranslationCapture: return "character.book.closed"
        case .quickCapture: return "square.and.arrow.down"
        case .captureLastArea: return "arrow.counterclockwise.circle"
        case .scrollCapture: return "scroll"
        case .captureDelay: return "timer"
        case .recordArea: return "record.circle"
        case .recordScreen: return "menubar.dock.rectangle"
        case .recentCaptures: return "clock.arrow.circlepath"
        case .historyOverlay: return "square.grid.2x2"
        case .openImage: return "photo.on.rectangle.angled"
        case .openVideo: return "film"
        case .openFromClipboard: return "doc.on.clipboard"
        case .pinFromClipboard: return "pin.fill"
        case .toggleAllPins: return "pin.slash"
        }
    }
}
