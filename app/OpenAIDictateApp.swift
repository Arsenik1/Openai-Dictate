import AVFoundation
import AppKit
import ApplicationServices
import Carbon
import Foundation
import QuartzCore
import Security

private let appName = "OpenAI Dictate"
private let statusTitle = "OD"
private let hotkeyDescription = "Ctrl + Option + Cmd + V"
private let transcribeURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
private let maxDirectUploadBytes = 24 * 1024 * 1024
private let appKeychainService = "openai-dictate-app-api-key"
private let sharedOpenAIKeychainService = "openai-api-key"
private let sharedWhisperKeychainService = "whisper-api-key"
private let accessibilityStateKey = "OpenAIDictateAccessibilityAuthorized"
private let accessibilityGuidedKey = "OpenAIDictateAccessibilityGuided"
private let accessibilityGuidedBundlePathKey = "OpenAIDictateAccessibilityGuidedBundlePath"
private let microphoneGuidedKey = "OpenAIDictateMicrophoneGuided"

private enum PreferenceKey {
    static let model = "OpenAIDictateModel"
    static let language = "OpenAIDictateLanguage"
    static let autoPaste = "OpenAIDictateAutoPaste"
    static let keepAudio = "OpenAIDictateKeepAudio"
    static let soundFeedback = "OpenAIDictateSoundFeedback"
    static let startSound = "OpenAIDictateStartSound"
    static let stopSound = "OpenAIDictateStopSound"
    static let clipboardSound = "OpenAIDictateClipboardSound"
}

private enum DictationState: String {
    case idle
    case recording
    case stopping
    case transcribing
}

private enum PasteDispatchMethod: String {
    case appleScript = "applescript"
    case cgEvent = "cgevent"
}

private enum DictationError: Error, CustomStringConvertible {
    case invalidAudioFile
    case missingAPIKey
    case microphoneDenied
    case recordingCreationFailed(String)
    case recordingStartFailed
    case transcriptionFailed(String)

    var description: String {
        switch self {
        case .invalidAudioFile:
            return "Recording produced no usable audio file."
        case .missingAPIKey:
            return "OpenAI API key is missing."
        case .microphoneDenied:
            return "Microphone access is required to record dictation."
        case .recordingCreationFailed(let message):
            return "Could not prepare recording: \(message)"
        case .recordingStartFailed:
            return "Recording could not be started."
        case .transcriptionFailed(let message):
            return message
        }
    }
}

private struct Preferences {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            PreferenceKey.model: "whisper-1",
            PreferenceKey.language: "",
            PreferenceKey.autoPaste: true,
            PreferenceKey.keepAudio: false,
            PreferenceKey.soundFeedback: true,
            PreferenceKey.startSound: "Glass",
            PreferenceKey.stopSound: "Glass",
            PreferenceKey.clipboardSound: "Blow",
        ])
    }

    var model: String {
        UserDefaults.standard.string(forKey: PreferenceKey.model)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "whisper-1"
    }

    var language: String {
        UserDefaults.standard.string(forKey: PreferenceKey.language)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var autoPaste: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKey.autoPaste)
    }

    var keepAudio: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKey.keepAudio)
    }

    var soundFeedback: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKey.soundFeedback)
    }

    var startSound: String {
        UserDefaults.standard.string(forKey: PreferenceKey.startSound)?.nonEmpty ?? "Glass"
    }

    var stopSound: String {
        UserDefaults.standard.string(forKey: PreferenceKey.stopSound)?.nonEmpty ?? "Glass"
    }

    var clipboardSound: String {
        UserDefaults.standard.string(forKey: PreferenceKey.clipboardSound)?.nonEmpty ?? "Blow"
    }
}

private struct KeychainStore {
    static func readPassword(services: [String]) -> String? {
        for service in services {
            if let password = readPassword(service: service) {
                return password
            }
        }
        return nil
    }

    static func readPassword(service: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: NSUserName(),
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty else {
            return nil
        }

        return password
    }

    @discardableResult
    static func upsertPassword(_ password: String, service: String) -> Bool {
        let passwordData = Data(password.utf8)
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: NSUserName(),
        ]

        let attributes: [CFString: Any] = [
            kSecValueData: passwordData,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        var insertQuery = query
        insertQuery[kSecValueData] = passwordData
        let addStatus = SecItemAdd(insertQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    @discardableResult
    static func deletePassword(service: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: NSUserName(),
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String?
}

private struct APIErrorEnvelope: Decodable {
    struct Payload: Decodable {
        let message: String?
    }

    let error: Payload?
}

private final class Logger {
    private let logURL: URL

    init(stateDirectory: URL) {
        self.logURL = stateDirectory.appendingPathComponent("openai-dictate.log")
    }

    func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try handle.close()
            } else {
                try line.write(to: logURL, atomically: true, encoding: .utf8)
            }
        } catch {
            FileHandle.standardError.write(Data("\(line)".utf8))
        }
    }
}

