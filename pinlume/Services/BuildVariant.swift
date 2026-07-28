enum BuildVariant {
    #if PLUS
    static let isPlus = true
    static let isOffline = false
    static let displayName = "Pinlume"
    static let actionsURLScheme = "pinlume"
    #elseif OFFLINE
    static let isPlus = false
    static let isOffline = true
    static let displayName = "Pinlume Offline"
    static let actionsURLScheme = "pinlume"
    #else
    static let isPlus = false
    static let isOffline = false
    static let displayName = "Pinlume"
    static let actionsURLScheme = "pinlume"
    #endif
}
