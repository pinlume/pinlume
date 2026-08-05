import Foundation

enum ToolbarToolPreferences {
    static let enabledDefaultsKey = "enabledTools"
    static let knownDefaultsKey = "knownToolRawValues"
    static let primaryOrderDefaultsKey = "primaryToolbarToolOrder"
    static let secondaryOrderDefaultsKey = "secondaryToolbarToolOrder"

    static let defaultPrimaryTools: [AnnotationTool] = [
        .rectangle, .pencil, .number, .marker, .text, .pixelate,
    ]

    static let defaultSecondaryTools: [AnnotationTool] = [
        .line, .arrow, .ellipse, .highlight, .loupe, .stamp, .colorSampler,
        .measure, .eraser,
    ]

    static var allConfigurableTools: [AnnotationTool] {
        defaultPrimaryTools + defaultSecondaryTools
    }

    /// These tools do not need screenshot pixels. Transparent sessions still
    /// take their visibility, primary ordering and More grouping from the
    /// ordinary Tools settings below.
    static let transparentAnnotationSupportedTools: [AnnotationTool] = [
        .pencil, .line, .arrow, .rectangle, .ellipse, .marker, .text,
        .number, .stamp, .loupe,
    ]

    static var transparentAnnotationTools: [AnnotationTool] {
        transparentAnnotationTools(inPrimary: true)
            + transparentAnnotationTools(inPrimary: false)
    }

    static func transparentAnnotationTools(inPrimary: Bool) -> [AnnotationTool] {
        let orderedTools = inPrimary ? primaryTools() : secondaryTools()
        return orderedTools.filter {
            transparentAnnotationSupportedTools.contains($0) && isToolEnabled($0)
        }
    }

    static func displayName(for tool: AnnotationTool) -> String {
        switch tool {
        case .pencil: return L("Pencil")
        case .line: return L("Line")
        case .arrow: return L("Arrow")
        case .rectangle: return L("Rectangle")
        case .filledRectangle: return L("Filled Rectangle")
        case .ellipse: return L("Ellipse")
        case .marker: return L("Marker")
        case .text: return L("Text")
        case .number: return L("Number / Counter")
        case .pixelate: return L("Censor")
        case .blur: return L("Blur")
        case .measure: return L("Measure")
        case .loupe: return L("Magnify (Loupe)")
        case .colorSampler: return L("Color Picker")
        case .stamp: return L("Stamp / Emoji")
        case .highlight: return L("Highlight (Spotlight)")
        case .eraser: return L("Eraser")
        case .select, .translateOverlay, .crop:
            return ""
        }
    }

    static func enabledRawValuesAfterMigration() -> [Int]? {
        let allKnownToolRawValues = allConfigurableTools.map(\.rawValue)
        var enabledRawValues = UserDefaults.standard.array(forKey: enabledDefaultsKey) as? [Int]
        let knownToolRawValues = UserDefaults.standard.array(forKey: knownDefaultsKey) as? [Int]
        let newToolRaws = allKnownToolRawValues.filter { !(knownToolRawValues ?? []).contains($0) }
        if !newToolRaws.isEmpty {
            if enabledRawValues == nil {
                enabledRawValues = allKnownToolRawValues
            } else if knownToolRawValues == nil {
                // Preserve existing enabledTools from old versions; only record current known tools.
            } else {
                enabledRawValues = enabledRawValues! + newToolRaws
            }
            UserDefaults.standard.set(enabledRawValues, forKey: enabledDefaultsKey)
            UserDefaults.standard.set(allKnownToolRawValues, forKey: knownDefaultsKey)
        }
        return enabledRawValues
    }

    static func isToolEnabled(_ tool: AnnotationTool, in enabledRawValues: [Int]? = enabledRawValuesAfterMigration()) -> Bool {
        enabledRawValues == nil || enabledRawValues!.contains(tool.rawValue)
    }

    static func setTool(_ tool: AnnotationTool, enabled: Bool) {
        let defaults = allConfigurableTools.map(\.rawValue)
        var enabledRawValues = UserDefaults.standard.array(forKey: enabledDefaultsKey) as? [Int] ?? defaults
        if enabled {
            if !enabledRawValues.contains(tool.rawValue) {
                enabledRawValues.append(tool.rawValue)
            }
        } else {
            enabledRawValues.removeAll { $0 == tool.rawValue }
        }
        UserDefaults.standard.set(enabledRawValues, forKey: enabledDefaultsKey)
        UserDefaults.standard.set(defaults, forKey: knownDefaultsKey)
    }