private final class CaptureRecorderController: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let outputURL: URL
    private let logger: Logger
    private let completion: @MainActor (Result<URL, Error>) -> Void
    private let captureQueue = DispatchQueue(label: "local.openai-dictate.capture")

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var recommendedWriterSettings: [String: Any]?
    private var didStartWriting = false
    private var didComplete = false
    private let startSemaphore = DispatchSemaphore(value: 0)
    private var didSignalStart = false

    init(outputURL: URL, logger: Logger, completion: @escaping @MainActor (Result<URL, Error>) -> Void) {
        self.outputURL = outputURL
        self.logger = logger
        self.completion = completion
    }

    func start() throws {
        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw DictationError.recordingCreationFailed("No default audio input device")
        }

        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()

        guard session.canAddInput(input) else {
            throw DictationError.recordingCreationFailed("Cannot add audio input")
        }
        session.addInput(input)

        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            throw DictationError.recordingCreationFailed("Cannot add capture output")
        }
        session.addOutput(output)

        guard let recommendedSettings = output.recommendedAudioSettingsForAssetWriter(writingTo: .m4a) else {
            throw DictationError.recordingCreationFailed("Could not derive compatible audio writer settings")
        }
        recommendedWriterSettings = recommendedSettings

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        self.writer = writer
        session.commitConfiguration()

        logger.write("capture session starting")
        session.startRunning()

        if startSemaphore.wait(timeout: .now() + 3) == .success {
            logger.write("capture recording started path=\(outputURL.path)")
            return
        }

        session.stopRunning()
        writer.cancelWriting()
        throw DictationError.recordingStartFailed
    }

    func stop() {
        captureQueue.async {
            self.session.stopRunning()
            self.finishWriting()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !didComplete else { return }
        guard let writer else { return }

        if writerInput == nil {
            guard let recommendedWriterSettings,
                  let formatHint = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                finishWithFailure(DictationError.recordingCreationFailed("Could not create audio writer input"))
                return
            }

            let writerInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: recommendedWriterSettings,
                sourceFormatHint: formatHint
            )
            writerInput.expectsMediaDataInRealTime = true

            guard writer.canAdd(writerInput) else {
                finishWithFailure(DictationError.recordingCreationFailed("Cannot add audio writer input"))
                return
            }

            writer.add(writerInput)
            self.writerInput = writerInput
            logger.write("audio writer input created for m4a capture")
        }

        guard let writerInput else { return }

        if !didStartWriting {
            let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard writer.startWriting() else {
                finishWithFailure(writer.error ?? DictationError.recordingStartFailed)
                return
            }
            writer.startSession(atSourceTime: startTime)
            didStartWriting = true

            if !didSignalStart {
                didSignalStart = true
                startSemaphore.signal()
            }
        }

        guard writer.status == .writing else {
            if writer.status == .failed {
                finishWithFailure(writer.error ?? DictationError.recordingStartFailed)
            }
            return
        }

        if writerInput.isReadyForMoreMediaData {
            if !writerInput.append(sampleBuffer) {
                finishWithFailure(writer.error ?? DictationError.recordingStartFailed)
            }
        }
    }

    private func finishWriting() {
        guard !didComplete else { return }
        didComplete = true

        if !didSignalStart {
            didSignalStart = true
            startSemaphore.signal()
        }

        guard let writer, let writerInput else {
            completeOnMain(.failure(DictationError.recordingStartFailed))
            return
        }

        writerInput.markAsFinished()

        switch writer.status {
        case .writing:
            writer.finishWriting {
                if writer.status == .completed {
                    self.logger.write("capture recording finished path=\(self.outputURL.path)")
                    self.completeOnMain(.success(self.outputURL))
                } else {
                    self.finishWithFailure(writer.error ?? DictationError.recordingStartFailed)
                }
            }
        case .completed:
            logger.write("capture recording finished path=\(outputURL.path)")
            completeOnMain(.success(outputURL))
        case .failed, .cancelled:
            finishWithFailure(writer.error ?? DictationError.recordingStartFailed)
        default:
            finishWithFailure(DictationError.recordingStartFailed)
        }
    }

    private func finishWithFailure(_ error: Error) {
        guard !didComplete else { return }
        didComplete = true
        session.stopRunning()
        writer?.cancelWriting()
        logger.write("capture recording failed=\(error.localizedDescription)")
        if !didSignalStart {
            didSignalStart = true
            startSemaphore.signal()
        }
        completeOnMain(.failure(error))
    }

    private func completeOnMain(_ result: Result<URL, Error>) {
        DispatchQueue.main.async {
            Task { @MainActor in
                self.completion(result)
            }
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}

private final class DictationFeedbackView: NSView {
    private enum VisualState {
        case neutralMic
        case recording
        case loading
        case success
        case failure
    }

    private let iconImageView = NSImageView()
    private let spinner = NSProgressIndicator()
    private var currentState: VisualState = .neutralMic

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = frameRect.height / 2
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = borderColor().cgColor
        layer?.backgroundColor = neutralBackgroundColor().cgColor

        iconImageView.translatesAutoresizingMaskIntoConstraints = false
        iconImageView.imageScaling = .scaleProportionallyUpOrDown
        iconImageView.contentTintColor = neutralIconColor()
        iconImageView.image = makeSymbolImage(named: "mic.fill")
        addSubview(iconImageView)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.alphaValue = 0
        addSubview(spinner)

        NSLayoutConstraint.activate([
            iconImageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 24),
            iconImageView.heightAnchor.constraint(equalToConstant: 24),

            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showRecording(animated: Bool, fromHidden: Bool) {
        currentState = .recording
        spinner.stopAnimation(nil)
        spinner.alphaValue = 0
        iconImageView.alphaValue = 1
        iconImageView.contentTintColor = .white
        iconImageView.image = makeSymbolImage(named: "mic.fill")

        if fromHidden {
            applyBackground(neutralBackgroundColor(), animated: false)
        }

        applyBackground(NSColor.systemGreen.withAlphaComponent(0.94), animated: animated)
        if fromHidden {
            animatePop()
        }
    }

    func showNeutralMicrophone(animated: Bool) {
        currentState = .neutralMic
        spinner.stopAnimation(nil)
        spinner.alphaValue = 0
        iconImageView.alphaValue = 1
        iconImageView.contentTintColor = neutralIconColor()
        iconImageView.image = makeSymbolImage(named: "mic.fill")
        applyBackground(neutralBackgroundColor(), animated: animated)
    }

    func showLoading(animated: Bool) {
        currentState = .loading
        applyBackground(neutralBackgroundColor(), animated: animated)
        spinner.startAnimation(nil)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                iconImageView.animator().alphaValue = 0
                spinner.animator().alphaValue = 1
            }
        } else {
            iconImageView.alphaValue = 0
            spinner.alphaValue = 1
        }
    }

    func showSuccess(animated: Bool) {
        currentState = .success
        spinner.stopAnimation(nil)
        iconImageView.image = makeSymbolImage(named: "checkmark")
        iconImageView.contentTintColor = NSColor.systemGreen

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                spinner.animator().alphaValue = 0
                iconImageView.animator().alphaValue = 1
            }
        } else {
            spinner.alphaValue = 0
            iconImageView.alphaValue = 1
        }

        applyBackground(neutralBackgroundColor(), animated: animated)
        animatePop()
    }

    func showFailure(animated: Bool) {
        currentState = .failure
        spinner.stopAnimation(nil)
        iconImageView.image = makeSymbolImage(named: "xmark")
        iconImageView.contentTintColor = .white

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                spinner.animator().alphaValue = 0
                iconImageView.animator().alphaValue = 1
            }
        } else {
            spinner.alphaValue = 0
            iconImageView.alphaValue = 1
        }

        applyBackground(NSColor.systemRed.withAlphaComponent(0.94), animated: animated)
        animatePop()
    }

    private func animatePop() {
        guard let layer else { return }

        let animation = CASpringAnimation(keyPath: "transform.scale")
        animation.fromValue = 0.88
        animation.toValue = 1.0
        animation.initialVelocity = 0.7
        animation.damping = 11
        animation.mass = 0.6
        animation.stiffness = 180
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: "transform.scale")
    }

    private func applyBackground(_ color: NSColor, animated: Bool) {
        let resolvedColor = resolvedColor(color)
        layer?.borderColor = borderColor().cgColor

        guard animated, let layer else {
            self.layer?.backgroundColor = resolvedColor.cgColor
            return
        }

        let animation = CABasicAnimation(keyPath: "backgroundColor")
        animation.fromValue = layer.backgroundColor
        animation.toValue = resolvedColor.cgColor
        animation.duration = 0.18
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "backgroundColor")
        layer.backgroundColor = resolvedColor.cgColor
    }

    private func makeSymbolImage(named systemName: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        return NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    private func neutralBackgroundColor() -> NSColor {
        isDarkMode() ? NSColor(calibratedWhite: 0.10, alpha: 0.96) : NSColor(calibratedWhite: 1.0, alpha: 0.96)
    }

    private func neutralIconColor() -> NSColor {
        isDarkMode() ? NSColor(calibratedWhite: 0.96, alpha: 1.0) : NSColor(calibratedWhite: 0.12, alpha: 1.0)
    }

    private func borderColor() -> NSColor {
        isDarkMode() ? NSColor.white.withAlphaComponent(0.10) : NSColor.black.withAlphaComponent(0.08)
    }

    private func isDarkMode() -> Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func resolvedColor(_ color: NSColor) -> NSColor {
        color.usingColorSpace(.deviceRGB) ?? color
    }
}

