import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct PinToolbarTooltipContractTests {
    static func main() throws {
        let source = try String(
            contentsOfFile: "pinlume/UI/Windows/PinWindowController.swift", encoding: .utf8)
        let strip = try String(
            contentsOfFile: "pinlume/UI/Toolbar/ToolbarStripView.swift", encoding: .utf8)

        expect(
            source.contains("bottomStrip.showsNativeTooltips = false")
                && source.contains("moreStrip.showsNativeTooltips = false"),
            "Pin toolbar buttons must disable native tooltips before using the Pin tooltip panel"
        )
        expect(
            strip.contains("var showsNativeTooltips = true")
                && strip.contains("button.toolTip = nativeTooltip(for: button)")
                && strip.contains("bv.toolTip = nativeTooltip(for: bv)")
                && strip.contains("buttonViews[i].toolTip = nativeTooltip(for: buttonViews[i])"),
            "state-only toolbar updates preserve the Pin's single-tooltip policy and shared formatting"
        )

        expect(
            !source.contains("private var toolbarTooltipPanel: NSPanel?")
                && source.contains("contentView.addSubview(tooltipView)")
                && source.contains("toolbarTooltipView?.isHidden = true"),
            "Pin tooltips must be a hidden sibling view in the existing toolbar panel, not a third window"
        )

        guard let start = source.range(of: "    private func handlePinToolbarHover("),
              let end = source.range(of: "    private func showPinToolbarTooltip", range: start.upperBound..<source.endIndex)
        else {
            fputs("FAIL: could not isolate Pin hover handler\n", stderr)
            exit(1)
        }
        let hoverHandler = String(source[start.lowerBound..<end.lowerBound])
        expect(
            hoverHandler.contains("ToolShortcutManager.tooltipText(")
                && hoverHandler.contains("isPointerInsidePinToolbarButton(button)")
                && !hoverHandler.contains("button.toolTip = button.tooltipText"),
            "Pin hover must have one current-pointer-validated tooltip owner with shortcut metadata"
        )
        print("pin toolbar tooltip contract tests passed")
    }
}
