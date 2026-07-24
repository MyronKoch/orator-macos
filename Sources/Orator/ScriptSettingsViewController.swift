import AppKit
import UniformTypeIdentifiers

@MainActor
final class ScriptSettingsViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate
{
    private enum Column {
        static let role = NSUserInterfaceItemIdentifier("ScriptRole")
        static let voice = NSUserInterfaceItemIdentifier("ScriptVoice")
    }

    private unowned let appDelegate: AppDelegate
    private let store = ScriptCastStore()
    private let scriptTextView = NSTextView()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Load or paste a Fountain / NAME: script.")
    private let languageWarning = NSTextField(wrappingLabelWithString: "")
    private let playButton = NSButton(title: "Play Table Read", target: nil, action: nil)
    private let skipHeadings = NSButton(checkboxWithTitle: "Skip scene headings", target: nil, action: nil)
    private let skipParentheticals = NSButton(checkboxWithTitle: "Skip parentheticals", target: nil, action: nil)
    private let skipTransitions = NSButton(checkboxWithTitle: "Skip transitions", target: nil, action: nil)

    private var elements: [ScriptElement] = []
    private var characterNames: [String] = []
    private var contentHash: String?
    private var cast = ScriptCast(characterVoices: [:], narratorVoice: "")

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10

        let heading = NSTextField(labelWithString: "Script")
        heading.font = .systemFont(ofSize: 26, weight: .bold)
        let helper = NSTextField(wrappingLabelWithString: "Load a Fountain or plain-text NAME: script, cast its characters, and play a local table read.")
        helper.font = .systemFont(ofSize: 13)
        helper.textColor = .secondaryLabelColor

        let loadButton = NSButton(title: "Load Script…", target: self, action: #selector(loadScript))
        let analyzeButton = NSButton(title: "Detect Characters", target: self, action: #selector(analyzeText))
        let sourceButtons = NSStackView(views: [loadButton, analyzeButton])
        sourceButtons.orientation = .horizontal
        sourceButtons.spacing = 8

        scriptTextView.isRichText = false
        scriptTextView.isAutomaticQuoteSubstitutionEnabled = false
        scriptTextView.isAutomaticDashSubstitutionEnabled = false
        scriptTextView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scriptTextView.delegate = self
        scriptTextView.textContainerInset = NSSize(width: 7, height: 7)
        scriptTextView.isVerticallyResizable = true
        scriptTextView.isHorizontallyResizable = false
        scriptTextView.autoresizingMask = [.width]
        scriptTextView.textContainer?.widthTracksTextView = true
        let textScroll = NSScrollView()
        textScroll.hasVerticalScroller = true
        textScroll.borderType = .bezelBorder
        textScroll.documentView = scriptTextView

        configureTable()
        let tableScroll = NSScrollView()
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.documentView = tableView

        let castHeading = NSTextField(labelWithString: "Cast")
        castHeading.font = .systemFont(ofSize: 15, weight: .semibold)
        let addButton = NSButton(title: "Add Character…", target: self, action: #selector(addCharacter))

        skipHeadings.state = .on
        skipParentheticals.state = .on
        skipTransitions.state = .on
        for option in [skipHeadings, skipParentheticals, skipTransitions] {
            option.target = self
            option.action = #selector(optionChanged)
        }
        let options = NSStackView(views: [skipHeadings, skipParentheticals, skipTransitions])
        options.orientation = .horizontal
        options.spacing = 12

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        languageWarning.font = .systemFont(ofSize: 11, weight: .medium)
        languageWarning.textColor = .systemOrange
        languageWarning.isHidden = true
        playButton.target = self
        playButton.action = #selector(play)
        playButton.bezelStyle = .rounded
        playButton.keyEquivalent = "\r"

        content.addArrangedSubview(heading)
        content.addArrangedSubview(helper)
        content.addArrangedSubview(sourceButtons)
        content.addArrangedSubview(textScroll)
        content.addArrangedSubview(statusLabel)
        content.setCustomSpacing(16, after: statusLabel)
        content.addArrangedSubview(castHeading)
        content.addArrangedSubview(tableScroll)
        content.addArrangedSubview(addButton)
        content.addArrangedSubview(options)
        content.addArrangedSubview(languageWarning)
        content.addArrangedSubview(playButton)

        for fullWidth in [helper, textScroll, statusLabel, tableScroll, languageWarning] {
            fullWidth.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        textScroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        tableScroll.heightAnchor.constraint(equalToConstant: 190).isActive = true

        view = makeSettingsScrollView(
            hosting: content,
            insets: NSEdgeInsets(top: 24, left: 26, bottom: 28, right: 26)
        )
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        updateState()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { characterNames.count + 1 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier, row >= 0, row <= characterNames.count else {
            return nil
        }
        let role = row == 0 ? "Narrator" : characterNames[row - 1]
        if identifier == Column.role {
            let label = NSTextField(labelWithString: role)
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 12, weight: row == 0 ? .semibold : .regular)
            return label
        }

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.tag = row
        popup.target = self
        popup.action = #selector(changeVoice(_:))
        populate(popup, selectedVoice: row == 0 ? cast.narratorVoice : cast.characterVoices[role])
        return popup
    }

    func textDidChange(_ notification: Notification) {
        statusLabel.stringValue = "Text changed — detect characters to update the cast."
        playButton.isEnabled = false
    }

    private func configureTable() {
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 28
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.dataSource = self
        tableView.delegate = self
        let role = NSTableColumn(identifier: Column.role)
        role.title = "Character"
        role.width = 180
        role.minWidth = 100
        role.resizingMask = .autoresizingMask
        let voice = NSTableColumn(identifier: Column.voice)
        voice.title = "Voice"
        voice.width = 250
        voice.minWidth = 150
        voice.resizingMask = .autoresizingMask
        tableView.addTableColumn(role)
        tableView.addTableColumn(voice)
    }

    private func populate(_ popup: NSPopUpButton, selectedVoice: String?) {
        popup.removeAllItems()
        for voice in appDelegate.availableVoiceNames {
            let item = NSMenuItem(title: appDelegate.displayName(for: voice), action: nil, keyEquivalent: "")
            item.representedObject = voice
            popup.menu?.addItem(item)
        }
        if let selectedVoice,
           let index = popup.menu?.items.firstIndex(where: { ($0.representedObject as? String) == selectedVoice }) {
            popup.selectItem(at: index)
        }
        popup.isEnabled = !appDelegate.availableVoiceNames.isEmpty
    }

    private func setScriptText(_ text: String, sourceName: String? = nil) {
        scriptTextView.string = text
        parseCurrentText(sourceName: sourceName)
    }

    private func parseCurrentText(sourceName: String? = nil) {
        let text = scriptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            elements = []
            characterNames = []
            contentHash = nil
            statusLabel.stringValue = "Paste script text or load a file first."
            tableView.reloadData()
            updateState()
            return
        }

        elements = ScriptParser.parse(text)
        let detected = ScriptParser.characterNames(in: elements)
        let hash = ScriptCastStore.contentHash(for: text)
        contentHash = hash
        let voices = appDelegate.availableVoiceNames
        let restored = store.cast(forContentHash: hash)
        cast = restored ?? ScriptCast(
            characterVoices: [:],
            narratorVoice: appDelegate.selectedVoiceName
        )
        if cast.narratorVoice.isEmpty || !voices.contains(cast.narratorVoice) {
            cast.narratorVoice = appDelegate.selectedVoiceName
        }
        characterNames = detected
        for savedName in cast.characterVoices.keys.sorted()
            where !characterNames.contains(savedName) {
            characterNames.append(savedName)
        }
        for (index, name) in detected.enumerated() where cast.characterVoices[name] == nil {
            if !voices.isEmpty { cast.characterVoices[name] = voices[index % voices.count] }
        }
        persistCast()
        tableView.reloadData()
        let prefix = sourceName.map { "\($0): " } ?? ""
        statusLabel.stringValue = "\(prefix)detected \(detected.count) character\(detected.count == 1 ? "" : "s")."
        updateState()
    }

    private func persistCast() {
        guard let contentHash else { return }
        store.set(contentHash: contentHash, cast: cast)
    }

    private func updateState() {
        let voices = [cast.narratorVoice] + characterNames.compactMap { cast.characterVoices[$0] }
        let families = Set(voices.filter { !$0.isEmpty }.map(voiceFamily))
        languageWarning.isHidden = families.count < 2
        languageWarning.stringValue = families.count < 2 ? "" : "This cast mixes voice language families. Live playback may pause briefly for pronunciation-model reloads; use one family for the smoothest read."
        playButton.isEnabled = contentHash != nil
            && !elements.isEmpty
            && !cast.narratorVoice.isEmpty
            && characterNames.allSatisfy { cast.characterVoices[$0] != nil }
    }

    private func voiceFamily(_ voice: String) -> String {
        guard let first = voice.first else { return voice }
        switch first {
        case "a": return "US"
        case "b": return "GB"
        default: return String(voice.prefix(while: { $0 != "_" }))
        }
    }

    @objc private func loadScript() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["txt", "text", "md", "markdown", "fountain", "rtf", "pdf"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                self.setScriptText(try FileTextExtractor.extractText(from: url), sourceName: url.lastPathComponent)
            } catch {
                self.statusLabel.stringValue = "Couldn’t load script: \(error.localizedDescription)"
            }
        }
    }

