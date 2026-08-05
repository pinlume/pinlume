import Cocoa
import AVFoundation

/// Shows a dialog to merge microphone + system audio tracks into one,
/// with individual volume sliders. Presented after recording when both
/// audio sources were active.
final class AudioMergeController: NSObject, NSWindowDelegate {

    private var window: NSPanel?
    private var micSlider: NSSlider!
    private var systemSlider: NSSlider!
    private var sourceURL: URL?
    private var completion: ((URL) -> Void)?
    private var isMerging = false
    private var completionGate = AudioMergeCompletionGate()

    /// Merge the audio tracks and call completion with the final URL.
    /// If the user skips merging, completion is called with the original URL.
    func show(url: URL, completion: @escaping (URL) -> Void) {
        let asset = AVAsset(url: url)
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard audioTracks.count >= 2 else {
            completion(url)
            return
        }

        let panelW: CGFloat = 380
        let panelH: CGFloat = 160

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelW, height: panelH),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = L("Audio Tracks")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: panelW, height: panelH))

        // Title label
        let title = NSTextField(labelWithString: L("Adjust volume for each audio track:"))
        title.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        title.frame = NSRect(x: 20, y: panelH - 32, width: panelW - 40, height: 18)
        content.addSubview(title)

        // Mic volume row
        let micLabel = NSTextField(labelWithString: L("Microphone:"))
        micLabel.font = NSFont.systemFont(ofSize: 11)
        micLabel.frame = NSRect(x: 20, y: panelH - 62, width: 90, height: 18)
        content.addSubview(micLabel)

        micSlider = NSSlider(value: 1.0, minValue: 0.0, maxValue: 1.5, target: nil, action: nil)
        micSlider.frame = NSRect(x: 115, y: panelH - 64, width: panelW - 155, height: 22)
        micSlider.isContinuous = true
        content.addSubview(micSlider)

        // System volume row
        let sysLabel = NSTextField(labelWithString: L("System audio:"))
        sysLabel.font = NSFont.systemFont(ofSize: 11)
        sysLabel.frame = NSRect(x: 20, y: panelH - 92, width: 90, height: 18)
        content.addSubview(sysLabel)

        systemSlider = NSSlider(value: 1.0, minValue: 0.0, maxValue: 1.5, target: nil, action: nil)
        systemSlider.frame = NSRect(x: 115, y: panelH - 94, width: panelW - 155, height: 22)
        systemSlider.isContinuous = true
        content.addSubview(systemSlider)

        // Buttons
        let mergeBtn = NSButton(title: L("Merge Audio"), target: nil, action: nil)
        mergeBtn.bezelStyle = .rounded
        mergeBtn.keyEquivalent = "\r"
        mergeBtn.frame = NSRect(x: panelW - 130, y: 12, width: 115, height: 30)
        content.addSubview(mergeBtn)

        let skipBtn = NSButton(title: L("Keep Separate"), target: nil, action: nil)
        skipBtn.bezelStyle = .rounded
        skipBtn.keyEquivalent = "\u{1b}"
        skipBtn.frame = NSRect(x: panelW - 255, y: 12, width: 115, height: 30)
        content.addSubview(skipBtn)

        panel.contentView = content
        self.window = panel

        mergeBtn.target = self
        mergeBtn.action = #selector(mergeClicked)
        skipBtn.target = self
        skipBtn.action = #selector(skipClicked)

        // Store state for callbacks
        sourceURL = url
        self.completion = completion
        completionGate = AudioMergeCompletionGate()

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func mergeClicked() {
        let micVol = Float(micSlider.doubleValue)
        let sysVol = Float(systemSlider.doubleValue)
        guard let url = sourceURL else { return }
        isMerging = true
        window?.close()
        window = nil

        mergeAudioTracks(url: url, micVolume: micVol, systemVolume: sysVol) { [self] mergedURL in
            DispatchQueue.main.async { self.finishOnce(mergedURL ?? url) }
        }
    }

    @objc private func skipClicked() {
        guard let url = sourceURL else { return }
        finishOnce(url)
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        // Red close, Cmd-W and Esc all mean "keep original" unless a merge is
        // already running. This is deliberately one completion path.
        if !isMerging, let sourceURL { finishOnce(sourceURL) }
        window = nil
    }

    private func finishOnce(_ url: URL) {
        guard completionGate.finishOnce() else { return }
        guard let completion else { return }
        self.completion = nil
        sourceURL = nil
        completion(url)
    }

    // MARK: - Audio Merge

    private func mergeAudioTracks(url: URL, micVolume: Float, systemVolume: Float,
                                   completion: @escaping (URL?) -> Void) {
        let asset = AVAsset(url: url)
        let audioTracks = asset.tracks(withMediaType: .audio)
        guard audioTracks.count >= 2,
              let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(nil)
            return
        }

        // Track 0 = mic (added first), Track 1 = system audio
        let micTrack = audioTracks[0]
        let systemTrack = audioTracks[1]

        let composition = AVMutableComposition()

        // Add video
        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(nil)
            return
        }
        let timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        try? compVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)

        // Add both audio tracks into the same composition audio track
        // so they play simultaneously (mixed)
        guard let compAudioTrack1 = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(nil)
            return
        }
        try? compAudioTrack1.insertTimeRange(timeRange, of: micTrack, at: .zero)

        guard let compAudioTrack2 = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            completion(nil)
            return
        }
        try? compAudioTrack2.insertTimeRange(timeRange, of: systemTrack, at: .zero)

        // Audio mix with volume parameters
        let audioMix = AVMutableAudioMix()
        let micParams = AVMutableAudioMixInputParameters(track: compAudioTrack1)
        micParams.setVolume(micVolume, at: .zero)
        let sysParams = AVMutableAudioMixInputParameters(track: compAudioTrack2)
        sysParams.setVolume(systemVolume, at: .zero)
        audioMix.inputParameters = [micParams, sysParams]

        // Never remove the recording before a complete, validated replacement
        // exists. The temporary path is private to this merge attempt.
        let mergedURL = url.deletingLastPathComponent()
            .appendingPathComponent("." + url.deletingPathExtension().lastPathComponent + ".merge-" + UUID().uuidString + ".mp4")

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            completion(nil)
            return
        }
        exporter.outputURL = mergedURL
        exporter.outputFileType = .mp4
        exporter.audioMix = audioMix

        exporter.exportAsynchronously {
            if exporter.status == .completed {
                do {
                    try TransactionalOutput.commit(to: url, produce: { stagedURL in
                        try FileManager.default.copyItem(at: mergedURL, to: stagedURL)
                    }, validate: Self.validateMovieOutput)
                    try? FileManager.default.removeItem(at: mergedURL)
                    completion(url)
                } catch {
                    // Preserve both the original and the diagnostic temporary
                    // file; the caller safely continues with the original.
                    completion(nil)
                }
            } else {
                #if DEBUG
                print("Audio merge export failed: \(exporter.error?.localizedDescription ?? "unknown")")
                #endif
                completion(nil)
            }
        }
    }

    private static func validateMovieOutput(_ url: URL) throws {
        try TransactionalOutput.validateNonEmptyFile(url)
        let asset = AVAsset(url: url)
        guard asset.isPlayable, !asset.tracks(withMediaType: .video).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}
