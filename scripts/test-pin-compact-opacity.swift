import Foundation

private func expectEqual(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
    guard abs(actual - expected) < 0.0001 else {
        fputs("FAIL: \(message). expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private func expectNil(_ value: CGFloat?, _ message: String) {
    guard value == nil else {
        fputs("FAIL: \(message). expected no opacity change, got \(value!)\n", stderr)
        exit(1)
    }
}

@main
struct PinCompactOpacityTests {
    static func main() {
        expectEqual(
            PinOpacityPolicy.displayedOpacity(storedOpacity: 0.35, isCompact: true),
            1,
            "a compact Pin must always display fully opaque"
        )
        expectEqual(
            PinOpacityPolicy.displayedOpacity(storedOpacity: 0.35, isCompact: false),
            0.35,
            "a normal Pin must display its saved opacity"
        )
        expectNil(
            PinOpacityPolicy.adjustedOpacity(storedOpacity: 0.35, by: -0.05, isCompact: true),
            "a compact Pin must reject opacity adjustments"
        )
        expectEqual(
            PinOpacityPolicy.adjustedOpacity(storedOpacity: 0.35, by: -0.05, isCompact: false)!,
            0.30,
            "a normal Pin keeps its existing opacity adjustment behavior"
        )
        print("pin compact opacity tests passed")
    }
}
