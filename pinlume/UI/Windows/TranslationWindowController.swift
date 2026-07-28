import AppKit
import AVFoundation

private class TranslationWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.keyCode == 13 {  // W
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class TranslationWindowController: NSObject, NSWindowDelegate, NSTextViewDelegate {
    private var window: NSWindow?
    private let sourceView = NSTextView()
    private let resultView = NSTextView()
    private let sourcePopup = NSPopUpButton()
    private let targetPopup = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private var debounceTimer: Timer?
    private var rawTranslation = ""
    private var comparisonEnabled = false
    private var comparisonButton: NSButton?
    private var lastResolvedSource: String?
    private var lastResolvedTarget: String?
    private var targetLanguageWasUserSelected = false
    private let speech = AVSpeechSynthesizer()
    private let coordinator: TranslationSessionCoordinator

    var lastInput: String? { coordinator.lastInput }
    var isKeyAndVisible: Bool {
        window?.isVisible == true && window?.isKeyWindow == true
    }

    override init() {
        coordinator = TranslationSessionCoordinator { text, source, target, completion in
            TranslationService.translateBatch(
                texts: [text], sourceLang: source, targetLang: target) { result in
                switch result {
                case .success(let values): completion(.success(values.first ?? text))
                case .failure(let error): completion(.failure(error))
                }
            }
        }
        super.init()
    }

    /// Build the reusable empty window without presenting it or reading any
    /// clipboard/selected text. Used only by AppDelegate's idle UI warmup.
    func prewarm() {
        if window == nil { buildWindow() }
    }

    /// Closes through the normal AppKit delegate path so pending translation
    /// work is cancelled and focus returns to the app that invoked the hotkey.
    func closeForHotkeyToggle() {
        window?.performClose(nil)
    }

    func present(sourceText: String, autoTranslate: Bool) {
        prewarm()
        debounceTimer?.invalidate()
        coordinator.cancelPending()
        speech.stopSpeaking(at: .immediate)
        progress.stopAnimation(nil)
        progress.isHidden = true
        sourceView.string = sourceText
        resultView.string = ""
        rawTranslation = ""
        statusLabel.stringValue = ""
        comparisonEnabled = false
        comparisonButton?.state = .off
        lastResolvedSource = nil
        lastResolvedTarget = nil
        selectLanguage("auto", in: sourcePopup)
        updateAutoDetectTitle(languageCode: nil)
        positionWindowAtPointer()
        // Translation is a normal, editable document window.  Promote the
        // menu-bar app while it is visible so Dock and Command-Tab can reach it.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeFirstResponder(sourceView)
        if autoTranslate && !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            translateNow()
        }
    }

    func present(sourceText: String, sourceLanguage: String, targetLanguage: String) {
        present(sourceText: sourceText, autoTranslate: false)
        selectLanguage(sourceLanguage, in: sourcePopup)
        selectLanguage(targetLanguage, in: targetPopup)
        targetLanguageWasUserSelected = true
        translateNow()
    }

    private func buildWindow() {
        let panel = TranslationWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 560),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = L("Translation Window")
        panel.minSize = NSSize(width: 720, height: 400)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // This is a normal document-style window: it inherits the app-selected appearance
        // instead of the fixed toolbar appearance.
        panel.appearance = nil
        panel.delegate = self
        panel.center()

