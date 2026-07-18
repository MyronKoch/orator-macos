import Cocoa
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static weak var shared: AppDelegate?

    // MARK: - State

    private var statusItem: NSStatusItem!
    private var engine: OratorEngine?
    private var timeline: SpeechTimeline?
    private var engineError: String?
    private var hotkeyManager: HotkeyManager?
    private var trustPollTimer: Timer?
    private var onboardingWindow: NSWindow?
    private var onboardingStatusLabel: NSTextField?
    private var hotkeyRecorderWindowController: HotkeyRecorderWindowController?
    private var pronunciationsEditor: PronunciationsEditor?
    private var appVoiceProfilesEditor: AppVoiceProfilesEditor?
    private var readerWindowController: ReaderWindowController?
    private var previewAudioPlayer: AVAudioPlayer?
    private var isPreviewRenderInFlight = false
    private var lastReadApp: (bundleID: String, name: String)?
    private var readingQueue: [String] = []
    private var queuePlaybackActive = false
    private var continuousReading: Bool = true

    private let defaults = UserDefaults.standard
    private let appProfiles = AppVoiceProfiles()
    private let history = ReadingHistory()
    private var rememberHistory: Bool = {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: "rememberHistory") == nil
            ? true
            : defaults.bool(forKey: "rememberHistory")
    }()
    private enum Pref {
        static let voice = "voice"
        static let speed = "speed"
        static let autoCast = "autoCast"
        static let continuousReading = "continuousReading"
        static let rememberHistory = "rememberHistory"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let hotkeyDisplay = "hotkeyDisplay"
        static let hotkeyPauseKeyCode = "hotkeyPauseKeyCode"
        static let hotkeyPauseModifiers = "hotkeyPauseModifiers"
        static let hotkeyPauseDisplay = "hotkeyPauseDisplay"
        static let hotkeyQueueKeyCode = "hotkeyQueueKeyCode"
        static let hotkeyQueueModifiers = "hotkeyQueueModifiers"
        static let hotkeyQueueDisplay = "hotkeyQueueDisplay"
    }
    private static let speedOptions: [Float] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5]

    // Option + ' (US keyboard apostrophe = keyCode 39)
    static let hotKeyLabel = "⌥'"

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupStatusItem()
        loadEngineAsync()

        if AXIsProcessTrusted() {
            installKeyMonitor()
        } else {
            showOnboarding()
            startTrustPolling()
        }

        NotificationCenter.default.addObserver(
            forName: .oratorSpeechStarted, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.updateIcon(speaking: true) } }
        NotificationCenter.default.addObserver(
            forName: .oratorSpeechFinished, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine?.isSpeaking == false else { return }
                self.updateIcon(speaking: false)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .oratorSpeechPaused, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.rebuildMenu() } }
        NotificationCenter.default.addObserver(
            forName: .oratorSpeechResumed, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.rebuildMenu() } }
        NotificationCenter.default.addObserver(
            forName: .oratorSpeechFinished, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[OratorFinishReason.key] as? String
            Task { @MainActor in
                guard let self, self.engine?.isSpeaking == false else { return }

                // An explicit stop means "silence" - never auto-advance or
                // auto-start the queue off the back of it.
                if reason == OratorFinishReason.stopped {
                    if self.queuePlaybackActive {
                        self.queuePlaybackActive = false
                        self.rebuildMenu()
                    }
                    return
                }

                if self.queuePlaybackActive {
                    if self.continuousReading {
                        self.playNextInQueue()
                    } else {
                        self.queuePlaybackActive = false
                        self.rebuildMenu()
                    }
                } else if !self.readingQueue.isEmpty, self.continuousReading {
                    // Non-queue speech (hotkey, Reader, menu) finished while
                    // items wait: the queue is "up next" - start it.
                    oratorLog("queue: auto-starting after speech completed (\(self.readingQueue.count) queued)")
                    self.startQueuePlayback()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        cleanupPreviewTempFile()
    }

    // MARK: - App Intents

    func speakText(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let engine, let timeline else { return }

        recordHistory(text)
        do { try speakSelection(text, engine: engine, timeline: timeline) }
        catch { oratorLog("speak FAILED: \(error.localizedDescription)") }
    }

    func speakClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        speakText(text)
    }

    // MARK: - Engine

    private func loadEngineAsync() {
        guard let modelPath = Bundle.main.url(forResource: "kokoro-v1_0", withExtension: "safetensors"),
              let voicesPath = Bundle.main.url(forResource: "voices", withExtension: "npz") else {
            engineError = "Model files missing from app bundle"
            rebuildMenu()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let engine = try OratorEngine(modelPath: modelPath, voicesPath: voicesPath)
                engine.warmUp()
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.engine = engine
                    self.timeline = SpeechTimeline(engine: engine)
                    engine.currentVoice = self.defaults.string(forKey: Pref.voice) ?? "af_heart"
                    let savedSpeed = self.defaults.float(forKey: Pref.speed)
                    engine.speed = savedSpeed > 0 ? savedSpeed : 1.0
                    self.continuousReading = self.defaults.object(forKey: Pref.continuousReading) == nil
                        ? true
                        : self.defaults.bool(forKey: Pref.continuousReading)
                    self.rebuildMenu()
                    NSLog("Orator: engine ready (%d voices)", engine.voiceNames.count)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.engineError = error.localizedDescription
                    self?.rebuildMenu()
                    NSLog("Orator: engine failed: %@", error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Global hotkey (NSEvent, requires Accessibility)

    private func installKeyMonitor() {
        guard hotkeyManager == nil else { return }
        let manager = HotkeyManager { [weak self] action in
            Task { @MainActor in
                switch action {
                case .speak: self?.toggleSpeech()
                case .pause: self?.togglePauseResume()
                case .queue: self?.queueSelection()
                }
            }
        }
        manager.installAll()
        for action in HotkeyAction.allCases {
            guard let savedHotkey = savedHotkey(for: action) else { continue }
            manager.reconfigure(
                action,
                keyCode: savedHotkey.keyCode,
                modifiers: savedHotkey.modifiers
            )
        }
        hotkeyManager = manager
        hotkeyRecorderWindowController?.setHotkeyManager(manager)
        rebuildMenu()
    }

    private var hotkeyPreferenceKeys: [
        HotkeyAction: HotkeyRecorderWindowController.PreferenceKeys
    ] {
        [
            .speak: .init(
                keyCode: Pref.hotkeyKeyCode,
                modifiers: Pref.hotkeyModifiers,
                display: Pref.hotkeyDisplay
            ),
            .pause: .init(
                keyCode: Pref.hotkeyPauseKeyCode,
                modifiers: Pref.hotkeyPauseModifiers,
                display: Pref.hotkeyPauseDisplay
            ),
            .queue: .init(
                keyCode: Pref.hotkeyQueueKeyCode,
                modifiers: Pref.hotkeyQueueModifiers,
                display: Pref.hotkeyQueueDisplay
            ),
        ]
    }

    private func savedHotkey(
        for action: HotkeyAction
    ) -> (keyCode: UInt16, modifiers: NSEvent.ModifierFlags, display: String)? {
        guard let keys = hotkeyPreferenceKeys[action],
              let keyCodeNumber = defaults.object(forKey: keys.keyCode) as? NSNumber,
              let modifiersNumber = defaults.object(forKey: keys.modifiers) as? NSNumber,
              keyCodeNumber.uint64Value <= UInt64(UInt16.max)
        else { return nil }

        let keyCode = UInt16(keyCodeNumber.uint64Value)
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(modifiersNumber.uint64Value))
            .intersection([.command, .option, .control, .shift])
        // Invalid historical/manual values must never register Return or an
        // unmodified global key. Valid legacy speak preferences still use the
        // original three key names above.
        guard keyCode != 36, !modifiers.isEmpty else { return nil }

        return (
            keyCode,
            modifiers,
            defaults.string(forKey: keys.display)
                ?? HotkeyRecorderWindowController.defaultDisplay(for: action)
        )
    }

    private func hotkeyDisplay(for action: HotkeyAction) -> String {
        savedHotkey(for: action)?.display
            ?? HotkeyRecorderWindowController.defaultDisplay(for: action)
    }

    private func startTrustPolling() {
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard AXIsProcessTrusted() else { return }
            Task { @MainActor in
                guard let self = self else { return }
                self.trustPollTimer?.invalidate()
                self.trustPollTimer = nil
                self.installKeyMonitor()
                self.dismissOnboarding()
            }
        }
    }

    // MARK: - Speak toggle

    private func toggleSpeech() {
        if let application = NSWorkspace.shared.frontmostApplication,
           let bundleID = application.bundleIdentifier,
           let name = application.localizedName {
            lastReadApp = (bundleID: bundleID, name: name)
        } else {
            lastReadApp = nil
        }
        let readApp = lastReadApp

        guard let engine, timeline != nil else { oratorLog("toggle: engine nil"); return }

        if engine.isSpeaking {
            oratorLog("toggle: was speaking → stop")
            queuePlaybackActive = false
            engine.stop()
            return
        }

        oratorLog("toggle: capturing selection…")
        captureSelectedText { [weak self] text in
            guard let self, let engine = self.engine, let timeline = self.timeline else { return }
            guard let text = text, !text.isEmpty else {
                oratorLog("capture: NO TEXT (copy produced nothing)")
                return
            }
            oratorLog("capture: got \(text.count) chars — speaking")

            let globalVoice = self.defaults.string(forKey: Pref.voice) ?? "af_heart"
            let savedSpeed = self.defaults.float(forKey: Pref.speed)
            let globalSpeed = savedSpeed == 0 ? Float(1.0) : savedSpeed
            if let bundleID = readApp?.bundleID,
               let profile = self.appProfiles.profile(for: bundleID) {
                engine.currentVoice = profile.voice
                engine.speed = profile.speed
            } else {
                engine.currentVoice = globalVoice
                engine.speed = globalSpeed
            }

            self.recordHistory(text)
            do { try self.speakSelection(text, engine: engine, timeline: timeline) }
            catch { oratorLog("speak FAILED: \(error.localizedDescription)") }
        }
    }

    private func speakSelection(
        _ text: String,
        engine: OratorEngine,
        timeline: SpeechTimeline
    ) throws {
        if defaults.bool(forKey: Pref.autoCast) {
            let segments = DialogueCaster.cast(
                text: text,
                narratorVoice: engine.currentVoice,
                pool: engine.voiceNames
            )
            try timeline.speak(segments: segments)
        } else {
            try timeline.speak(text: text)
        }
    }

    private func recordHistory(_ text: String) {
        guard rememberHistory else { return }
        history.add(text)
        rebuildMenu()
    }

    /// Simulate Cmd+C, read the pasteboard, then restore the user's clipboard.
    private func captureSelectedText(completion: @escaping @MainActor (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)
        let changeCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            var text: String?
            let changed = pasteboard.changeCount != changeCount
            if changed {
                text = pasteboard.string(forType: .string)
            }
            oratorLog("capture: pasteboard changed=\(changed) len=\(text?.count ?? -1)")
            self.restorePasteboard(pasteboard, items: saved)
            completion(text)
        }
    }

    private func savePasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    private func restorePasteboard(_ pb: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        for itemDict in items {
            let item = NSPasteboardItem()
            for (type, data) in itemDict { item.setData(data, forType: type) }
            pb.writeObjects([item])
        }
    }

    // MARK: - Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(speaking: false)
        rebuildMenu()
    }

    /// The Orator bust as menu-bar template images (monochrome + alpha, 18pt).
    /// Idle shows the head alone; while speaking, the logo's sound waves
    /// appear beside it. Both share identical head geometry so the state
    /// change reads as waves materializing, not the icon jumping.
    /// (An accent-tint approach was tried first and rejected: tinted template
    /// icons disappear against wallpaper-tinted menu bars.)
    private static let menuBarIdleIcon = loadMenuBarIcon(named: "menubar-idle")
    private static let menuBarSpeakingIcon = loadMenuBarIcon(named: "menubar-speaking")

    private static func loadMenuBarIcon(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Orator"
        return image
    }

    private func updateIcon(speaking: Bool) {
        if let icon = speaking ? Self.menuBarSpeakingIcon : Self.menuBarIdleIcon {
            statusItem.button?.image = icon
            return
        }
        // Fallback if the bundled assets are ever missing.
        let symbol = speaking ? "waveform.circle.fill" : "waveform.circle"
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "Orator"
        )
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let title = NSMenuItem(title: "Orator", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        // Status line
        let status: String
        if let err = engineError {
            status = "⚠️ \(err)"
        } else if engine == nil {
            status = "Loading voices…"
        } else if !AXIsProcessTrusted() {
            status = "⚠️ Needs Accessibility permission"
        } else {
            status = "Ready — select text, press \(Self.hotKeyLabel)"
        }
        let statusLine = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        if !AXIsProcessTrusted() {
            let fix = NSMenuItem(title: "Grant Permission…", action: #selector(openOnboarding), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }
        menu.addItem(.separator())

        if engine != nil {
            let readFile = NSMenuItem(
                title: "Read File…",
                action: #selector(readFile),
                keyEquivalent: ""
            )
            readFile.target = self
            menu.addItem(readFile)

            let speakClipboard = NSMenuItem(title: "Speak Clipboard", action: #selector(speakClipboardText), keyEquivalent: "")
            speakClipboard.target = self
            menu.addItem(speakClipboard)

            let openReader = NSMenuItem(title: "Open Reader…", action: #selector(openReader), keyEquivalent: "")
            openReader.target = self
            menu.addItem(openReader)

            let stopItem = NSMenuItem(title: "Stop Speaking", action: #selector(stopSpeaking), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)

            let pauseActionTitle = engine?.isPaused == true ? "Resume Speaking" : "Pause Speaking"
            let pauseTitle = "\(pauseActionTitle) (\(hotkeyDisplay(for: .pause)))"
            let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(pauseResumeSpeaking), keyEquivalent: "")
            pauseItem.target = self
            menu.addItem(pauseItem)
            menu.addItem(.separator())

            let queueRoot = NSMenuItem(title: "Queue", action: nil, keyEquivalent: "")
            let queueMenu = NSMenu()

            let addSelectionToQueue = NSMenuItem(
                title: "Add Selection to Queue",
                action: #selector(addSelectionToQueue),
                keyEquivalent: ""
            )
            addSelectionToQueue.target = self
            queueMenu.addItem(addSelectionToQueue)

            let addClipboardToQueue = NSMenuItem(
                title: "Add Clipboard to Queue",
                action: #selector(addClipboardToQueue),
                keyEquivalent: ""
            )
            addClipboardToQueue.target = self
            queueMenu.addItem(addClipboardToQueue)
            queueMenu.addItem(.separator())

            let queueCountTitle = readingQueue.isEmpty
                ? "Empty"
                : "\(readingQueue.count) \(readingQueue.count == 1 ? "item" : "items")"
            let queueCount = NSMenuItem(title: queueCountTitle, action: nil, keyEquivalent: "")
            queueCount.isEnabled = false
            queueMenu.addItem(queueCount)

            for text in readingQueue {
                let item = NSMenuItem(title: queueItemTitle(for: text), action: nil, keyEquivalent: "")
                item.isEnabled = false
                queueMenu.addItem(item)
            }

            if queuePlaybackActive || !readingQueue.isEmpty {
                queueMenu.addItem(.separator())
            }
            if !readingQueue.isEmpty && !queuePlaybackActive {
                let playQueue = NSMenuItem(
                    title: "Play Queue",
                    action: #selector(startQueuePlayback),
                    keyEquivalent: ""
                )
                playQueue.target = self
                queueMenu.addItem(playQueue)
            }
            if queuePlaybackActive {
                let stopQueue = NSMenuItem(
                    title: "Stop Queue",
                    action: #selector(stopQueuePlayback),
                    keyEquivalent: ""
                )
                stopQueue.target = self
                queueMenu.addItem(stopQueue)
            }
            if !readingQueue.isEmpty {
                let clearQueue = NSMenuItem(
                    title: "Clear Queue",
                    action: #selector(clearReadingQueue),
                    keyEquivalent: ""
                )
                clearQueue.target = self
                queueMenu.addItem(clearQueue)
            }
            queueMenu.addItem(.separator())

            let continuousReadingItem = NSMenuItem(
                title: "Continuous Reading",
                action: #selector(toggleContinuousReading),
                keyEquivalent: ""
            )
            continuousReadingItem.target = self
            continuousReadingItem.state = continuousReading ? .on : .off
            queueMenu.addItem(continuousReadingItem)
            queueRoot.submenu = queueMenu
            menu.addItem(queueRoot)

            let exportRoot = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
            let exportMenu = NSMenu()
            let exportSelection = NSMenuItem(
                title: "Export Selection to Audio…",
                action: #selector(exportSelectionToAudio),
                keyEquivalent: ""
            )
            exportSelection.target = self
            exportMenu.addItem(exportSelection)

            let exportClipboard = NSMenuItem(
                title: "Export Clipboard to Audio…",
                action: #selector(exportClipboardToAudio),
                keyEquivalent: ""
            )
            exportClipboard.target = self
            exportMenu.addItem(exportClipboard)

            let exportFile = NSMenuItem(
                title: "Export File to Audio…",
                action: #selector(exportFileToAudio),
                keyEquivalent: ""
            )
            exportFile.target = self
            exportMenu.addItem(exportFile)
            exportRoot.submenu = exportMenu
            menu.addItem(exportRoot)
        }

        let historyRoot = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu()
        let historyEntries = history.entries
        if historyEntries.isEmpty {
            let emptyHistory = NSMenuItem(title: "No recent reads", action: nil, keyEquivalent: "")
            emptyHistory.isEnabled = false
            historyMenu.addItem(emptyHistory)
        } else {
            for entry in historyEntries.prefix(20) {
                let item = NSMenuItem(
                    title: entry.title,
                    action: #selector(readHistoryEntry(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry.text
                item.isEnabled = engine != nil
                historyMenu.addItem(item)
            }
        }
        historyMenu.addItem(.separator())

        let rememberHistoryItem = NSMenuItem(
            title: "Remember Reading History",
            action: #selector(toggleRememberHistory),
            keyEquivalent: ""
        )
        rememberHistoryItem.target = self
        rememberHistoryItem.state = rememberHistory ? .on : .off
        historyMenu.addItem(rememberHistoryItem)

        let clearHistoryItem = NSMenuItem(
            title: "Clear History",
            action: #selector(clearHistory),
            keyEquivalent: ""
        )
        clearHistoryItem.target = self
        historyMenu.addItem(clearHistoryItem)

        historyRoot.submenu = historyMenu
        menu.addItem(historyRoot)
        menu.addItem(.separator())

        if let engine = engine {
            // Voice picker
            let voiceRoot = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
            let voiceMenu = NSMenu()
            for name in engine.voiceNames {
                let item = NSMenuItem(title: displayName(for: name), action: #selector(selectVoice(_:)), keyEquivalent: "")
                item.representedObject = name
                item.target = self
                item.state = name == engine.currentVoice ? .on : .off
                voiceMenu.addItem(item)
            }
            voiceRoot.submenu = voiceMenu
            menu.addItem(voiceRoot)

            // Speed picker
            let speedRoot = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
            let speedMenu = NSMenu()
            for value in Self.speedOptions {
                let item = NSMenuItem(title: String(format: "%.2gx", value), action: #selector(selectSpeed(_:)), keyEquivalent: "")
                item.representedObject = value
                item.target = self
                item.state = abs(engine.speed - value) < 0.01 ? .on : .off
                speedMenu.addItem(item)
            }
            speedRoot.submenu = speedMenu
            menu.addItem(speedRoot)

            let autoCast = NSMenuItem(
                title: "Auto-cast dialogue",
                action: #selector(toggleAutoCast),
                keyEquivalent: ""
            )
            autoCast.target = self
            autoCast.state = defaults.bool(forKey: Pref.autoCast) ? .on : .off
            menu.addItem(autoCast)

            let pronunciations = NSMenuItem(
                title: "Pronunciations…",
                action: #selector(openPronunciations),
                keyEquivalent: ""
            )
            pronunciations.target = self
            menu.addItem(pronunciations)

            let perAppVoices = NSMenuItem(
                title: "Per-App Voices…",
                action: #selector(openPerAppVoices),
                keyEquivalent: ""
            )
            perAppVoices.target = self
            menu.addItem(perAppVoices)

            if let app = lastReadApp {
                let saveProfile = NSMenuItem(
                    title: "Use current voice for \(app.name)",
                    action: #selector(saveVoiceForLastReadApp),
                    keyEquivalent: ""
                )
                saveProfile.target = self
                menu.addItem(saveProfile)

                if appProfiles.profile(for: app.bundleID) != nil {
                    let clearProfile = NSMenuItem(
                        title: "Clear voice for \(app.name)",
                        action: #selector(clearVoiceForLastReadApp),
                        keyEquivalent: ""
                    )
                    clearProfile.target = self
                    menu.addItem(clearProfile)
                }
            }
            menu.addItem(.separator())

            let speakTest = NSMenuItem(title: "Speak Test Sentence", action: #selector(speakTestSentence), keyEquivalent: "")
            speakTest.target = self
            menu.addItem(speakTest)
            menu.addItem(.separator())
        }

        let recordShortcut = NSMenuItem(
            title: "Keyboard Shortcuts…",
            action: #selector(openHotkeyRecorder),
            keyEquivalent: ""
        )
        recordShortcut.target = self
        menu.addItem(recordShortcut)

        // Login item toggle
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let quit = NSMenuItem(title: "Quit Orator", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func displayName(for voice: String) -> String {
        let parts = voice.split(separator: "_")
        guard parts.count == 2 else { return voice }
        let accent = parts[0].hasPrefix("a") ? "US" : "UK"
        let gender = parts[0].hasSuffix("f") ? "Female" : "Male"
        return "\(parts[1].capitalized)  (\(accent) \(gender))"
    }

    private func queueItemTitle(for text: String) -> String {
        let singleLine = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let prefix = String(singleLine.prefix(40))
        return singleLine.count > 40 ? "\(prefix)…" : prefix
    }

    // MARK: - Menu actions

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let engine = engine else { return }
        queuePlaybackActive = false
        engine.stop()
        engine.currentVoice = name
        defaults.set(name, forKey: Pref.voice)
        rebuildMenu()
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Float, let engine = engine else { return }
        engine.speed = value
        defaults.set(value, forKey: Pref.speed)
        rebuildMenu()
    }

    @objc private func toggleAutoCast() {
        defaults.set(!defaults.bool(forKey: Pref.autoCast), forKey: Pref.autoCast)
        rebuildMenu()
    }

    @objc private func openPronunciations() {
        if pronunciationsEditor == nil {
            pronunciationsEditor = PronunciationsEditor(pronunciations: .shared)
        }
        pronunciationsEditor?.show()
    }

    @objc private func openHotkeyRecorder() {
        if hotkeyRecorderWindowController == nil {
            hotkeyRecorderWindowController = HotkeyRecorderWindowController(
                hotkeyManager: hotkeyManager,
                defaults: defaults,
                preferenceKeys: hotkeyPreferenceKeys,
                onBindingChanged: { [weak self] in
                    self?.rebuildMenu()
                }
            )
        }
        hotkeyRecorderWindowController?.show()
    }

    @objc private func saveVoiceForLastReadApp() {
        guard let app = lastReadApp, let engine = engine else { return }
        appProfiles.set(
            bundleID: app.bundleID,
            appName: app.name,
            voice: engine.currentVoice,
            speed: engine.speed
        )
        appVoiceProfilesEditor?.reload()
        rebuildMenu()
    }

    @objc private func clearVoiceForLastReadApp() {
        guard let app = lastReadApp else { return }
        appProfiles.remove(bundleID: app.bundleID)
        appVoiceProfilesEditor?.reload()
        rebuildMenu()
    }

    @objc private func openPerAppVoices() {
        if appVoiceProfilesEditor == nil {
            appVoiceProfilesEditor = AppVoiceProfilesEditor(
                profiles: appProfiles,
                voiceNames: engine?.voiceNames ?? [],
                speedOptions: Self.speedOptions,
                onPreview: { [weak self] voice, speed in
                    self?.previewVoice(voice, speed: speed)
                },
                onChange: { [weak self] in
                    self?.rebuildMenu()
                }
            )
        }
        appVoiceProfilesEditor?.show()
    }

    func previewVoice(_ voiceName: String, speed: Float) {
        guard let engine, !isPreviewRenderInFlight else { return }

        isPreviewRenderInFlight = true
        let sample = "The quick brown fox jumps over the lazy dog."
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orator-preview.m4a")
        engine.synthesizeToFile(sample, voiceName: voiceName, speed: speed, to: url) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPreviewRenderInFlight = false

                guard case .success(let renderedURL) = result else { return }
                do {
                    self.previewAudioPlayer?.stop()
                    self.previewAudioPlayer = try AVAudioPlayer(contentsOf: renderedURL)
                    self.previewAudioPlayer?.play()
                } catch {
                    oratorLog("voice preview playback FAILED: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Orator: login item toggle failed: %@", error.localizedDescription)
        }
        rebuildMenu()
    }

    @objc private func addSelectionToQueue() {
        captureSelectedText { [weak self] text in
            self?.addToReadingQueue(text)
        }
    }

    @objc private func addClipboardToQueue() {
        addToReadingQueue(NSPasteboard.general.string(forType: .string))
    }

    @objc private func toggleContinuousReading() {
        continuousReading.toggle()
        defaults.set(continuousReading, forKey: Pref.continuousReading)
        rebuildMenu()
    }

    @objc private func readHistoryEntry(_ sender: NSMenuItem) {
        guard let timeline, let text = sender.representedObject as? String else { return }
        do { try timeline.speak(text: text) }
        catch { oratorLog("history speak FAILED: \(error.localizedDescription)") }
    }

    @objc private func toggleRememberHistory() {
        rememberHistory.toggle()
        defaults.set(rememberHistory, forKey: Pref.rememberHistory)
        rebuildMenu()
    }

    @objc private func clearHistory() {
        history.clear()
        rebuildMenu()
    }

    private func addToReadingQueue(_ text: String?) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showNotification("Nothing to queue", body: "Select or copy some text first.")
            return
        }

        readingQueue.append(text)
        if engine?.isSpeaking == false && !queuePlaybackActive {
            startQueuePlayback()
        } else {
            rebuildMenu()
        }
    }

    @objc private func startQueuePlayback() {
        queuePlaybackActive = true
        playNextInQueue()
    }

    private func playNextInQueue() {
        guard !readingQueue.isEmpty else {
            queuePlaybackActive = false
            rebuildMenu()
            return
        }
        guard let timeline else {
            queuePlaybackActive = false
            rebuildMenu()
            return
        }

        let text = readingQueue.removeFirst()
        oratorLog("queue: playing next item (\(readingQueue.count) remaining)")
        do { try timeline.speak(text: text) }
        catch { oratorLog("queue speak FAILED: \(error.localizedDescription)") }
        rebuildMenu()
    }

    @objc private func stopQueuePlayback() {
        queuePlaybackActive = false
        engine?.stop()
        rebuildMenu()
    }

    @objc private func clearReadingQueue() {
        readingQueue.removeAll()
        rebuildMenu()
    }

    @objc private func speakClipboardText() {
        speakClipboard()
    }

    @objc private func openReader() {
        guard let engine, let timeline else { return }

        if timeline.current != nil {
            if readerWindowController == nil {
                readerWindowController = ReaderWindowController(timeline: timeline, engine: engine)
            }
            readerWindowController?.showFollowingTimeline()
            return
        }

        captureSelectedText { [weak self] capturedText in
            guard let self, let engine = self.engine, let timeline = self.timeline else { return }

            // Speech may have started while selection capture was in flight.
            // Prefer the live timeline in that case and never replace it with
            // a passive clipboard document.
            if timeline.current != nil {
                if self.readerWindowController == nil {
                    self.readerWindowController = ReaderWindowController(
                        timeline: timeline,
                        engine: engine
                    )
                }
                self.readerWindowController?.showFollowingTimeline()
                return
            }

            let selectedText = capturedText.flatMap { text in
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            }
            let text = selectedText ?? NSPasteboard.general.string(forType: .string)

            if self.readerWindowController == nil {
                self.readerWindowController = ReaderWindowController(
                    timeline: timeline,
                    engine: engine
                )
            }
            self.readerWindowController?.show(text: text)
        }
    }

    @objc private func readFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileTextExtractor.supportedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let text = try FileTextExtractor.extractText(from: url)
                    let chunks = TextChunker.chunk(text)
                    DispatchQueue.main.async {
                        guard let timeline = self.timeline else { return }
                        self.recordHistory(text)
                        do { try timeline.speak(chunks: chunks, from: 0) }
                        catch { oratorLog("speak FAILED: \(error.localizedDescription)") }
                    }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        self.showNotification("Couldn’t read file", body: message)
                    }
                }
            }
        }
    }

    @objc private func exportSelectionToAudio() {
        captureSelectedText { [weak self] text in
            self?.exportToAudio(text)
        }
    }

    @objc private func exportClipboardToAudio() {
        exportToAudio(NSPasteboard.general.string(forType: .string))
    }

    @objc private func exportFileToAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileTextExtractor.supportedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let text = try FileTextExtractor.extractText(from: url)
                    DispatchQueue.main.async {
                        self.exportToAudio(text)
                    }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        self.showNotification("Couldn’t read file", body: message)
                    }
                }
            }
        }
    }

    private func exportToAudio(_ text: String?) {
        let trimmedText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedText.isEmpty else {
            showNotification("Nothing to export", body: "Select or copy some text first.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(defaultExportFilename(for: trimmedText)).m4a"

        let fileManager = FileManager.default
        panel.directoryURL = fileManager.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first

        panel.begin { [weak self] response in
            guard response == .OK,
                  let self,
                  let engine = self.engine,
                  let url = panel.url else { return }

            self.statusItem.button?.toolTip = "Exporting… 0%"
            engine.synthesizeToFile(
                trimmedText,
                to: url,
                progress: { [weak self] fraction in
                    MainActor.assumeIsolated {
                        let percent = Int((fraction * 100).rounded())
                        self?.statusItem.button?.toolTip = "Exporting… \(percent)%"
                    }
                },
                completion: { [weak self] result in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.statusItem.button?.toolTip = nil

                        switch result {
                        case .success(let url):
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        case .failure(let error):
                            self.showNotification("Export failed", body: error.localizedDescription)
                        }
                    }
                }
            )
        }
    }

    private func defaultExportFilename(for text: String) -> String {
        let prefix = String(text.prefix(40))
        let unsafeCharacters = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.controlCharacters)
        let sanitized = prefix.unicodeScalars.map { scalar in
            unsafeCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let collapsed = sanitized.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let filename = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return filename.isEmpty ? "Orator Audio" : filename
    }

    private func showNotification(_ title: String, body: String) {
        let escapedTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\""
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(nil)
        }
    }

    @objc private func speakTestSentence() {
        guard let timeline else { return }
        do {
            try timeline.speak(
                text: "Hello! Orator is working. Select any text and press option apostrophe to hear it read aloud."
            )
        } catch {
            NSLog("Orator: test speak failed: %@", error.localizedDescription)
        }
    }

    @objc func stopSpeaking() {
        queuePlaybackActive = false
        engine?.stop()
        rebuildMenu()
    }

    @objc private func pauseResumeSpeaking() {
        togglePauseResume()
    }

    /// Global queue hotkey (Option+Q): capture the current selection
    /// (clipboard fallback) and append it to the reading queue without
    /// interrupting whatever is speaking. Queue semantics match the menu:
    /// adding while idle starts queue playback.
    private func queueSelection() {
        captureSelectedText { [weak self] captured in
            guard let self else { return }
            let selected = captured.flatMap { text in
                text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
            }
            let text = selected ?? NSPasteboard.general.string(forType: .string)
            oratorLog("queue hotkey: captured len=\(text?.count ?? -1)")
            let hadText = !(text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            self.addToReadingQueue(text)
            if hadText, let text {
                self.showNotification("Added to queue", body: String(text.prefix(80)))
            }
        }
    }

    /// Global pause/resume toggle (Option+P hotkey and menu item). No-ops
    /// when nothing is speaking; the engine posts paused/resumed
    /// notifications that keep the Reader window and menu in sync.
    private func togglePauseResume() {
        guard let engine else { return }
        if engine.isPaused {
            engine.resume()
        } else if engine.isSpeaking {
            engine.pause()
        }
    }

    @objc private func openOnboarding() {
        showOnboarding()
        if trustPollTimer == nil { startTrustPolling() }
    }

    @objc private func quit() {
        queuePlaybackActive = false
        engine?.stop()
        cleanupPreviewTempFile()
        NSApp.terminate(nil)
    }

    private func cleanupPreviewTempFile() {
        previewAudioPlayer?.stop()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orator-preview.m4a")
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Onboarding window

    private func showOnboarding() {
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Welcome to Orator"
        window.center()
        window.isReleasedWhenClosed = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)

        let heading = NSTextField(labelWithString: "One quick setup step")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString:
            "Orator reads any text on your screen out loud.\n\n" +
            "To do that, macOS requires you to grant it Accessibility access:\n\n" +
            "1. Click “Open System Settings” below\n" +
            "2. Find “Orator” in the list (use the + button if it's not there)\n" +
            "3. Turn the switch ON\n\n" +
            "Then highlight any text anywhere and press \(Self.hotKeyLabel) (Option + apostrophe) to hear it. Press it again to stop."
        )
        body.font = .systemFont(ofSize: 13)
        body.preferredMaxLayoutWidth = 400

        let statusLabel = NSTextField(labelWithString: "Waiting for permission…")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        onboardingStatusLabel = statusLabel

        let button = NSButton(title: "Open System Settings", target: self, action: #selector(openAccessibilitySettings))
        button.bezelStyle = .rounded
        button.keyEquivalent = "\r"

        content.addArrangedSubview(heading)
        content.addArrangedSubview(body)
        content.addArrangedSubview(button)
        content.addArrangedSubview(statusLabel)

        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window

        // Also fire the system prompt so Orator appears in the list automatically.
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([promptKey: kCFBooleanTrue!] as CFDictionary)
    }

    private func dismissOnboarding() {
        onboardingStatusLabel?.stringValue = "✓ Permission granted — you're all set!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.onboardingWindow?.close()
            self?.onboardingWindow = nil
            self?.onboardingStatusLabel = nil
            self?.rebuildMenu()
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Per-app voices window

@MainActor
private final class AppVoiceProfilesEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    private enum Column {
        static let app = NSUserInterfaceItemIdentifier("appVoiceProfileApp")
        static let voice = NSUserInterfaceItemIdentifier("appVoiceProfileVoice")
        static let speed = NSUserInterfaceItemIdentifier("appVoiceProfileSpeed")
        static let preview = NSUserInterfaceItemIdentifier("appVoiceProfilePreview")
        static let remove = NSUserInterfaceItemIdentifier("appVoiceProfileRemove")
    }

    private let profiles: AppVoiceProfiles
    private let voiceNames: [String]
    private let speedOptions: [Float]
    private let onPreview: (_ voiceName: String, _ speed: Float) -> Void
    private let onChange: @MainActor () -> Void
    private let window: NSWindow
    private let tableView = NSTableView()
    private var rows: [(bundleID: String, profile: Profile)]

    init(
        profiles: AppVoiceProfiles,
        voiceNames: [String],
        speedOptions: [Float],
        onPreview: @escaping (_ voiceName: String, _ speed: Float) -> Void,
        onChange: @escaping @MainActor () -> Void
    ) {
        self.profiles = profiles
        self.voiceNames = voiceNames
        self.speedOptions = speedOptions
        self.onPreview = onPreview
        self.onChange = onChange
        rows = profiles.all
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow()
    }

    func show() {
        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() {
        rows = profiles.all
        tableView.reloadData()
    }

    private func configureWindow() {
        window.title = "Per-App Voices"
        window.center()
        window.isReleasedWhenClosed = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)

        let heading = NSTextField(labelWithString: "Per-App Voices")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString:
            "Add a running app, then choose the voice and speed Orator should use for it."
        )
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 612

        let appColumn = NSTableColumn(identifier: Column.app)
        appColumn.title = "App"
        appColumn.width = 220
        appColumn.minWidth = 140

        let voiceColumn = NSTableColumn(identifier: Column.voice)
        voiceColumn.title = "Voice"
        voiceColumn.width = 190
        voiceColumn.minWidth = 120

        let speedColumn = NSTableColumn(identifier: Column.speed)
        speedColumn.title = "Speed"
        speedColumn.width = 80
        speedColumn.minWidth = 60

        let previewColumn = NSTableColumn(identifier: Column.preview)
        previewColumn.title = "Preview"
        previewColumn.width = 90
        previewColumn.minWidth = 80

        let removeColumn = NSTableColumn(identifier: Column.remove)
        removeColumn.title = "Remove"
        removeColumn.width = 90
        removeColumn.minWidth = 80

        tableView.addTableColumn(appColumn)
        tableView.addTableColumn(voiceColumn)
        tableView.addTableColumn(speedColumn)
        tableView.addTableColumn(previewColumn)
        tableView.addTableColumn(removeColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 30
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.widthAnchor.constraint(equalToConstant: 612).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 240).isActive = true

        let addButton = NSButton(title: "Add App…", target: self, action: #selector(showAddAppMenu(_:)))
        addButton.bezelStyle = .rounded

        content.addArrangedSubview(heading)
        content.addArrangedSubview(body)
        content.addArrangedSubview(scrollView)
        content.addArrangedSubview(addButton)

        window.contentView = content
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }

        if identifier == Column.remove {
            let button = NSButton(title: "Remove", target: self, action: #selector(removeProfile(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = row
            return button
        }

        if identifier == Column.preview {
            let button = NSButton(title: "▶︎ Preview", target: self, action: #selector(previewProfile(_:)))
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.tag = row
            return button
        }

        if identifier == Column.voice {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            let currentVoice = rows[row].profile.voice
            var availableVoices = voiceNames
            if !availableVoices.contains(currentVoice) {
                availableVoices.append(currentVoice)
            }
            popup.addItems(withTitles: availableVoices)
            popup.selectItem(withTitle: currentVoice)
            popup.target = self
            popup.action = #selector(changeVoice(_:))
            popup.tag = row
            popup.controlSize = .small
            return popup
        }

        if identifier == Column.speed {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            let currentSpeed = rows[row].profile.speed
            var availableSpeeds = speedOptions
            if !availableSpeeds.contains(where: { abs($0 - currentSpeed) < 0.001 }) {
                availableSpeeds.append(currentSpeed)
            }
            for speed in availableSpeeds {
                let item = NSMenuItem(title: String(format: "%.2gx", speed), action: nil, keyEquivalent: "")
                item.representedObject = speed
                popup.menu?.addItem(item)
            }
            if let selectedIndex = availableSpeeds.firstIndex(where: { abs($0 - currentSpeed) < 0.001 }) {
                popup.selectItem(at: selectedIndex)
            }
            popup.target = self
            popup.action = #selector(changeSpeed(_:))
            popup.tag = row
            popup.controlSize = .small
            return popup
        }

        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingTail
        if identifier == Column.app {
            field.stringValue = rows[row].profile.appName
        }
        return field
    }

    @objc private func showAddAppMenu(_ sender: NSButton) {
        let existingBundleIDs = Set(rows.map { $0.bundleID })
        let ownBundleID = Bundle.main.bundleIdentifier
        var seenBundleIDs = existingBundleIDs
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> (bundleID: String, name: String)? in
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  let name = app.localizedName,
                  bundleID != ownBundleID,
                  seenBundleIDs.insert(bundleID).inserted else { return nil }
            return (bundleID, name)
        }.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.bundleID < $1.bundleID : order == .orderedAscending
        }

        let menu = NSMenu()
        for app in apps {
            let item = NSMenuItem(title: app.name, action: #selector(addApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.bundleID
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: "No Running Apps Available", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func addApp(_ sender: NSMenuItem) {
        guard let bundleID = sender.representedObject as? String else { return }
        profiles.set(
            bundleID: bundleID,
            appName: sender.title,
            voice: voiceNames.first ?? "af_heart",
            speed: 1.0
        )
        reload()
        if let row = rows.firstIndex(where: { $0.bundleID == bundleID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        }
        onChange()
    }

    @objc private func changeVoice(_ sender: NSPopUpButton) {
        guard rows.indices.contains(sender.tag),
              let voice = sender.titleOfSelectedItem else { return }
        let row = rows[sender.tag]
        profiles.set(
            bundleID: row.bundleID,
            appName: row.profile.appName,
            voice: voice,
            speed: row.profile.speed
        )
        reload()
        onChange()
    }

    @objc private func changeSpeed(_ sender: NSPopUpButton) {
        guard rows.indices.contains(sender.tag),
              let speed = sender.selectedItem?.representedObject as? Float else { return }
        let row = rows[sender.tag]
        profiles.set(
            bundleID: row.bundleID,
            appName: row.profile.appName,
            voice: row.profile.voice,
            speed: speed
        )
        reload()
        onChange()
    }

    @objc private func previewProfile(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let profile = rows[sender.tag].profile
        onPreview(profile.voice, profile.speed)
    }

    @objc private func removeProfile(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag) else { return }
        profiles.remove(bundleID: rows[sender.tag].bundleID)
        reload()
        onChange()
    }
}

// MARK: - Pronunciations window

@MainActor
private final class PronunciationsEditor: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private enum Column {
        static let word = NSUserInterfaceItemIdentifier("pronunciationWord")
        static let respelling = NSUserInterfaceItemIdentifier("pronunciationRespelling")
    }

    private let pronunciations: Pronunciations
    private let window: NSWindow
    private let tableView = NSTableView()
    private var removeButton: NSButton!
    private var rows: [(key: String, value: String)]

    init(pronunciations: Pronunciations) {
        self.pronunciations = pronunciations
        rows = pronunciations.entries
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 410),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureWindow()
    }

    func show() {
        rows = pronunciations.entries
        tableView.reloadData()
        updateRemoveButton()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func configureWindow() {
        window.title = "Pronunciations"
        window.center()
        window.isReleasedWhenClosed = false

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)

        let heading = NSTextField(labelWithString: "Pronunciation Dictionary")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)

        let body = NSTextField(wrappingLabelWithString:
            "Add words Orator should say differently. For example, enter “nginx” and “engine ex”."
        )
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 492

        let wordColumn = NSTableColumn(identifier: Column.word)
        wordColumn.title = "Word"
        wordColumn.width = 236
        wordColumn.minWidth = 140

        let respellingColumn = NSTableColumn(identifier: Column.respelling)
        respellingColumn.title = "Say it like"
        respellingColumn.width = 256
        respellingColumn.minWidth = 160

        tableView.addTableColumn(wordColumn)
        tableView.addTableColumn(respellingColumn)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 26
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.widthAnchor.constraint(equalToConstant: 492).isActive = true
        scrollView.heightAnchor.constraint(equalToConstant: 238).isActive = true

        let addButton = NSButton(title: "Add", target: self, action: #selector(addEntry))
        addButton.bezelStyle = .rounded
        removeButton = NSButton(title: "Remove", target: self, action: #selector(removeEntry))
        removeButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        content.addArrangedSubview(heading)
        content.addArrangedSubview(body)
        content.addArrangedSubview(scrollView)
        content.addArrangedSubview(buttons)

        window.contentView = content
        updateRemoveButton()
    }

    @objc private func addEntry() {
        rows.append((key: "", value: ""))
        tableView.reloadData()

        let row = rows.count - 1
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        tableView.editColumn(0, row: row, with: nil, select: true)
    }

    @objc private func removeEntry() {
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }

        let key = rows[row].key
        if !key.isEmpty {
            pronunciations.remove(key: key)
        }
        rows.remove(at: row)
        tableView.reloadData()

        if !rows.isEmpty {
            let nextRow = min(row, rows.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        }
        updateRemoveButton()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }

        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField()
            field.identifier = identifier
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.delegate = self
            field.cell?.isScrollable = true
            field.cell?.wraps = false
        }

        if identifier == Column.word {
            field.stringValue = rows[row].key
            field.placeholderString = "e.g. nginx"
        } else {
            field.stringValue = rows[row].value
            field.placeholderString = "e.g. engine ex"
        }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveButton()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let row = tableView.row(for: field)
        let column = tableView.column(for: field)
        guard rows.indices.contains(row), tableView.tableColumns.indices.contains(column) else { return }

        let oldKey = rows[row].key
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.stringValue = value

        if tableView.tableColumns[column].identifier == Column.word {
            rows[row].key = value
        } else {
            rows[row].value = value
        }

        let newKey = rows[row].key
        if oldKey != newKey, !oldKey.isEmpty {
            pronunciations.remove(key: oldKey)
        }

        if newKey.isEmpty || rows[row].value.isEmpty {
            if oldKey == newKey, !oldKey.isEmpty {
                pronunciations.remove(key: oldKey)
            }
        } else {
            pronunciations.add(key: newKey, value: rows[row].value)
        }
    }

    private func updateRemoveButton() {
        removeButton?.isEnabled = tableView.selectedRow >= 0
    }
}
