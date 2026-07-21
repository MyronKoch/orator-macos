import Cocoa

/// Records and resets the global keyboard shortcuts exposed by Orator.
/// The controller owns its local event monitor so closing or cancelling the
/// window cannot leave a recorder active.
@MainActor
final class HotkeyRecorderWindowController: NSWindowController, NSWindowDelegate {

    struct PreferenceKeys {
        let keyCode: String
        let modifiers: String
        let display: String
    }

    private struct Chord {
        let keyCode: UInt16
        let modifiers: NSEvent.ModifierFlags
        let display: String
    }

    private struct RowControls {
        let chordLabel: NSTextField
        let recordButton: NSButton
        let feedbackLabel: NSTextField
    }

    private static let allowedModifiers: NSEvent.ModifierFlags = [
        .command, .option, .control, .shift,
    ]

    private let defaults: UserDefaults
    private let preferenceKeys: [HotkeyAction: PreferenceKeys]
    private let onBindingChanged: @MainActor () -> Void
    private var hotkeyManager: HotkeyManager?
    private var chords: [HotkeyAction: Chord] = [:]
    private var rowSets: [[HotkeyAction: RowControls]] = []
    private var recordingAction: HotkeyAction?
    private var localMonitor: Any?

    init(
        hotkeyManager: HotkeyManager?,
        defaults: UserDefaults,
        preferenceKeys: [HotkeyAction: PreferenceKeys],
        onBindingChanged: @escaping @MainActor () -> Void
    ) {
        self.hotkeyManager = hotkeyManager
        self.defaults = defaults
        self.preferenceKeys = preferenceKeys
        self.onBindingChanged = onBindingChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 310),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        configureWindow(window)
        loadChords()
        refreshRows()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        refreshRows()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        refreshRows()
    }

    /// The manager may be installed after the window is created, once the
    /// user grants Accessibility permission.
    func setHotkeyManager(_ manager: HotkeyManager) {
        hotkeyManager = manager
        for action in HotkeyAction.allCases {
            guard let binding = manager.binding(for: action),
                  let keyCode = binding.keyCode else { continue }
            let modifiers = normalized(binding.modifiers)
            chords[action] = Chord(
                keyCode: keyCode,
                modifiers: modifiers,
                display: displayForCurrentBinding(
                    action: action,
                    keyCode: keyCode,
                    modifiers: modifiers
                )
            )
        }
        refreshRows()
    }

    func windowWillClose(_ notification: Notification) {
        stopRecording()
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = "Keyboard Shortcuts"
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = makeContentView(
            edgeInsets: NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        )
    }

    /// Creates a new recorder hierarchy for each host. All hierarchies share
    /// one recording session and the same HotkeyManager/defaults bindings.
    func makeContentView(
        edgeInsets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    ) -> NSView {
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.edgeInsets = edgeInsets

        let heading = NSTextField(labelWithString: "Keyboard Shortcuts")
        heading.font = .systemFont(ofSize: 20, weight: .semibold)

        let helper = NSTextField(
            wrappingLabelWithString: "Record a shortcut with at least one modifier (⌘ ⌥ ⌃ ⇧). Press Escape to cancel."
        )
        helper.font = .systemFont(ofSize: 12)
        helper.textColor = .secondaryLabelColor
        helper.preferredMaxLayoutWidth = 532

        content.addArrangedSubview(heading)
        content.addArrangedSubview(helper)

        var rows: [HotkeyAction: RowControls] = [:]
        for action in HotkeyAction.allCases {
            let nameLabel = NSTextField(labelWithString: Self.rowTitle(for: action))
            nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
            nameLabel.widthAnchor.constraint(equalToConstant: 190).isActive = true

            let chordLabel = NSTextField(labelWithString: "")
            chordLabel.font = .monospacedSystemFont(ofSize: 15, weight: .medium)
            chordLabel.widthAnchor.constraint(equalToConstant: 100).isActive = true

            let recordButton = NSButton(
                title: "Record",
                target: self,
                action: #selector(beginRecording(_:))
            )
            recordButton.bezelStyle = .rounded
            recordButton.tag = Int(action.carbonID)
            recordButton.widthAnchor.constraint(equalToConstant: 84).isActive = true

            let resetButton = NSButton(
                title: "Reset",
                target: self,
                action: #selector(resetShortcut(_:))
            )
            resetButton.bezelStyle = .rounded
            resetButton.tag = Int(action.carbonID)
            resetButton.widthAnchor.constraint(equalToConstant: 72).isActive = true

            let controls = NSStackView(views: [nameLabel, chordLabel, recordButton, resetButton])
            controls.orientation = .horizontal
            controls.alignment = .centerY
            controls.spacing = 8

            let feedbackLabel = NSTextField(labelWithString: "")
            feedbackLabel.font = .systemFont(ofSize: 11)
            feedbackLabel.textColor = .systemRed
            feedbackLabel.isHidden = true

            let row = NSStackView(views: [controls, feedbackLabel])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 3
            content.addArrangedSubview(row)

            rows[action] = RowControls(
                chordLabel: chordLabel,
                recordButton: recordButton,
                feedbackLabel: feedbackLabel
            )
        }

        rowSets.append(rows)
        refreshRows()
        return content
    }

    @objc private func beginRecording(_ sender: NSButton) {
        guard let action = action(for: sender) else { return }
        stopRecording()
        clearAllFeedback()
        recordingAction = action

        for rows in rowSets {
            for (rowAction, row) in rows {
                row.recordButton.isEnabled = false
                row.recordButton.title = rowAction == action ? "Recording…" : "Record"
            }
        }
        setFeedback("Press a shortcut, or Escape to cancel.", for: action, isError: false)

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let shouldConsume = MainActor.assumeIsolated {
                self?.recordShortcut(from: event) ?? false
            }
            return shouldConsume ? nil : event
        }
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        guard let action = action(for: sender),
              let keys = preferenceKeys[action] else { return }
        stopRecording()
        clearAllFeedback()

        defaults.removeObject(forKey: keys.keyCode)
        defaults.removeObject(forKey: keys.modifiers)
        defaults.removeObject(forKey: keys.display)

        if let chord = Self.defaultChord(for: action) {
            chords[action] = chord
            hotkeyManager?.reconfigure(
                action,
                keyCode: chord.keyCode,
                modifiers: chord.modifiers
            )
        } else {
            chords.removeValue(forKey: action)
            hotkeyManager?.reconfigure(action, keyCode: nil, modifiers: [.option])
        }
        refreshRows()
        onBindingChanged()
    }

    private func recordShortcut(from event: NSEvent) -> Bool {
        guard let action = recordingAction else { return false }

        if event.keyCode == 53 {
            stopRecording()
            setFeedback("Recording canceled.", for: action, isError: false)
            return true
        }

        if Self.isStandaloneModifierKey(event.keyCode) {
            return true
        }

        // Return is rejected before modifier validation so no Return chord can
        // ever reach persistence or HotkeyManager.
        if event.keyCode == 36 {
            setFeedback(
                "Return-based shortcuts interfere with typing.",
                for: action,
                isError: true
            )
            return true
        }

        let modifiers = normalized(event.modifierFlags)
        guard !modifiers.isEmpty else {
            setFeedback("Include at least one modifier (⌘ ⌥ ⌃ ⇧).", for: action, isError: true)
            return true
        }

        if let conflict = conflictingAction(
            for: action,
            keyCode: event.keyCode,
            modifiers: modifiers
        ) {
            setFeedback(
                "Already used by \(Self.conflictName(for: conflict))",
                for: action,
                isError: true
            )
            return true
        }

        guard let keys = preferenceKeys[action] else { return true }
        let display = Self.displayString(for: event, modifiers: modifiers)
        let chord = Chord(keyCode: event.keyCode, modifiers: modifiers, display: display)

        defaults.set(Int(event.keyCode), forKey: keys.keyCode)
        defaults.set(Int(modifiers.rawValue), forKey: keys.modifiers)
        defaults.set(display, forKey: keys.display)
        chords[action] = chord
        hotkeyManager?.reconfigure(action, keyCode: event.keyCode, modifiers: modifiers)

        stopRecording()
        clearFeedback(for: action)
        refreshRows()
        onBindingChanged()
        return true
    }

    private func conflictingAction(
        for action: HotkeyAction,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> HotkeyAction? {
        HotkeyAction.allCases.first { otherAction in
            guard otherAction != action,
                  let other = currentBinding(for: otherAction) else { return false }
            return other.keyCode == keyCode && other.modifiers == modifiers
        }
    }

    private func currentBinding(
        for action: HotkeyAction
    ) -> (keyCode: UInt16, modifiers: NSEvent.ModifierFlags)? {
        if let hotkeyManager, let binding = hotkeyManager.binding(for: action) {
            guard let keyCode = binding.keyCode else { return nil }
            return (keyCode, normalized(binding.modifiers))
        }
        guard let chord = chords[action] else { return nil }
        return (chord.keyCode, chord.modifiers)
    }

    private func loadChords() {
        for action in HotkeyAction.allCases {
            if let chord = persistedChord(for: action) ?? Self.defaultChord(for: action) {
                chords[action] = chord
            } else {
                chords.removeValue(forKey: action)
            }
        }
    }

    private func persistedChord(for action: HotkeyAction) -> Chord? {
        guard let keys = preferenceKeys[action],
              let keyCodeNumber = defaults.object(forKey: keys.keyCode) as? NSNumber,
              let modifiersNumber = defaults.object(forKey: keys.modifiers) as? NSNumber,
              let display = defaults.string(forKey: keys.display),
              keyCodeNumber.uint64Value <= UInt64(UInt16.max) else { return nil }

        let keyCode = UInt16(keyCodeNumber.uint64Value)
        let modifiers = normalized(
            NSEvent.ModifierFlags(rawValue: UInt(modifiersNumber.uint64Value))
        )
        guard keyCode != 36, !modifiers.isEmpty else { return nil }
        return Chord(keyCode: keyCode, modifiers: modifiers, display: display)
    }

    private func refreshRows() {
        for rows in rowSets {
            for action in HotkeyAction.allCases {
                guard let row = rows[action] else { continue }
                if let binding = currentBinding(for: action) {
                    row.chordLabel.stringValue = displayForCurrentBinding(
                        action: action,
                        keyCode: binding.keyCode,
                        modifiers: binding.modifiers
                    )
                    row.chordLabel.textColor = .labelColor
                } else {
                    row.chordLabel.stringValue = "Not set"
                    row.chordLabel.textColor = .secondaryLabelColor
                }
            }
        }
    }

    private func displayForCurrentBinding(
        action: HotkeyAction,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> String {
        if let chord = chords[action],
           chord.keyCode == keyCode,
           chord.modifiers == modifiers {
            return chord.display
        }
        if let defaultChord = Self.defaultChord(for: action),
           defaultChord.keyCode == keyCode, defaultChord.modifiers == modifiers {
            return defaultChord.display
        }
        return Self.modifierDisplay(modifiers) + String(keyCode)
    }

    func stopRecording() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        recordingAction = nil
        for rows in rowSets {
            for row in rows.values {
                row.recordButton.title = "Record"
                row.recordButton.isEnabled = true
            }
        }
    }

    private func clearAllFeedback() {
        for action in HotkeyAction.allCases {
            clearFeedback(for: action)
        }
    }

    private func clearFeedback(for action: HotkeyAction) {
        for rows in rowSets {
            guard let label = rows[action]?.feedbackLabel else { continue }
            label.stringValue = ""
            label.isHidden = true
        }
    }

    private func setFeedback(_ message: String, for action: HotkeyAction, isError: Bool) {
        for rows in rowSets {
            guard let label = rows[action]?.feedbackLabel else { continue }
            label.stringValue = message
            label.textColor = isError ? .systemRed : .secondaryLabelColor
            label.isHidden = false
        }
    }

    private func action(for button: NSButton) -> HotkeyAction? {
        HotkeyAction.from(carbonID: UInt32(button.tag))
    }

    private func normalized(_ modifiers: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        modifiers.intersection(Self.allowedModifiers)
    }

    static func defaultDisplay(for action: HotkeyAction) -> String {
        defaultChord(for: action)?.display ?? "Not set"
    }

    private static func defaultChord(for action: HotkeyAction) -> Chord? {
        switch action {
        case .speak:
            return Chord(keyCode: 39, modifiers: [.option], display: "⌥'")
        case .pause:
            return Chord(keyCode: 35, modifiers: [.option], display: "⌥P")
        case .queue:
            return Chord(keyCode: 12, modifiers: [.option], display: "⌥Q")
        case .dramatize:
            return nil
        }
    }

    private static func rowTitle(for action: HotkeyAction) -> String {
        switch action {
        case .speak: return "Speak selection"
        case .pause: return "Pause / Resume"
        case .queue: return "Add selection to Queue"
        case .dramatize: return "Dramatize dialogue"
        }
    }

    private static func conflictName(for action: HotkeyAction) -> String {
        switch action {
        case .speak: return "Speak"
        case .pause: return "Pause / Resume"
        case .queue: return "Queue"
        case .dramatize: return "Dramatize"
        }
    }

    private static func isStandaloneModifierKey(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 54, 55, 56, 57, 58, 59, 60, 61, 62, 63:
            return true
        default:
            return false
        }
    }

    private static func displayString(
        for event: NSEvent,
        modifiers: NSEvent.ModifierFlags
    ) -> String {
        modifierDisplay(modifiers) + keyDisplay(for: event)
    }

    private static func modifierDisplay(_ modifiers: NSEvent.ModifierFlags) -> String {
        var display = ""
        if modifiers.contains(.command) { display += "⌘" }
        if modifiers.contains(.option) { display += "⌥" }
        if modifiers.contains(.control) { display += "⌃" }
        if modifiers.contains(.shift) { display += "⇧" }
        return display
    }

    private static func keyDisplay(for event: NSEvent) -> String {
        switch event.keyCode {
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "⌫"
        case 71: return "Clear"
        case 76: return "Enter"
        case 117: return "⌦"
        case 115: return "Home"
        case 119: return "End"
        case 116: return "Page Up"
        case 121: return "Page Down"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:
            if let characters = event.charactersIgnoringModifiers?.uppercased(),
               !characters.isEmpty {
                return characters
            }
            return String(event.keyCode)
        }
    }
}