        let languageRow = NSStackView()
        languageRow.orientation = .horizontal
        languageRow.spacing = 8
        languageRow.alignment = .centerY
        languageRow.translatesAutoresizingMaskIntoConstraints = false
        sourcePopup.addItem(withTitle: L("Auto Detect"))
        sourcePopup.lastItem?.representedObject = "auto"
        for language in TranslationService.menuLanguages {
            sourcePopup.addItem(withTitle: language.name)
            sourcePopup.lastItem?.representedObject = language.code
            targetPopup.addItem(withTitle: language.name)
            targetPopup.lastItem?.representedObject = language.code
        }
        selectLanguage("zh-CN", in: targetPopup)
        sourcePopup.setAccessibilityLabel(L("Source Language"))
        targetPopup.setAccessibilityLabel(L("Target Language"))
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceLanguageChanged)
        targetPopup.target = self
        targetPopup.action = #selector(targetLanguageChanged)
        sourcePopup.setContentCompressionResistancePriority(.required, for: .horizontal)
        targetPopup.setContentCompressionResistancePriority(.required, for: .horizontal)
        languageRow.addArrangedSubview(sourcePopup)
        let swap = NSButton(title: L("Swap"), target: self, action: #selector(swapLanguages))
        swap.setAccessibilityLabel(L("Swap Languages"))
        languageRow.addArrangedSubview(swap)
        languageRow.addArrangedSubview(targetPopup)
        let translate = NSButton(title: L("Translate"), target: self, action: #selector(translateNow))
        translate.keyEquivalent = "\r"
        translate.keyEquivalentModifierMask = [.command]
        translate.setAccessibilityLabel(L("Translate Now"))
        languageRow.addArrangedSubview(translate)
        progress.style = .spinning
        progress.controlSize = .small
        progress.isHidden = true
        progress.setAccessibilityLabel(L("Translation Status"))
        languageRow.addArrangedSubview(progress)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        languageRow.addArrangedSubview(spacer)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setAccessibilityLabel(L("Translation Status"))
        languageRow.addArrangedSubview(statusLabel)

        configureEditor(sourceView, label: L("Source Text"))
        configureEditor(resultView, label: L("Translated Text"))
        sourceView.delegate = self
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(makeScrollView(sourceView))
        split.addArrangedSubview(makeScrollView(resultView))

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.translatesAutoresizingMaskIntoConstraints = false
        let sourceSpeak = NSButton(title: L("Speak Source"), target: self, action: #selector(sourceSpeak))
        sourceSpeak.setAccessibilityLabel(L("Speak Source"))
        footer.addArrangedSubview(sourceSpeak)
        let sourceCopy = NSButton(title: L("Copy Source"), target: self, action: #selector(sourceCopy))
        sourceCopy.setAccessibilityLabel(L("Copy Source"))
        footer.addArrangedSubview(sourceCopy)
        let clear = NSButton(title: L("Clear"), target: self, action: #selector(clearTranslation))
        clear.setAccessibilityLabel(L("Clear"))
        footer.addArrangedSubview(clear)
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.addArrangedSubview(footerSpacer)
        let resultSpeak = NSButton(title: L("Speak"), target: self, action: #selector(resultSpeak))
        resultSpeak.setAccessibilityLabel(L("Speak Translation"))
        footer.addArrangedSubview(resultSpeak)
        let resultCopy = NSButton(title: L("Copy"), target: self, action: #selector(resultCopy))
        resultCopy.setAccessibilityLabel(L("Copy Translation"))
        footer.addArrangedSubview(resultCopy)
        let compare = NSButton(title: L("Sentence Comparison"), target: self, action: #selector(toggleComparison))
        compare.setButtonType(.switch)
        compare.setAccessibilityLabel(L("Sentence Comparison"))
        comparisonButton = compare
        footer.addArrangedSubview(compare)
        let content = NSView()
        panel.contentView = content
        content.addSubview(languageRow)
        content.addSubview(split)
        content.addSubview(footer)
        NSLayoutConstraint.activate([
            languageRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            languageRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            languageRow.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            sourcePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 135),
            targetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 135),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 180),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            split.topAnchor.constraint(equalTo: languageRow.bottomAnchor, constant: 12),
            split.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            split.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        content.layoutSubtreeIfNeeded()
        split.setPosition((split.bounds.width - split.dividerThickness) / 2, ofDividerAt: 0)
        window = panel
    }

    private func positionWindowAtPointer() {
        guard let window else { return }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visibleFrame = screen.visibleFrame
        let size = window.frame.size
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        window.setFrameOrigin(NSPoint(
            x: min(max(visibleFrame.midX - size.width / 2, visibleFrame.minX), maxX),
            y: min(max(visibleFrame.midY - size.height / 2, visibleFrame.minY), maxY)
        ))
    }

    private func configureEditor(_ view: NSTextView, label: String) {
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        view.isEditable = true
        view.isSelectable = true
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 14)
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
        view.insertionPointColor = .labelColor
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel(label)
    }

    private func makeScrollView(_ textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = textView
        return scroll
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === sourceView else { return }
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.translateNow() }
        }
    }

    @objc private func translateNow() {
        debounceTimer?.invalidate()
        let source = sourceView.string
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            coordinator.cancelPending()
            progress.stopAnimation(nil)
            progress.isHidden = true
            rawTranslation = ""
            resultView.string = ""
            statusLabel.stringValue = ""
            lastResolvedSource = nil
            lastResolvedTarget = nil
            return
        }
        let sourceCode = sourcePopup.selectedItem?.representedObject as? String
        let targetCode = targetLanguageWasUserSelected
            ? targetPopup.selectedItem?.representedObject as? String
            : nil
        progress.isHidden = false
        progress.startAnimation(nil)
        statusLabel.stringValue = L("Translating…")
        coordinator.translate(source, sourceLanguage: sourceCode, targetLanguage: targetCode) { [weak self] presentation in
            guard let self, self.window != nil else { return }
            self.progress.stopAnimation(nil)
            self.progress.isHidden = true
            self.rawTranslation = presentation.translatedText
            self.lastResolvedSource = presentation.sourceLanguage
            self.lastResolvedTarget = presentation.targetLanguage
            if sourceCode == "auto" {
                self.updateAutoDetectTitle(languageCode: presentation.sourceLanguage)
            }
            if let target = presentation.targetLanguage,
               let index = self.targetPopup.itemArray.firstIndex(where: { ($0.representedObject as? String) == target }) {
                self.targetPopup.selectItem(at: index)
            }
            self.renderResult()
            self.statusLabel.stringValue = presentation.status ?? L("Translation complete")
        }
    }

    @objc private func sourceLanguageChanged() {
        guard !sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        translateNow()
    }

    @objc private func targetLanguageChanged() {
        targetLanguageWasUserSelected = true
        guard !sourceView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        translateNow()
    }

    private func renderResult() {
        resultView.string = comparisonEnabled
            ? TranslationTextProcessor.sentenceComparison(source: sourceView.string, translated: rawTranslation)
            : rawTranslation
    }

    @objc private func toggleComparison(_ sender: NSButton) {
        comparisonEnabled = sender.state == .on
        renderResult()
    }

    @objc private func sourceCopy() { copy(sourceView.string) }
    @objc private func resultCopy() { copy(resultView.string) }

    @objc private func clearTranslation() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        coordinator.cancelPending()
        speech.stopSpeaking(at: .immediate)
        progress.stopAnimation(nil)
        progress.isHidden = true
        sourceView.string = ""
        resultView.string = ""
        rawTranslation = ""
        statusLabel.stringValue = ""
        comparisonEnabled = false
        comparisonButton?.state = .off
        lastResolvedSource = nil
        lastResolvedTarget = nil
        targetLanguageWasUserSelected = false
        selectLanguage("auto", in: sourcePopup)
        updateAutoDetectTitle(languageCode: nil)
        window?.makeFirstResponder(sourceView)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func sourceSpeak() { speak(sourceView.string) }
    @objc private func resultSpeak() { speak(resultView.string) }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        if speech.isSpeaking {
            speech.stopSpeaking(at: .immediate)
            return
        }
        speech.speak(AVSpeechUtterance(string: text))
    }

    @objc private func swapLanguages() {
        switch TranslationSwapResolver.resolve(TranslationSwapContext(
            lastResolvedSource: lastResolvedSource,
            lastResolvedTarget: lastResolvedTarget,
            currentResult: resultView.string,
            rawTranslation: rawTranslation)) {
        case .apply(let sourceLanguage, let targetLanguage, let sourceText):
            selectLanguage(sourceLanguage, in: sourcePopup)
            selectLanguage(targetLanguage, in: targetPopup)
            targetLanguageWasUserSelected = true
            sourceView.string = sourceText
            translateNow()
        case .preserveEditedResult:
            statusLabel.stringValue = L("Languages swapped; edited translation was preserved")
        case .unavailable:
            statusLabel.stringValue = L("Translate before swapping languages")
        }
    }

    private func selectLanguage(_ code: String, in popup: NSPopUpButton) {
        if let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? String) == code }) {
            popup.selectItem(at: index)
        }
    }

    private func updateAutoDetectTitle(languageCode: String?) {
        guard let autoItem = sourcePopup.itemArray.first(where: {
            ($0.representedObject as? String) == "auto"
        }) else { return }
        guard let languageCode,
              let language = TranslationService.menuLanguages.first(where: {
                $0.code == languageCode
              })
        else {
            autoItem.title = L("Auto Detect")
            return
        }
        autoItem.title = "\(L("Auto Detect")) · \(language.name)"
    }

    func windowWillClose(_ notification: Notification) {
        debounceTimer?.invalidate()
        coordinator.cancelPending()
        speech.stopSpeaking(at: .immediate)
        progress.stopAnimation(nil)
        progress.isHidden = true
        (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
    }
}