private final class DictationFeedbackOverlayController {
    private let panel: NSPanel
    private let feedbackView: DictationFeedbackView
    private var dismissWorkItem: DispatchWorkItem?

    init() {
        let frame = NSRect(x: 0, y: 0, width: 128, height: 64)
        feedbackView = DictationFeedbackView(frame: NSRect(origin: .zero, size: frame.size))
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = feedbackView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.orderOut(nil)
    }

    func showRecording() {
        cancelScheduledDismiss()
        let wasVisible = panel.isVisible
        ensureVisible(animated: !wasVisible)
        feedbackView.showRecording(animated: true, fromHidden: !wasVisible)
    }

    func prepareForTranscribing() {
        cancelScheduledDismiss()
        ensureVisible(animated: false)
        feedbackView.showNeutralMicrophone(animated: true)
    }

    func showLoading() {
        cancelScheduledDismiss()
        ensureVisible(animated: false)
        feedbackView.showLoading(animated: true)
    }

    func showSuccessAndDismiss(after delay: TimeInterval = 0.5) {
        cancelScheduledDismiss()
        ensureVisible(animated: false)
        feedbackView.showSuccess(animated: true)
        scheduleDismiss(after: delay)
    }

    func showFailureAndDismiss(after delay: TimeInterval = 1.0) {
        cancelScheduledDismiss()
        ensureVisible(animated: false)
        feedbackView.showFailure(animated: true)
        scheduleDismiss(after: delay)
    }

