import Cocoa
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers

extension Notification.Name {
    static let oratorAutoCastChanged = Notification.Name("OratorAutoCastChanged")
}

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
    private var oratorWindowController: OratorWindowController?
    private var readerWindowController: ReaderWindowController?
    private var statusItemDropTarget: FileDropTargetView?
    private var previewAudioPlayer: AVAudioPlayer?
    private var isPreviewRenderInFlight = false
    private var lastReadApp: (bundleID: String, name: String)?
    private var readingQueue: [String] = []
    private var queuePlaybackActive = false
    private var continuousReading: Bool = true

    private let defaults = UserDefaults.standard
    private let appProfiles = AppVoiceProfiles()
    private let history = ReadingHistory()
    private let stats = ReadingStats()
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
        static let castGender = "castGender"
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
        static let hotkeyDramatizeKeyCode = "hotkeyDramatizeKeyCode"
        static let hotkeyDramatizeModifiers = "hotkeyDramatizeModifiers"
        static let hotkeyDramatizeDisplay = "hotkeyDramatizeDisplay"
    }
    private static let speedOptions: [Float] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5]

    // Option + ' (US keyboard apostrophe = keyCode 39)
    static let hotKeyLabel = "⌥'"

    // MARK: - Launch

    private var serviceProvider: OratorServiceProvider?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        setupStatusItem()
        loadEngineAsync()
        registerServices()

        if AXIsProcessTrusted() {
            installKeyMonitor()
        } else {
            showOnboarding()
            startTrustPolling()
        }

        NotificationCenter.default.addObserver(
            forName: .oratorSpeechStarted, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateIcon(speaking: true)
                self?.rebuildMenu()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .oratorSpeechFinished, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine?.isSpeaking == false else { return }
                self.updateIcon(speaking: false)
                self.rebuildMenu()
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
                    self.oratorWindowController?.refresh()
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
                case .dramatize: self?.toggleAutoCast()
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
            .dramatize: .init(
                keyCode: Pref.hotkeyDramatizeKeyCode,
                modifiers: Pref.hotkeyDramatizeModifiers,
                display: Pref.hotkeyDramatizeDisplay
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
            let castGender = DialogueCaster.CastGender(
                rawValue: defaults.string(forKey: Pref.castGender) ?? "auto"
            ) ?? .auto
            let segments = DialogueCaster.cast(
                text: text,
                narratorVoice: engine.currentVoice,
                pool: engine.voiceNames,
                castGender: castGender
            )
            try timeline.speak(segments: segments)
        } else {
            try timeline.speak(text: text)
        }
    }

    private func recordHistory(_ text: String) {
        guard rememberHistory else { return }
        history.add(text)
        // Reading stats share the "remember my reading" switch. Cast reads are
        // not produced by the features on this branch.
        stats.record(
            text: text,
            sourceApp: lastReadApp?.name,
            voiceName: engine?.currentVoice ?? "af_heart",
            cast: false,
            speed: engine?.speed ?? 1.0
        )
        oratorWindowController?.refreshDashboard()
        rebuildMenu()
    }

    /// Snapshot of local reading stats for the Dashboard and the menu teaser.
    var statsSnapshot: ReadingStatsSnapshot { stats.snapshot() }
    var reading: ReadingStats { stats }

    // MARK: - Orator window settings bridge

    var availableVoiceNames: [String] { engine?.voiceNames ?? [] }
    var autoCastEnabled: Bool { defaults.bool(forKey: Pref.autoCast) }
    var castGender: String { defaults.string(forKey: Pref.castGender) ?? "auto" }
    func setCastGender(_ rawValue: String) {
        defaults.set(rawValue, forKey: Pref.castGender)
    }
    var selectedVoiceName: String { engine?.currentVoice ?? defaults.string(forKey: Pref.voice) ?? "af_heart" }
    var selectedSpeed: Float {
        if let engine { return engine.speed }
        let saved = defaults.float(forKey: Pref.speed)
        return saved > 0 ? saved : 1.0
    }
    var availableSpeedOptions: [Float] { Self.speedOptions }
    var startAtLoginEnabled: Bool { SMAppService.mainApp.status == .enabled }
    var remembersReading: Bool { rememberHistory }
    var continuousReadingEnabled: Bool { continuousReading }
    var recentReadingEntries: [HistoryEntry] { history.entries }

    func setSelectedVoice(_ name: String) {
        guard let engine, engine.voiceNames.contains(name) else { return }
        queuePlaybackActive = false
        engine.stop()
        engine.currentVoice = name
        defaults.set(name, forKey: Pref.voice)
        rebuildMenu()
    }

    func setSelectedSpeed(_ value: Float) {
        guard let engine, Self.speedOptions.contains(where: { abs($0 - value) < 0.001 }) else { return }
        engine.speed = value
        defaults.set(value, forKey: Pref.speed)
        rebuildMenu()
    }

    func updateWeeklyGoalWords(_ words: Int) -> ReadingStatsSnapshot {
        reading.weeklyGoalWords = max(0, words)
        let updated = statsSnapshot
        rebuildMenu()
        return updated
    }

    func setStartAtLogin(_ enabled: Bool) {
        do {
            if enabled, SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            } else if !enabled, SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Orator: login item update failed: %@", error.localizedDescription)
        }
        rebuildMenu()
    }

    func setRemembersReading(_ enabled: Bool) {
        rememberHistory = enabled
        defaults.set(enabled, forKey: Pref.rememberHistory)
        rebuildMenu()
    }

    func setContinuousReading(_ enabled: Bool) {
        continuousReading = enabled
        defaults.set(enabled, forKey: Pref.continuousReading)
        rebuildMenu()
    }

    func clearReadingHistory() {
        history.clear()
        rebuildMenu()
    }

    func clearReadingStats() {
        reading.clear()
        oratorWindowController?.refreshDashboard()
        rebuildMenu()
    }

    func speakHistoryText(_ text: String) {
        guard let timeline else { return }
        do { try timeline.speak(text: text) }
        catch { oratorLog("history speak FAILED: \(error.localizedDescription)") }
    }

    /// Script mode's only playback bridge; parsing and casting stay outside the engine.
    func speakScriptSegments(_ segments: [SpeechSegment]) throws {
        guard let timeline else {
            throw NSError(
                domain: "Orator.ScriptMode",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The speech engine is still loading"]
            )
        }
        try timeline.speak(segments: segments)
    }

    func makePronunciationsContentView() -> NSView {
        if pronunciationsEditor == nil {
            pronunciationsEditor = PronunciationsEditor(pronunciations: .shared)
        }
        return pronunciationsEditor!.makeContentView()
    }

    func refreshPronunciationsEditor() {
        pronunciationsEditor?.reload()
    }

    func makeShortcutsContentView() -> NSView {
        ensureHotkeyRecorder()
        return hotkeyRecorderWindowController!.makeContentView()
    }

    func refreshShortcutsEditor() {
        hotkeyRecorderWindowController?.refresh()
    }

    func stopShortcutRecording() {
        hotkeyRecorderWindowController?.stopRecording()
    }

    func makeAppVoiceProfilesContentView() -> NSView {
        ensureAppVoiceProfilesEditor()
        appVoiceProfilesEditor?.updateVoiceNames(availableVoiceNames)
        return appVoiceProfilesEditor!.makeContentView()
    }

    func refreshAppVoiceProfilesEditor() {
        appVoiceProfilesEditor?.updateVoiceNames(availableVoiceNames)
        appVoiceProfilesEditor?.reload()
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

        if let button = statusItem.button {
            button.registerForDraggedTypes([.fileURL])
            let dropTarget = FileDropTargetView(frame: button.bounds)
            dropTarget.autoresizingMask = [.width, .height]
            dropTarget.forwardsClicksTo = button
            dropTarget.onDrop = { [weak self] urls in
                self?.readFiles(urls)
            }
            button.addSubview(dropTarget)
            statusItemDropTarget = dropTarget
        }
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
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "Orator", action: nil, keyEquivalent: "")
        title.image = Self.menuBarIdleIcon
        title.isEnabled = false
        // Show the version right in the header so a bug report can name it at a glance.
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let headerText = NSMutableAttributedString(
            string: "Orator",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        )
        headerText.append(NSAttributedString(
            string: "  v\(appVersion)",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        title.attributedTitle = headerText
        menu.addItem(title)

        let status: String
        if let err = engineError {
            status = "⚠️ \(err)"
        } else if engine == nil {
            status = "Loading voices…"
        } else if !AXIsProcessTrusted() {
            status = "⚠️ Needs Accessibility permission"
        } else if engine?.isPaused == true {
            status = "Paused"
        } else if engine?.isSpeaking == true {
            status = "Reading"
        } else {
            status = "Ready — select text, press \(Self.hotKeyLabel)"
        }
        let statusLine = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        if engine?.isSpeaking == true,
           let current = timeline?.current,
           current.chunks.indices.contains(current.baseIndex) {
            let prefix = queueItemTitle(for: current.chunks[current.baseIndex])
            let nowReading = NSMenuItem(title: "Now reading: \(prefix)", action: nil, keyEquivalent: "")
            nowReading.isEnabled = false
            menu.addItem(nowReading)
        }

        if !AXIsProcessTrusted() {
            let fix = NSMenuItem(title: "Grant Permission…", action: #selector(openOnboarding), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }
        menu.addItem(.separator())

        if engine != nil {
            // Open Reader is the flagship entry point - promote it to the very
            // top, larger and bolder, with the reader glyph, set apart by its
            // own separator.
            let openReader = NSMenuItem(title: "Open Reader…", action: #selector(openReader), keyEquivalent: "")
            openReader.target = self
            openReader.image = NSImage(systemSymbolName: "book.pages", accessibilityDescription: nil)
            openReader.attributedTitle = NSAttributedString(
                string: "Open Reader…",
                attributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]
            )
            menu.addItem(openReader)
            menu.addItem(.separator())

            let readFile = NSMenuItem(
                title: "Read File…",
                action: #selector(readFile),
                keyEquivalent: ""
            )
            readFile.target = self
            menu.addItem(readFile)

            let speakClipboard = NSMenuItem(
                title: "Speak Clipboard (\(hotkeyDisplay(for: .speak)))",
                action: #selector(speakClipboardText),
                keyEquivalent: ""
            )
            speakClipboard.target = self
            menu.addItem(speakClipboard)

            let pauseActionTitle = engine?.isPaused == true ? "Resume Speaking" : "Pause Speaking"
            let pauseTitle = "\(pauseActionTitle) (\(hotkeyDisplay(for: .pause)))"
            let pauseItem = NSMenuItem(title: pauseTitle, action: #selector(pauseResumeSpeaking), keyEquivalent: "")
            pauseItem.target = self
            pauseItem.isEnabled = engine?.isSpeaking == true || engine?.isPaused == true
            menu.addItem(pauseItem)

            let stopItem = NSMenuItem(title: "Stop", action: #selector(stopSpeaking), keyEquivalent: "")
            stopItem.target = self
            stopItem.isEnabled = engine?.isSpeaking == true || engine?.isPaused == true
            menu.addItem(stopItem)
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

            for (index, text) in readingQueue.enumerated() {
                // Clicking a queued item removes it. The ✕ + tooltip make the
                // "click to remove" affordance discoverable.
                let item = NSMenuItem(
                    title: "✕  \(queueItemTitle(for: text))",
                    action: #selector(removeQueueItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = index
                item.toolTip = "Remove this item from the queue"
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

        menu.addItem(.separator())

        let autoCast = NSMenuItem(
            title: "Dramatized reading",
            action: #selector(toggleAutoCast),
            keyEquivalent: ""
        )
        autoCast.target = self
        autoCast.state = defaults.bool(forKey: Pref.autoCast) ? .on : .off
        menu.addItem(autoCast)
        menu.addItem(.separator())

        let snapshot = statsSnapshot
        let teaserItem = NSMenuItem()
        let teaser = MenuStatsTeaser(
            snapshot: snapshot,
            target: self,
            action: #selector(openDashboard)
        )
        teaser.menuItem = teaserItem
        teaserItem.view = teaser
        menu.addItem(teaserItem)
        menu.addItem(.separator())

        let dashboard = NSMenuItem(
            title: "Dashboard…",
            action: #selector(openDashboard),
            keyEquivalent: "d"
        )
        dashboard.target = self
        menu.addItem(dashboard)

        let settings = NSMenuItem(
            title: "Orator Settings…",
            action: #selector(openOratorSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Orator", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func displayName(for voice: String) -> String {
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

    @objc private func openDashboard() {
        showOratorWindow(tab: .dashboard)
    }

    @objc private func openOratorSettings() {
        showOratorWindow(tab: .voices)
    }

    private func showOratorWindow(tab: OratorTab) {
        if oratorWindowController == nil {
            oratorWindowController = OratorWindowController(appDelegate: self)
        }
        oratorWindowController?.show(tab: tab)
    }

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        setSelectedVoice(name)
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Float else { return }
        setSelectedSpeed(value)
    }

    @objc private func toggleAutoCast() {
        setAutoCast(!defaults.bool(forKey: Pref.autoCast))
    }

    func setAutoCast(_ enabled: Bool) {
        defaults.set(enabled, forKey: Pref.autoCast)
        rebuildMenu()
        NotificationCenter.default.post(name: .oratorAutoCastChanged, object: nil)
    }

    @objc private func openPronunciations() {
        if pronunciationsEditor == nil {
            pronunciationsEditor = PronunciationsEditor(pronunciations: .shared)
        }
        pronunciationsEditor?.show()
    }

    @objc private func openHotkeyRecorder() {
        ensureHotkeyRecorder()
        hotkeyRecorderWindowController?.show()
    }

    private func ensureHotkeyRecorder() {
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
        ensureAppVoiceProfilesEditor()
        appVoiceProfilesEditor?.show()
    }

    private func ensureAppVoiceProfilesEditor() {
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
        setStartAtLogin(!startAtLoginEnabled)
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
        setContinuousReading(!continuousReading)
    }

    @objc private func readHistoryEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        speakHistoryText(text)
    }

    @objc private func toggleRememberHistory() {
        setRemembersReading(!rememberHistory)
    }

    @objc private func clearHistory() {
        clearReadingHistory()
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

    @objc private func removeQueueItem(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int,
              readingQueue.indices.contains(index) else { return }
        readingQueue.remove(at: index)
        rebuildMenu()
    }

    // MARK: - macOS Services (right-click on a selection)

    /// Register the services provider so the Info.plist NSServices entries
    /// resolve to real handlers, then refresh the system's dynamic services so
    /// they show up without a re-login.
    private func registerServices() {
        let provider = OratorServiceProvider()
        NSApp.servicesProvider = provider
        serviceProvider = provider
        NSUpdateDynamicServices()
    }

    /// Speak text handed over by the "Speak with Orator" Service.
    func serviceSpeak(_ text: String) { speakText(text) }

    /// Queue text handed over by the "Add to Orator Queue" Service.
    func serviceQueue(_ text: String) { addToReadingQueue(text) }

    /// Read files delivered by drag-and-drop or the Finder file Service.
    func serviceReadFiles(_ urls: [URL]) { readFiles(urls) }

    /// Queue files delivered by the Finder file Service.
    func serviceQueueFiles(_ urls: [URL]) { extractFiles(urls, action: .queueAll) }

    @objc private func speakClipboardText() {
        speakClipboard()
    }

    @objc private func openReader() {
        guard let engine, let timeline else { return }

        if timeline.current != nil {
            if readerWindowController == nil {
                readerWindowController = makeReaderWindowController(timeline: timeline, engine: engine)
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
                    self.readerWindowController = self.makeReaderWindowController(
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
                self.readerWindowController = self.makeReaderWindowController(
                    timeline: timeline,
                    engine: engine
                )
            }
            self.readerWindowController?.show(text: text)
        }
    }

    private func makeReaderWindowController(
        timeline: SpeechTimeline,
        engine: OratorEngine
    ) -> ReaderWindowController {
        let controller = ReaderWindowController(timeline: timeline, engine: engine)
        controller.onFilesDropped = { [weak self] urls in
            self?.readFiles(urls)
        }
        return controller
    }

    @objc private func readFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FileTextExtractor.supportedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }

            self.readFiles([url])
        }
    }

    private enum ExtractedFileAction {
        case readFirstAndQueueRest
        case queueAll
    }

    private func readFiles(_ urls: [URL]) {
        extractFiles(urls, action: .readFirstAndQueueRest)
    }

    /// The shared file-intake path. Extraction is deliberately serial so a
    /// multi-file drop or Service invocation preserves Finder's file order.
    private func extractFiles(_ urls: [URL], action: ExtractedFileAction) {
        let supportedURLs = urls.filter(FileTextExtractor.supports)
        guard !supportedURLs.isEmpty else {
            showNotification(
                "Couldn’t read file",
                body: "Choose a PDF, plain-text, Markdown, or RTF file."
            )
            return
        }

        statusItem.button?.toolTip = supportedURLs.count == 1
            ? "Extracting \(supportedURLs[0].lastPathComponent)…"
            : "Extracting \(supportedURLs.count) files…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var extracted: [String] = []
            var failures: [String] = []
            for url in supportedURLs {
                do {
                    extracted.append(try FileTextExtractor.extractText(from: url))
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.statusItem.button?.toolTip = nil
                switch action {
                case .readFirstAndQueueRest:
                    if let first = extracted.first, let timeline = self.timeline {
                        let chunks = TextChunker.chunk(first)
                        self.recordHistory(first)
                        do { try timeline.speak(chunks: chunks, from: 0) }
                        catch { oratorLog("speak FAILED: \(error.localizedDescription)") }
                        for text in extracted.dropFirst() {
                            self.addToReadingQueue(text)
                        }
                    }
                case .queueAll:
                    for text in extracted {
                        self.addToReadingQueue(text)
                    }
                }

                if !failures.isEmpty {
                    self.showNotification("Couldn’t read file", body: failures.joined(separator: "\n"))
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
    private var voiceNames: [String]
    private let speedOptions: [Float]
    private let onPreview: (_ voiceName: String, _ speed: Float) -> Void
    private let onChange: @MainActor () -> Void
    private let window: NSWindow
    private var tableViews: [NSTableView] = []
    private var addButtonTables: [ObjectIdentifier: NSTableView] = [:]
    private weak var pendingSelectionTableView: NSTableView?
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

    func updateVoiceNames(_ names: [String]) {
        voiceNames = names
    }

    func reload() {
        rows = profiles.all
        for tableView in tableViews {
            tableView.reloadData()
        }
    }

    private func configureWindow() {
        window.title = "Per-App Voices"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = makeContentView(
            edgeInsets: NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        )
    }

    /// Creates a distinct control hierarchy for each host. The editor remains
    /// the shared store-backed data source for every table it vends.
    func makeContentView(
        edgeInsets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    ) -> NSView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = edgeInsets

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
        appColumn.width = 140
        appColumn.minWidth = 100

        let voiceColumn = NSTableColumn(identifier: Column.voice)
        voiceColumn.title = "Voice"
        voiceColumn.width = 132
        voiceColumn.minWidth = 100

        let speedColumn = NSTableColumn(identifier: Column.speed)
        speedColumn.title = "Speed"
        speedColumn.width = 64
        speedColumn.minWidth = 54

        let previewColumn = NSTableColumn(identifier: Column.preview)
        previewColumn.title = "Preview"
        previewColumn.width = 78
        previewColumn.minWidth = 72

        let removeColumn = NSTableColumn(identifier: Column.remove)
        removeColumn.title = "Remove"
        removeColumn.width = 76
        removeColumn.minWidth = 70

        let tableView = NSTableView()
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
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let addButton = NSButton(title: "Add App…", target: self, action: #selector(showAddAppMenu(_:)))
        addButton.bezelStyle = .rounded

        content.addArrangedSubview(heading)
        content.addArrangedSubview(body)
        content.addArrangedSubview(scrollView)
        content.addArrangedSubview(addButton)
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(
                equalTo: content.widthAnchor,
                constant: -(edgeInsets.left + edgeInsets.right)
            ),
            scrollView.heightAnchor.constraint(equalToConstant: 240),
        ])

        tableViews.append(tableView)
        addButtonTables[ObjectIdentifier(addButton)] = tableView
        return content
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
        pendingSelectionTableView = addButtonTables[ObjectIdentifier(sender)]
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
            pendingSelectionTableView?.selectRowIndexes(
                IndexSet(integer: row),
                byExtendingSelection: false
            )
            pendingSelectionTableView?.scrollRowToVisible(row)
        }
        pendingSelectionTableView = nil
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

    private struct ViewControls {
        let tableView: NSTableView
        let removeButton: NSButton
    }

    private let pronunciations: Pronunciations
    private let window: NSWindow
    private var viewControls: [ViewControls] = []
    private var buttonTables: [ObjectIdentifier: NSTableView] = [:]
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
        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func reload() {
        rows = pronunciations.entries
        reloadTables()
    }

    private func configureWindow() {
        window.title = "Pronunciations"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = makeContentView(
            edgeInsets: NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        )
    }

    /// Builds fresh controls for a window or tab while keeping all tables
    /// synchronized through Pronunciations.shared.
    func makeContentView(
        edgeInsets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    ) -> NSView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = edgeInsets

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

        let tableView = NSTableView()
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
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let addButton = NSButton(title: "Add", target: self, action: #selector(addEntry(_:)))
        addButton.bezelStyle = .rounded
        let removeButton = NSButton(
            title: "Remove",
            target: self,
            action: #selector(removeEntry(_:))
        )
        removeButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [addButton, removeButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        content.addArrangedSubview(heading)
        content.addArrangedSubview(body)
        content.addArrangedSubview(scrollView)
        content.addArrangedSubview(buttons)
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(
                equalTo: content.widthAnchor,
                constant: -(edgeInsets.left + edgeInsets.right)
            ),
            scrollView.heightAnchor.constraint(equalToConstant: 238),
        ])

        viewControls.append(ViewControls(tableView: tableView, removeButton: removeButton))
        buttonTables[ObjectIdentifier(addButton)] = tableView
        buttonTables[ObjectIdentifier(removeButton)] = tableView
        updateRemoveButtons()
        return content
    }

    @objc private func addEntry(_ sender: NSButton) {
        guard let tableView = buttonTables[ObjectIdentifier(sender)] else { return }
        rows.append((key: "", value: ""))
        reloadTables()

        let row = rows.count - 1
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        tableView.editColumn(0, row: row, with: nil, select: true)
        updateRemoveButtons()
    }

    @objc private func removeEntry(_ sender: NSButton) {
        guard let tableView = buttonTables[ObjectIdentifier(sender)] else { return }
        let row = tableView.selectedRow
        guard rows.indices.contains(row) else { return }

        let key = rows[row].key
        if !key.isEmpty {
            pronunciations.remove(key: key)
        }
        rows.remove(at: row)
        reloadTables()

        if !rows.isEmpty {
            let nextRow = min(row, rows.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        }
        updateRemoveButtons()
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
        updateRemoveButtons()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let tableView = containingTableView(for: field) else { return }
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

        reloadTables(excluding: tableView)
    }

    private func reloadTables(excluding excludedTableView: NSTableView? = nil) {
        for controls in viewControls where controls.tableView !== excludedTableView {
            controls.tableView.reloadData()
        }
        updateRemoveButtons()
    }

    private func updateRemoveButtons() {
        for controls in viewControls {
            controls.removeButton.isEnabled = controls.tableView.selectedRow >= 0
        }
    }

    private func containingTableView(for view: NSView) -> NSTableView? {
        var ancestor: NSView? = view
        while let current = ancestor {
            if let tableView = current as? NSTableView {
                return tableView
            }
            ancestor = current.superview
        }
        return nil
    }
}