    @objc private func analyzeText() { parseCurrentText() }

    @objc private func addCharacter() {
        guard contentHash != nil else {
            statusLabel.stringValue = "Load or detect a script before adding a character."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Add Character"
        alert.informativeText = "Enter the character name used by the script cue."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "CHARACTER NAME"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !name.isEmpty, !characterNames.contains(name) else { return }
        characterNames.append(name)
        if let voice = appDelegate.availableVoiceNames.first { cast.characterVoices[name] = voice }
        persistCast()
        tableView.reloadData()
        updateState()
    }

    @objc private func changeVoice(_ sender: NSPopUpButton) {
        guard let voice = sender.selectedItem?.representedObject as? String else { return }
        if sender.tag == 0 {
            cast.narratorVoice = voice
        } else if characterNames.indices.contains(sender.tag - 1) {
            cast.characterVoices[characterNames[sender.tag - 1]] = voice
        }
        persistCast()
        updateState()
    }

    @objc private func optionChanged() { updateState() }

    @objc private func play() {
        let options = ScriptCaster.Options(
            readSceneHeadings: skipHeadings.state != .on,
            readParentheticals: skipParentheticals.state != .on,
            readTransitions: skipTransitions.state != .on
        )
        let segments = ScriptCaster.cast(elements: elements, cast: cast, options: options)
        guard !segments.isEmpty else {
            statusLabel.stringValue = "Nothing to play with the current cast and skip options."
            return
        }
        do {
            try appDelegate.speakScriptSegments(segments)
            statusLabel.stringValue = "Playing table read."
        } catch {
            statusLabel.stringValue = "Couldn’t start playback: \(error.localizedDescription)"
        }
    }
}