    func dismissImmediately() {
        cancelScheduledDismiss()
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    private func ensureVisible(animated: Bool) {
        positionPanel()
        guard !panel.isVisible else { return }

        panel.alphaValue = animated ? 0 : 1
        panel.orderFrontRegardless()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func positionPanel() {
        let screen = activeScreen() ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = NSPoint(
            x: round(visibleFrame.midX - panel.frame.width / 2),
            y: round(visibleFrame.minY + 92)
        )
        panel.setFrameOrigin(origin)
    }

    private func activeScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismissAnimated()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func dismissAnimated() {
        guard panel.isVisible else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        })
    }

    private func cancelScheduledDismiss() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
    }
}

final class DictationApp: NSObject, NSApplicationDelegate {
    private let stateDirectory = URL(fileURLWithPath: NSString(string: "~/Library/Application Support/OpenAIDictateApp").expandingTildeInPath)
    private lazy var logger = Logger(stateDirectory: stateDirectory)
    private let feedbackOverlay = DictationFeedbackOverlayController()

    private var hotKeyRef: EventHotKeyRef?
    private var state: DictationState = .idle
    private var recorder: CaptureRecorderController?
    private var currentRecordingURL: URL?
    private var currentRawRecordingURL: URL?
    private var activeFeedbackSound: NSSound?
    private var pasteTargetApplication: NSRunningApplication?
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var autoPasteMenuItem: NSMenuItem?
    private var keepAudioMenuItem: NSMenuItem?
    private var soundFeedbackMenuItem: NSMenuItem?
    private var languageMenuItem: NSMenuItem?
    private var modelMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        registerHotkey()
        refreshMenuState()
        setStatus("Ready: \(hotkeyDescription)", notify: false)
        prepareAutoPasteAccessibilityIfNeeded()
    }

    private var preferences: Preferences {
        Preferences()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = statusTitle

        let menu = NSMenu()

        let statusItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(NSMenuItem.separator())

        let hotkeyItem = NSMenuItem(title: "Hotkey: \(hotkeyDescription)", action: nil, keyEquivalent: "")
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)

        let modelItem = NSMenuItem(title: "Model: whisper-1", action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)

        let languageItem = NSMenuItem(title: "Language: auto", action: nil, keyEquivalent: "")
        languageItem.isEnabled = false
        menu.addItem(languageItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Toggle Dictation", action: #selector(toggleDictationFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Set OpenAI API Key...", action: #selector(promptForAPIKey), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Clear Stored API Key", action: #selector(clearStoredAPIKey), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Set Language...", action: #selector(promptForLanguage), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Set Model...", action: #selector(promptForModel), keyEquivalent: ""))

        let autoPasteItem = NSMenuItem(title: "Auto Paste", action: #selector(toggleAutoPaste), keyEquivalent: "")
        menu.addItem(autoPasteItem)

        let keepAudioItem = NSMenuItem(title: "Keep Audio Files", action: #selector(toggleKeepAudio), keyEquivalent: "")
        menu.addItem(keepAudioItem)

        let soundFeedbackItem = NSMenuItem(title: "Sound Feedback", action: #selector(toggleSoundFeedback), keyEquivalent: "")
        menu.addItem(soundFeedbackItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Open Data Folder", action: #selector(openDataFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Microphone Settings", action: #selector(openMicrophoneSettingsFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettingsFromMenu), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenAI Dictate", action: #selector(quitApp), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        item.menu = menu

        self.statusItem = item
        self.statusMenuItem = statusItem
        self.autoPasteMenuItem = autoPasteItem
        self.keepAudioMenuItem = keepAudioItem
        self.soundFeedbackMenuItem = soundFeedbackItem
        self.languageMenuItem = languageItem
        self.modelMenuItem = modelItem
    }

    private func refreshMenuState() {
        autoPasteMenuItem?.state = preferences.autoPaste ? .on : .off
        keepAudioMenuItem?.state = preferences.keepAudio ? .on : .off
        soundFeedbackMenuItem?.state = preferences.soundFeedback ? .on : .off
        let language = preferences.language.isEmpty ? "auto" : preferences.language
        languageMenuItem?.title = "Language: \(language)"
        modelMenuItem?.title = "Model: \(preferences.model)"
    }

    @objc private func toggleDictationFromMenu() {
        handleDictationToggle(source: "menu")
    }

    @objc private func promptForAPIKey() {
        guard let key = promptForSecureText(
            title: "OpenAI API Key",
            message: "Enter the API key to store in Keychain for OpenAI Dictate.",
            placeholder: "sk-..."
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return
        }

        if KeychainStore.upsertPassword(key, service: appKeychainService) {
            setStatus("OpenAI API key saved to Keychain.", notify: true)
            logger.write("api key saved to keychain")
        } else {
            setStatus("Could not save API key to Keychain.", notify: true)
            logger.write("api key save failed")
        }
    }

    @objc private func clearStoredAPIKey() {
        if KeychainStore.deletePassword(service: appKeychainService) {
            setStatus("Stored API key cleared.", notify: true)
            logger.write("app keychain api key cleared")
        } else {
            setStatus("Could not clear stored API key.", notify: true)
        }
    }

    @objc private func promptForLanguage() {
        let current = preferences.language
        let result = promptForText(
            title: "Transcription Language",
            message: "Leave empty to let the model auto-detect the language.",
            defaultValue: current,
            placeholder: "tr"
        )

        guard let result else { return }
        UserDefaults.standard.set(result.trimmingCharacters(in: .whitespacesAndNewlines), forKey: PreferenceKey.language)
        refreshMenuState()
        setStatus("Transcription language updated.", notify: true)
        logger.write("language updated")
    }

    @objc private func promptForModel() {
        let current = preferences.model
        let result = promptForText(
            title: "Transcription Model",
            message: "Default is whisper-1.",
            defaultValue: current,
            placeholder: "whisper-1"
        )

        guard let result else { return }
        let value = result.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "whisper-1"
        UserDefaults.standard.set(value, forKey: PreferenceKey.model)
        refreshMenuState()
        setStatus("Transcription model updated.", notify: true)
        logger.write("model updated=\(value)")
    }

    @objc private func toggleAutoPaste() {
        let newValue = !preferences.autoPaste
        UserDefaults.standard.set(newValue, forKey: PreferenceKey.autoPaste)
        refreshMenuState()
    }

    @objc private func toggleKeepAudio() {
        let newValue = !preferences.keepAudio
        UserDefaults.standard.set(newValue, forKey: PreferenceKey.keepAudio)
        refreshMenuState()
    }

    @objc private func toggleSoundFeedback() {
        let newValue = !preferences.soundFeedback
        UserDefaults.standard.set(newValue, forKey: PreferenceKey.soundFeedback)
        refreshMenuState()
    }

    @objc private func openDataFolder() {
        try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(stateDirectory)
    }

    @objc private func openMicrophoneSettingsFromMenu() {
        _ = openMicrophoneSettings()
    }

    @objc private func openAccessibilitySettingsFromMenu() {
        _ = openAccessibilitySettings()
    }

    @objc private func quitApp() {
        if state == .recording || state == .stopping {
            recorder?.stop()
        }
        NSApp.terminate(nil)
    }

    private func registerHotkey() {
        let hotKeyID = EventHotKeyID(signature: fourCharCode("ODAP"), id: 1)
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            setStatus("Hotkey registration failed. Remove conflicting shortcuts.", notify: true)
            logger.write("hotkey registration failed=\(status)")
            return
        }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let app = Unmanaged<DictationApp>.fromOpaque(userData).takeUnretainedValue()
                app.handleDictationToggle(source: "hotkey")
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )

        logger.write("hotkey registered=\(hotkeyDescription)")
    }

    private func handleDictationToggle(source: String) {
        logger.write("toggle source=\(source) state=\(state.rawValue)")

        switch state {
        case .idle:
            capturePasteTargetApplication()
            Task { @MainActor in
                await self.startDictationFlow()
            }
        case .recording:
            stopRecording()
        case .stopping, .transcribing:
            setStatus("Busy: finishing current dictation request.", notify: false)
        }
    }

    @MainActor
    private func startDictationFlow() async {
        guard state == .idle else { return }

        guard ensureAPIKeyAvailable() else {
            setStatus("OpenAI API key is required before recording.", notify: false)
            feedbackOverlay.showFailureAndDismiss()
            return
        }

        let hasPermission = await ensureMicrophonePermission()
        guard hasPermission else {
            setStatus(DictationError.microphoneDenied.description, notify: false)
            feedbackOverlay.showFailureAndDismiss()
            return
        }

        do {
            try startRecording()
        } catch {
            let message = (error as? DictationError)?.description ?? error.localizedDescription
            setStatus(message, notify: false)
            feedbackOverlay.showFailureAndDismiss()
            logger.write("start recording failed=\(message)")
            resetRecordingState(deleteAudio: true)
        }
    }

    private func ensureAPIKeyAvailable() -> Bool {
        if loadedAPIKey() != nil {
            return true
        }

        promptForAPIKey()
        return loadedAPIKey() != nil
    }

    private func loadedAPIKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }

        if let env = ProcessInfo.processInfo.environment["WHISPER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty {
            return env
        }

        return KeychainStore.readPassword(services: [appKeychainService, sharedOpenAIKeychainService, sharedWhisperKeychainService])
    }

    private func startRecording() throws {
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let timestamp = timestamp()
        let rawOutputURL = stateDirectory.appendingPathComponent("recording-\(timestamp).m4a")
        currentRawRecordingURL = rawOutputURL
        currentRecordingURL = rawOutputURL

        do {
            let recorder = CaptureRecorderController(outputURL: rawOutputURL, logger: logger) { [weak self] result in
                self?.handleCaptureRecordingFinished(result)
            }
            try recorder.start()
            self.recorder = recorder
            state = .recording
            playFeedback(named: preferences.startSound)
            feedbackOverlay.showRecording()
            setStatus("Recording started.", notify: false)
            logger.write("recording started file=\(rawOutputURL.path)")
        } catch let error as DictationError {
            throw error
        } catch {
            throw DictationError.recordingCreationFailed(error.localizedDescription)
        }
    }

    private func stopRecording() {
        guard state == .recording, let recorder else {
            return
        }

        state = .stopping
        feedbackOverlay.prepareForTranscribing()
        setStatus("Stopping recording.", notify: false)
        logger.write("recording stop requested")
        recorder.stop()
    }

    private func handleCaptureRecordingFinished(_ result: Result<URL, Error>) {
        logger.write("recording finished callback")
        recorder = nil

        switch result {
        case .failure(let error):
            let message = (error as? DictationError)?.description ?? error.localizedDescription
            setStatus(message, notify: false)
            feedbackOverlay.showFailureAndDismiss()
            resetRecordingState(deleteAudio: true)
        case .success(let rawURL):
            guard FileManager.default.fileExists(atPath: rawURL.path),
                  (try? rawURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 0 }) == true else {
                setStatus(DictationError.invalidAudioFile.description, notify: false)
                feedbackOverlay.showFailureAndDismiss()
                resetRecordingState(deleteAudio: true)
                return
            }

            playFeedback(named: preferences.stopSound)
            feedbackOverlay.showLoading()
            setStatus("Transcribing audio.", notify: false)
            state = .transcribing

            Task { @MainActor in
                await self.transcribeRecording(fromRawAudioAt: rawURL)
            }
        }
    }

    @MainActor
    private func transcribeRecording(fromRawAudioAt rawAudioURL: URL) async {
        do {
            let uploadURL = try await prepareAudioForUpload(fromRawAudioAt: rawAudioURL)
            currentRecordingURL = uploadURL
            let text = try await transcribeAudioFile(at: uploadURL, rawFallbackURL: rawAudioURL)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setStatus("No speech detected.", notify: false)
                feedbackOverlay.showFailureAndDismiss()
                finishSession(deleteAudio: !preferences.keepAudio)
                return
            }

            copyToClipboard(text)

            if preferences.autoPaste {
                let accessibilityTrusted = refreshAccessibilityState()
                if !accessibilityTrusted {
                    guideAccessibilityPermissionIfNeeded()
                    logger.write("accessibility not trusted according to AX API; attempting paste anyway")
                }

                if activatePasteTargetApplicationIfNeeded() {
                    try? await Task.sleep(nanoseconds: 180_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                }

                if let pasteMethod = pasteClipboardIntoFocusedApp() {
                    if accessibilityTrusted || pasteMethod == .appleScript {
                        logger.write("clipboard paste command issued method=\(pasteMethod.rawValue)")
                        setStatus("Transcript pasted.", notify: false)
                    } else {
                        logger.write(
                            "clipboard paste command issued without trusted accessibility permission method=\(pasteMethod.rawValue) path=\(Bundle.main.bundlePath)"
                        )
                        setStatus("Transcript copied. Re-enable Accessibility for this app copy.", notify: false)
                    }
                } else {
                    logger.write("clipboard copied but auto-paste command could not be issued")
                    setStatus("Transcript copied. Grant Accessibility permission to auto-paste.", notify: false)
                }
            } else {
                logger.write("clipboard copied with auto-paste disabled")
                setStatus("Transcript copied to clipboard.", notify: false)
            }

            playFeedback(named: preferences.clipboardSound)
            feedbackOverlay.showSuccessAndDismiss()

            logger.write("transcription completed chars=\(text.count)")
            finishSession(deleteAudio: !preferences.keepAudio)
        } catch {
            let message = (error as? DictationError)?.description ?? error.localizedDescription
            setStatus(message, notify: false)
            feedbackOverlay.showFailureAndDismiss()
            logger.write("transcription failed=\(message)")
            finishSession(deleteAudio: !preferences.keepAudio)
        }
    }

    private func prepareAudioForUpload(fromRawAudioAt rawAudioURL: URL) async throws -> URL {
        let fileSize = (try? rawAudioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        logger.write("raw recording size bytes=\(fileSize) path=\(rawAudioURL.path)")

        guard rawAudioURL.pathExtension.lowercased() == "mp4" else {
            return rawAudioURL
        }

        if fileSize > maxDirectUploadBytes {
            logger.write("raw recording exceeds direct upload threshold, exporting to m4a")
            let exportedURL = try await exportRecordingToM4A(rawAudioURL)
            return exportedURL
        }

        return rawAudioURL
    }

    private func exportRecordingToM4A(_ rawAudioURL: URL) async throws -> URL {
        let outputURL = rawAudioURL.deletingPathExtension().appendingPathExtension("m4a")

        try? FileManager.default.removeItem(at: outputURL)
        let asset = AVURLAsset(url: rawAudioURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw DictationError.transcriptionFailed("Could not prepare audio export for transcription.")
        }

        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        exporter.shouldOptimizeForNetworkUse = true

        try await exporter.export(to: outputURL, as: .m4a)

        guard FileManager.default.fileExists(atPath: outputURL.path),
              (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 > 0 }) == true else {
            throw DictationError.invalidAudioFile
        }

        logger.write("audio exported to m4a path=\(outputURL.path)")
        return outputURL
    }

    private func transcribeAudioFile(at audioURL: URL, rawFallbackURL: URL?) async throws -> String {
        do {
            return try await transcribeAudioFileOnce(at: audioURL)
        } catch let error as DictationError {
            let lowered = error.description.lowercased()
            let fileExtension = audioURL.pathExtension.lowercased()
            let shouldFallbackToM4A =
                fileExtension == "mp4" && (
                    lowered.contains("invalid file format") ||
                    lowered.contains("maximum content size limit") ||
                    lowered.contains("openai api error (413)")
                )

            if shouldFallbackToM4A {
                logger.write("raw mp4 upload rejected, trying m4a fallback path=\(audioURL.path)")
                let sourceURL = rawFallbackURL ?? audioURL
                let exportedURL = try await exportRecordingToM4A(sourceURL)
                currentRecordingURL = exportedURL
                return try await transcribeAudioFileOnce(at: exportedURL)
            }
            throw error
        }
    }

    private func transcribeAudioFileOnce(at audioURL: URL) async throws -> String {
        guard let apiKey = loadedAPIKey(), !apiKey.isEmpty else {
            throw DictationError.missingAPIKey
        }

        let audioData = try Data(contentsOf: audioURL)
        guard !audioData.isEmpty else {
            throw DictationError.invalidAudioFile
        }

        logger.write("uploading audio path=\(audioURL.path) bytes=\(audioData.count) type=\(audioURL.pathExtension.lowercased())")

        var request = URLRequest(url: transcribeURL)
        request.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = makeMultipartBody(
            audioData: audioData,
            filename: audioURL.lastPathComponent,
            contentType: multipartContentType(for: audioURL),
            boundary: boundary
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DictationError.transcriptionFailed("OpenAI transcription request failed.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let errorMessage = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).error?.message)?.nonEmpty
                ?? String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                ?? "HTTP \(httpResponse.statusCode)"
            throw DictationError.transcriptionFailed("OpenAI API error (\(httpResponse.statusCode)): \(errorMessage)")
        }

        let responsePayload = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return responsePayload.text ?? ""
    }

    private func multipartContentType(for audioURL: URL) -> String {
        switch audioURL.pathExtension.lowercased() {
        case "m4a":
            return "audio/m4a"
        case "mp4":
            return "audio/mp4"
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        default:
            return "application/octet-stream"
        }
    }

    private func makeMultipartBody(audioData: Data, filename: String, contentType: String, boundary: String) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(audioData)
        append("\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(preferences.model)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("json\r\n")

        if !preferences.language.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            append("\(preferences.language)\r\n")
        }

        append("--\(boundary)--\r\n")
        return body
    }

    private func finishSession(deleteAudio: Bool) {
        resetRecordingState(deleteAudio: deleteAudio)
        state = .idle
    }

    private func resetRecordingState(deleteAudio: Bool) {
        if deleteAudio, let currentRecordingURL {
            try? FileManager.default.removeItem(at: currentRecordingURL)
        }

        if deleteAudio, let currentRawRecordingURL {
            try? FileManager.default.removeItem(at: currentRawRecordingURL)
        }

        recorder = nil
        currentRecordingURL = nil
        currentRawRecordingURL = nil
        pasteTargetApplication = nil
        if state != .idle {
            state = .idle
        }
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func prepareAutoPasteAccessibilityIfNeeded() {
        let accessibilityTrusted = refreshAccessibilityState()
        logger.write(
            "app launched bundlePath=\(Bundle.main.bundlePath) bundleID=\(Bundle.main.bundleIdentifier ?? "unknown") axTrusted=\(accessibilityTrusted)"
        )

        guard preferences.autoPaste, !accessibilityTrusted else {
            return
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        logger.write("accessibility prompt requested on launch path=\(Bundle.main.bundlePath)")
    }

    private func capturePasteTargetApplication() {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            pasteTargetApplication = nil
            logger.write("paste target capture skipped: no frontmost app")
            return
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        if frontmostApp.bundleIdentifier == ownBundleID {
            pasteTargetApplication = nil
            logger.write("paste target capture skipped: frontmost app is self")
            return
        }

        pasteTargetApplication = frontmostApp
        logger.write(
            "paste target captured app=\(frontmostApp.localizedName ?? "unknown") bundle=\(frontmostApp.bundleIdentifier ?? "unknown") pid=\(frontmostApp.processIdentifier)"
        )
    }

    private func activatePasteTargetApplicationIfNeeded() -> Bool {
        guard let pasteTargetApplication else {
            logger.write("paste target activation skipped: no stored target")
            return false
        }

        let activated = pasteTargetApplication.activate()
        logger.write(
            "paste target activation result=\(activated) app=\(pasteTargetApplication.localizedName ?? "unknown") pid=\(pasteTargetApplication.processIdentifier)"
        )
        return activated
    }

    private func pasteClipboardIntoFocusedApp() -> PasteDispatchMethod? {
        if runAppleScriptPaste() {
            logger.write("paste path=applescript")
            return .appleScript
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        guard let keyDown, let keyUp else {
            return nil
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        logger.write("paste path=cgevent")
        return .cgEvent
    }

    private func setStatus(_ message: String, notify: Bool) {
        statusMenuItem?.title = message
        statusItem?.button?.toolTip = message
        _ = notify
    }

    private func playFeedback(named soundName: String) {
        guard preferences.soundFeedback else { return }

        let soundURL = URL(fileURLWithPath: "/System/Library/Sounds/\(soundName).aiff")
        guard FileManager.default.fileExists(atPath: soundURL.path) else { return }
        guard let sound = NSSound(contentsOf: soundURL, byReference: true) else { return }
        activeFeedbackSound = sound
        sound.play()
    }

    private func guideAccessibilityPermissionIfNeeded() {
        let defaults = UserDefaults.standard
        let currentBundlePath = Bundle.main.bundlePath
        let guidedBundlePath = defaults.string(forKey: accessibilityGuidedBundlePathKey)
        if !defaults.bool(forKey: accessibilityGuidedKey) || guidedBundlePath != currentBundlePath {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            _ = openAccessibilitySettings()
            defaults.set(true, forKey: accessibilityGuidedKey)
            defaults.set(currentBundlePath, forKey: accessibilityGuidedBundlePathKey)
            logger.write("accessibility guidance opened path=\(currentBundlePath)")
        }
    }

    private func runAppleScriptPaste() -> Bool {
        guard let script = NSAppleScript(
            source: "tell application \"System Events\" to keystroke \"v\" using command down"
        ) else {
            logger.write("apple script paste failed=script creation returned nil")
            return false
        }

        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            logger.write("apple script paste failed=\(errorInfo)")
            return false
        }

        return true
    }

    @discardableResult
    private func refreshAccessibilityState() -> Bool {
        let defaults = UserDefaults.standard
        let isAuthorized = AXIsProcessTrusted()
        let previousValue = defaults.object(forKey: accessibilityStateKey) as? Bool

        if isAuthorized {
            defaults.set(true, forKey: accessibilityStateKey)
            defaults.set(false, forKey: accessibilityGuidedKey)
            defaults.set(Bundle.main.bundlePath, forKey: accessibilityGuidedBundlePathKey)
            return true
        }

        if previousValue == true {
            defaults.set(false, forKey: accessibilityStateKey)
            defaults.set(false, forKey: accessibilityGuidedKey)
            defaults.removeObject(forKey: accessibilityGuidedBundlePathKey)
        }

        return false
    }

    private func ensureMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            UserDefaults.standard.set(false, forKey: microphoneGuidedKey)
            return true
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            if granted {
                UserDefaults.standard.set(false, forKey: microphoneGuidedKey)
            } else {
                guideMicrophonePermissionIfNeeded()
            }
            return granted
        case .denied, .restricted:
            guideMicrophonePermissionIfNeeded()
            return false
        @unknown default:
            guideMicrophonePermissionIfNeeded()
            return false
        }
    }

    private func guideMicrophonePermissionIfNeeded() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: microphoneGuidedKey) {
            _ = openMicrophoneSettings()
            defaults.set(true, forKey: microphoneGuidedKey)
            logger.write("microphone guidance opened")
        }
    }

    @discardableResult
    private func openMicrophoneSettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    @discardableResult
    private func openAccessibilitySettings() -> Bool {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private func promptForSecureText(title: String, message: String, placeholder: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        alert.accessoryView = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return nil
        }

        return field.stringValue
    }

    private func promptForText(title: String, message: String, defaultValue: String, placeholder: String) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = placeholder
        field.stringValue = defaultValue
        alert.accessoryView = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return nil
        }

        return field.stringValue
    }
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars.prefix(4) {
        result = (result << 8) + OSType(scalar.value)
    }
    return result
}

let app = NSApplication.shared
private let delegate = DictationApp()
app.delegate = delegate
app.run()