    static func primaryTools() -> [AnnotationTool] {
        sanitizedOrder(forKey: primaryOrderDefaultsKey, defaultTools: defaultPrimaryTools)
    }

    static func secondaryTools() -> [AnnotationTool] {
        sanitizedOrder(forKey: secondaryOrderDefaultsKey, defaultTools: defaultSecondaryTools)
    }

    static func setPrimaryTools(_ tools: [AnnotationTool]) {
        setOrderedTools(tools, forKey: primaryOrderDefaultsKey)
    }

    static func setSecondaryTools(_ tools: [AnnotationTool]) {
        setOrderedTools(tools, forKey: secondaryOrderDefaultsKey)
    }

    static func moveTool(_ tool: AnnotationTool, toPrimary: Bool) {
        var primary = primaryTools().filter { $0 != tool }
        var secondary = secondaryTools().filter { $0 != tool }
        if toPrimary {
            primary.append(tool)
        } else {
            secondary.append(tool)
        }
        setPrimaryTools(primary)
        setSecondaryTools(secondary)
    }

    static func moveTool(_ tool: AnnotationTool, inPrimary: Bool, offset: Int) {
        var tools = inPrimary ? primaryTools() : secondaryTools()
        guard let currentIndex = tools.firstIndex(of: tool) else { return }
        let newIndex = currentIndex + offset
        guard tools.indices.contains(newIndex) else { return }
        tools.swapAt(currentIndex, newIndex)
        if inPrimary {
            setPrimaryTools(tools)
        } else {
            setSecondaryTools(tools)
        }
    }

    private static func sanitizedOrder(forKey key: String, defaultTools: [AnnotationTool]) -> [AnnotationTool] {
        let saved = (UserDefaults.standard.array(forKey: key) as? [Int] ?? [])
            .compactMap(AnnotationTool.init(rawValue:))
            .filter { allConfigurableTools.contains($0) }
        let otherKey = key == primaryOrderDefaultsKey ? secondaryOrderDefaultsKey : primaryOrderDefaultsKey
        let otherSaved = (UserDefaults.standard.array(forKey: otherKey) as? [Int] ?? [])
            .compactMap(AnnotationTool.init(rawValue:))
        let fallback = saved.isEmpty ? defaultTools : saved
        var result: [AnnotationTool] = []
        for tool in fallback where !result.contains(tool) && !otherSaved.contains(tool) {
            result.append(tool)
        }
        for tool in defaultTools where !result.contains(tool) && !otherSaved.contains(tool) {
            result.append(tool)
        }
        result.removeAll { !allConfigurableTools.contains($0) }
        return result
    }

    private static func setOrderedTools(_ tools: [AnnotationTool], forKey key: String) {
        let unique = tools.reduce(into: [AnnotationTool]()) { result, tool in
            guard allConfigurableTools.contains(tool), !result.contains(tool) else { return }
            result.append(tool)
        }
        UserDefaults.standard.set(unique.map(\.rawValue), forKey: key)
    }
}

enum PinToolbarLayoutItem: Equatable {
    case tool(AnnotationTool)
    case pinShadow
    case selectText
    case screenTranslation

    var storageValue: String {
        switch self {
        case .tool(let tool): return "tool:\(tool.rawValue)"
        case .pinShadow: return "pinShadow"
        case .selectText: return "selectText"
        case .screenTranslation: return "screenTranslation"
        }
    }

    init?(storageValue: String) {
        if storageValue == "pinShadow" { self = .pinShadow; return }
        if storageValue == "selectText" { self = .selectText; return }
        if storageValue == "screenTranslation" { self = .screenTranslation; return }
        guard storageValue.hasPrefix("tool:"),
              let rawValue = Int(storageValue.dropFirst(5)),
              let tool = AnnotationTool(rawValue: rawValue),
              ToolbarToolPreferences.allConfigurableTools.contains(tool)
        else { return nil }
        self = .tool(tool)
    }
}

/// Keeps non-drawing toolbar controls in the same ordered list shown by
/// Settings. Each surface consumes only its applicable controls.
enum PinToolbarLayoutPreferences {
    static let primaryOrderDefaultsKey = "primaryPinToolbarItemOrder"
    static let secondaryOrderDefaultsKey = "secondaryPinToolbarItemOrder"
    private static let pinShadowPrimaryKey = "pinShadowToolInPrimary"
    private static let selectTextPrimaryKey = "selectTextToolInPrimary"
    private static let screenTranslationPrimaryKey = "screenTranslationToolInPrimary"

