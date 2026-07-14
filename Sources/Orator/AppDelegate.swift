import Cocoa
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - State

    private var statusItem: NSStatusItem!
    private var engine: OratorEngine?
    private var engineError: String?
    private var hotkeyManager: HotkeyManager?
    private var trustPollTimer: Timer?
    private var onboardingWindow: NSWindow?
    private var onboardingStatusLabel: NSTextField?
    private var pronunciationsEditor: PronunciationsEditor?
    private var appVoiceProfilesEditor: AppVoiceProfilesEditor?
    private var lastReadApp: (bundleID: String, name: String)?

    private let defaults = UserDefaults.standard
    private let appProfiles = AppVoiceProfiles()
    private enum Pref {
        static let voice = "voice"
        static let speed = "speed"
    }
    private static let speedOptions: [Float] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5]

    // Option + ' (US keyboard apostrophe = keyCode 39)
    private let hotKeyCode: UInt16 = 39
    static let hotKeyLabel = "\u{2325} '"

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        ) { [weak self] _ in Task { @MainActor in self?.updateIcon(speaking: false) } }
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
                    engine.currentVoice = self.defaults.string(forKey: Pref.voice) ?? "af_heart"
                    let savedSpeed = self.defaults.float(forKey: Pref.speed)
                    engine.speed = savedSpeed > 0 ? savedSpeed : 1.0
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
        let manager = HotkeyManager { [weak self] in
            Task { @MainActor in self?.toggleSpeech() }
        }
        manager.installAll()
        hotkeyManager = manager
        rebuildMenu()
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

        guard let engine = engine else { oratorLog("toggle: engine nil"); return }

        if engine.isSpeaking {
            oratorLog("toggle: was speaking → stop")
            engine.stop()
            return
        }

        oratorLog("toggle: capturing selection…")
        captureSelectedText { [weak self] text in
            guard let self = self, let engine = self.engine else { return }
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

            DispatchQueue.global(qos: .userInitiated).async {
                do { try engine.speak(text) }
                catch { oratorLog("speak FAILED: \(error.localizedDescription)") }
            }
        }
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

    private func updateIcon(speaking: Bool) {
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
        menu.addItem(.separator())

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

        // Voice picker
        if let engine = engine {
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

            let perAppVoices = NSMenuItem(
                title: "Per-App Voices…",
                action: #selector(openPerAppVoices),
                keyEquivalent: ""
            )
            perAppVoices.target = self
            menu.addItem(perAppVoices)

            let pronunciations = NSMenuItem(
                title: "Pronunciations…",
                action: #selector(openPronunciations),
                keyEquivalent: ""
            )
            pronunciations.target = self
            menu.addItem(pronunciations)
            menu.addItem(.separator())

            let speakClipboard = NSMenuItem(title: "Speak Clipboard", action: #selector(speakClipboardText), keyEquivalent: "")
            speakClipboard.target = self
            menu.addItem(speakClipboard)

            let exportSelection = NSMenuItem(
                title: "Export Selection to Audio…",
                action: #selector(exportSelectionToAudio),
                keyEquivalent: ""
            )
            exportSelection.target = self
            menu.addItem(exportSelection)

            let exportClipboard = NSMenuItem(
                title: "Export Clipboard to Audio…",
                action: #selector(exportClipboardToAudio),
                keyEquivalent: ""
            )
            exportClipboard.target = self
            menu.addItem(exportClipboard)

            let speakTest = NSMenuItem(title: "Speak Test Sentence", action: #selector(speakTestSentence), keyEquivalent: "")
            speakTest.target = self
            menu.addItem(speakTest)

            let stopItem = NSMenuItem(title: "Stop Speaking", action: #selector(stopSpeaking), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
            menu.addItem(.separator())
        }

        // Login item toggle
        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
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

    // MARK: - Menu actions

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let engine = engine else { return }
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

    @objc private func openPronunciations() {
        if pronunciationsEditor == nil {
            pronunciationsEditor = PronunciationsEditor(pronunciations: .shared)
        }
        pronunciationsEditor?.show()
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
                speedOptions: Self.speedOptions
            ) { [weak self] in
                self?.rebuildMenu()
            }
        }
        appVoiceProfilesEditor?.show()
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

    @objc private func speakClipboardText() {
        guard let engine = engine,
              let text = NSPasteboard.general.string(forType: .string) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do { try engine.speak(text) }
            catch { NSLog("Orator: speak failed: %@", error.localizedDescription) }
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
        guard let engine = engine else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do { try engine.speak("Hello! Orator is working. Select any text and press option apostrophe to hear it read aloud.") }
            catch { NSLog("Orator: test speak failed: %@", error.localizedDescription) }
        }
    }

    @objc private func stopSpeaking() {
        engine?.stop()
    }

    @objc private func openOnboarding() {
        showOnboarding()
        if trustPollTimer == nil { startTrustPolling() }
    }

    @objc private func quit() {
        engine?.stop()
        NSApp.terminate(nil)
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
        static let remove = NSUserInterfaceItemIdentifier("appVoiceProfileRemove")
    }

    private let profiles: AppVoiceProfiles
    private let voiceNames: [String]
    private let speedOptions: [Float]
    private let onChange: @MainActor () -> Void
    private let window: NSWindow
    private let tableView = NSTableView()
    private var rows: [(bundleID: String, profile: Profile)]

    init(
        profiles: AppVoiceProfiles,
        voiceNames: [String],
        speedOptions: [Float],
        onChange: @escaping @MainActor () -> Void
    ) {
        self.profiles = profiles
        self.voiceNames = voiceNames
        self.speedOptions = speedOptions
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

        let removeColumn = NSTableColumn(identifier: Column.remove)
        removeColumn.title = "Remove"
        removeColumn.width = 90
        removeColumn.minWidth = 80

        tableView.addTableColumn(appColumn)
        tableView.addTableColumn(voiceColumn)
        tableView.addTableColumn(speedColumn)
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