    static func items(inPrimary: Bool) -> [PinToolbarLayoutItem] {
        let tools = (inPrimary ? ToolbarToolPreferences.primaryTools() : ToolbarToolPreferences.secondaryTools())
            .map(PinToolbarLayoutItem.tool)
        var allowed = tools
        if isPinShadowPrimary == inPrimary { allowed.append(.pinShadow) }
        if inPrimary {
            allowed.append(contentsOf: fixedOrdinarySelectionItems)
        }

        let key = inPrimary ? primaryOrderDefaultsKey : secondaryOrderDefaultsKey
        let saved = (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .compactMap { PinToolbarLayoutItem(storageValue: $0) }
        var result = saved.filter {
            allowed.contains($0) && !fixedOrdinarySelectionItems.contains($0)
        }
        for item in defaultItems(inPrimary: inPrimary, tools: tools) where !result.contains(item) {
            result.append(item)
        }
        for item in allowed where !result.contains(item) { result.append(item) }
        if inPrimary {
            result.removeAll { fixedOrdinarySelectionItems.contains($0) }
            result.append(contentsOf: fixedOrdinarySelectionItems)
        }
        return result
    }

    static func move(_ item: PinToolbarLayoutItem, inPrimary: Bool, offset: Int) {
        guard !fixedOrdinarySelectionItems.contains(item) else { return }
        var ordered = items(inPrimary: inPrimary)
        guard let index = ordered.firstIndex(of: item) else { return }
        let destination = index + offset
        guard ordered.indices.contains(destination) else { return }
        ordered.swapAt(index, destination)
        persist(ordered, inPrimary: inPrimary)
    }

    static func transfer(_ item: PinToolbarLayoutItem, toPrimary: Bool) {
        guard !fixedOrdinarySelectionItems.contains(item) else { return }
        let source = items(inPrimary: !toPrimary).filter { $0 != item }
        var destination = items(inPrimary: toPrimary).filter { $0 != item }
        switch item {
        case .tool(let tool):
            ToolbarToolPreferences.moveTool(tool, toPrimary: toPrimary)
        case .pinShadow:
            UserDefaults.standard.set(toPrimary, forKey: pinShadowPrimaryKey)
        case .selectText:
            UserDefaults.standard.set(toPrimary, forKey: selectTextPrimaryKey)
        case .screenTranslation:
            UserDefaults.standard.set(toPrimary, forKey: screenTranslationPrimaryKey)
        }
        destination.append(item)
        persist(source, inPrimary: !toPrimary)
        persist(destination, inPrimary: toPrimary)
    }

    private static var isPinShadowPrimary: Bool {
        UserDefaults.standard.object(forKey: pinShadowPrimaryKey) as? Bool ?? true
    }

    private static var isSelectTextPrimary: Bool {
        UserDefaults.standard.object(forKey: selectTextPrimaryKey) as? Bool ?? true
    }

    private static var isScreenTranslationPrimary: Bool {
        UserDefaults.standard.object(forKey: screenTranslationPrimaryKey) as? Bool ?? true
    }

    private static let fixedOrdinarySelectionItems: [PinToolbarLayoutItem] = [.selectText, .screenTranslation]

    private static func defaultItems(
        inPrimary: Bool,
        tools: [PinToolbarLayoutItem]
    ) -> [PinToolbarLayoutItem] {
        var result = tools
        guard inPrimary else {
            if !isPinShadowPrimary { result.append(.pinShadow) }
            return result
        }
        result.append(contentsOf: fixedOrdinarySelectionItems)
        if isPinShadowPrimary {
            let index = result.firstIndex(of: .tool(.pixelate)).map { result.index(after: $0) } ?? result.endIndex
            result.insert(.pinShadow, at: index)
        }
        return result
    }

    private static func persist(_ items: [PinToolbarLayoutItem], inPrimary: Bool) {
        let key = inPrimary ? primaryOrderDefaultsKey : secondaryOrderDefaultsKey
        UserDefaults.standard.set(items.map(\.storageValue), forKey: key)
        let tools = items.compactMap { item -> AnnotationTool? in
            if case .tool(let tool) = item { return tool }
            return nil
        }
        if inPrimary {
            ToolbarToolPreferences.setPrimaryTools(tools)
        } else {
            ToolbarToolPreferences.setSecondaryTools(tools)
        }
    }
}
