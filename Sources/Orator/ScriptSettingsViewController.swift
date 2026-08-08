import AppKit
import UniformTypeIdentifiers

@MainActor
final class ScriptSettingsViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate
{
    private enum Column {
        static let role = NSUserInterfaceItemIdentifier("ScriptRole")
        static let voice = NSUserInterfaceItemIdentifier("ScriptVoice")
        static let speed = NSUserInterfaceItemIdentifier("ScriptSpeed")
    }

    private unowned let appDelegate: AppDelegate
    private let store = ScriptCastStore()
    private let scriptTextView = NSTextView()
    private let tableView = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Load or paste a Fountain / NAME: script.")
    private let languageWarning = NSTextField(wrappingLabelWithString: "")
    private let samplePopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let overallSpeedSlider = NSSlider()
    private let overallSpeedLabel = NSTextField(labelWithString: "")
    private let playButton = NSButton(title: "Play Table Read", target: nil, action: nil)
    private let skipHeadings = NSButton(checkboxWithTitle: "Skip scene headings", target: nil, action: nil)
    private let skipParentheticals = NSButton(checkboxWithTitle: "Skip parentheticals", target: nil, action: nil)
    private let skipTransitions = NSButton(checkboxWithTitle: "Skip transitions", target: nil, action: nil)
    private let timelineView = TimelineView()
    private lazy var timelineAudio: TimelineAudio? = appDelegate.makeTimelineAudio()
    private var timelineScrollView: NSScrollView
    private var playheadTimer: Timer?
    private let buildTimelineButton = NSButton(title: "Build Timeline", target: nil, action: nil)
    private let playTimelineButton = NSButton(title: "Play Timeline", target: nil, action: nil)
    private let stopTimelineButton = NSButton(title: "Stop", target: nil, action: nil)
    private let exportTimelineButton = NSButton(title: "Export Audio…", target: nil, action: nil)
    private let zoomInTimelineButton = NSButton(title: "+", target: nil, action: nil)
    private let zoomOutTimelineButton = NSButton(title: "-", target: nil, action: nil)
    private let timelineStatus = NSTextField(labelWithString: "")

    private var elements: [ScriptElement] = []
    private var characterNames: [String] = []
    private var contentHash: String?
    private var cast = ScriptCast(characterVoices: [:], narratorVoice: "")

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        timelineScrollView = NSScrollView()
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

        // Pull-down (not a selection popup): picking an item is an action that
        // loads a script, so nothing should stay "selected" afterwards.
        samplePopup.pullsDown = true
        samplePopup.addItem(withTitle: "Sample Scripts")
        for sample in SampleScripts.all {
            samplePopup.addItem(withTitle: "\(sample.title)  —  \(sample.subtitle)")
        }
        samplePopup.target = self
        samplePopup.action = #selector(loadSample)
        samplePopup.toolTip = "Load a short built-in script to try a table read"

        let sourceButtons = NSStackView(views: [loadButton, analyzeButton, samplePopup])
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

        // Script-wide multiplier applied on top of each character's own pace,
        // so the whole read can be sped up without re-tuning every row.
        overallSpeedSlider.minValue = Double(ScriptCast.minSpeed)
        overallSpeedSlider.maxValue = Double(ScriptCast.maxSpeed)
        overallSpeedSlider.floatValue = cast.overallSpeed
        overallSpeedSlider.isContinuous = true
        overallSpeedSlider.controlSize = .small
        overallSpeedSlider.target = self
        overallSpeedSlider.action = #selector(changeOverallSpeed(_:))
        overallSpeedSlider.setAccessibilityLabel("Overall table read speed")
        overallSpeedSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        overallSpeedLabel.font = .systemFont(ofSize: 11)
        overallSpeedLabel.textColor = .secondaryLabelColor
        let overallStack = NSStackView(views: [overallSpeedSlider, overallSpeedLabel])
        overallStack.orientation = .horizontal
        overallStack.alignment = .centerY
        overallStack.spacing = 8

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        languageWarning.font = .systemFont(ofSize: 11, weight: .medium)
        languageWarning.textColor = .systemOrange
        languageWarning.isHidden = true
        playButton.target = self
        playButton.action = #selector(play)
        playButton.bezelStyle = .rounded
        playButton.keyEquivalent = "\r"

        let timelineHeading = NSTextField(labelWithString: "Timeline")
        timelineHeading.font = .systemFont(ofSize: 15, weight: .semibold)
        buildTimelineButton.target = self
        buildTimelineButton.action = #selector(buildTimeline)
        playTimelineButton.target = self
        playTimelineButton.action = #selector(playTimeline)
        stopTimelineButton.target = self
        stopTimelineButton.action = #selector(stopTimeline)
        exportTimelineButton.target = self
        exportTimelineButton.action = #selector(exportTimeline)
        zoomInTimelineButton.target = self
        zoomInTimelineButton.action = #selector(zoomInTimeline)
        zoomOutTimelineButton.target = self
        zoomOutTimelineButton.action = #selector(zoomOutTimeline)
        timelineStatus.font = .systemFont(ofSize: 11)
        timelineStatus.textColor = .secondaryLabelColor
        timelineStatus.lineBreakMode = .byTruncatingTail
        timelineStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let timelineHeader = NSStackView(views: [
            buildTimelineButton,
            playTimelineButton,
            stopTimelineButton,
            exportTimelineButton,
            zoomInTimelineButton,
            zoomOutTimelineButton,
            timelineStatus,
        ])
        timelineHeader.orientation = .horizontal
        timelineHeader.alignment = .centerY
        timelineHeader.spacing = 8

        timelineView.envelopeProvider = { [weak self] clip, buckets in
            self?.timelineAudio?.envelope(for: clip, buckets: buckets) ?? []
        }
        timelineView.onTimelineChanged = { [weak self] updated in
            self?.timelineChanged(updated)
        }
        timelineView.onScrub = { [weak self] ms in
            self?.timelineView.playheadMS = ms
        }
        timelineView.onEditClip = { [weak self] id in
            self?.editClip(id)
        }
        timelineScrollView.hasHorizontalScroller = true
        timelineScrollView.hasVerticalScroller = true
        timelineScrollView.borderType = .bezelBorder
        timelineScrollView.documentView = timelineView
        timelineView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            timelineView.leadingAnchor.constraint(equalTo: timelineScrollView.contentView.leadingAnchor),
            timelineView.topAnchor.constraint(equalTo: timelineScrollView.contentView.topAnchor),
            timelineView.widthAnchor.constraint(greaterThanOrEqualTo: timelineScrollView.contentView.widthAnchor),
            timelineView.heightAnchor.constraint(greaterThanOrEqualTo: timelineScrollView.contentView.heightAnchor),
        ])

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
        content.addArrangedSubview(overallStack)
        content.addArrangedSubview(languageWarning)
        content.addArrangedSubview(playButton)
        content.setCustomSpacing(16, after: playButton)
        content.addArrangedSubview(timelineHeading)
        content.addArrangedSubview(timelineHeader)
        content.addArrangedSubview(timelineScrollView)

        for fullWidth in [
            helper, textScroll, statusLabel, tableScroll, languageWarning,
            timelineHeader, timelineScrollView,
        ] {
            fullWidth.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        textScroll.heightAnchor.constraint(equalToConstant: 170).isActive = true
        tableScroll.heightAnchor.constraint(equalToConstant: 190).isActive = true
        timelineScrollView.heightAnchor.constraint(equalToConstant: 240).isActive = true

        view = makeSettingsScrollView(
            hosting: content,
            insets: NSEdgeInsets(top: 24, left: 26, bottom: 28, right: 26)
        )
        refresh()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        playheadTimer?.invalidate()
        playheadTimer = nil
    }

    func refresh() {
        guard isViewLoaded else { return }
        tableView.reloadData()
        overallSpeedSlider.floatValue = ScriptCast.clamp(cast.overallSpeed)
        updateOverallSpeedLabel()
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

        if identifier == Column.speed {
            // A draggable slider rather than a stepper: pace is a feel you tune
            // by ear, and dragging lets you sweep the range instead of clicking
            // toward it. The live readout is the label beside it.
            let slider = NSSlider(
                value: Double(row == 0 ? cast.narratorSpeed : cast.speed(forCharacter: role)),
                minValue: Double(ScriptCast.minSpeed),
                maxValue: Double(ScriptCast.maxSpeed),
                target: self,
                action: #selector(changeSpeed(_:))
            )
            slider.tag = row
            slider.isContinuous = true
            slider.controlSize = .small
            slider.setAccessibilityLabel("\(role) speaking speed")

            let readout = NSTextField(labelWithString: "")
            readout.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            readout.textColor = .secondaryLabelColor
            readout.alignment = .right
            readout.identifier = Self.speedReadoutID
            readout.stringValue = Self.speedText(slider.floatValue)
            readout.setContentHuggingPriority(.required, for: .horizontal)

            let stack = NSStackView(views: [slider, readout])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 6
            return stack
        }

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.tag = row
        popup.target = self
        popup.action = #selector(changeVoice(_:))
        populate(popup, selectedVoice: row == 0 ? cast.narratorVoice : cast.characterVoices[role])
        return popup
    }

    private static let speedReadoutID = NSUserInterfaceItemIdentifier("speedReadout")

    private static func speedText(_ speed: Float) -> String {
        String(format: "%.2f×", speed)
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
        voice.width = 220
        voice.minWidth = 140
        voice.resizingMask = .autoresizingMask
        let speed = NSTableColumn(identifier: Column.speed)
        speed.title = "Speed"
        speed.width = 150
        speed.minWidth = 120
        speed.resizingMask = .autoresizingMask
        tableView.addTableColumn(role)
        tableView.addTableColumn(voice)
        tableView.addTableColumn(speed)
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

    /// Load a built-in sample. Index 0 is the pull-down's own title, so the
    /// samples start at 1.
    @objc private func loadSample() {
        let index = samplePopup.indexOfSelectedItem - 1
        guard SampleScripts.all.indices.contains(index) else { return }
        let sample = SampleScripts.all[index]
        setScriptText(sample.text, sourceName: sample.title)
    }

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

    @objc private func changeSpeed(_ sender: NSSlider) {
        let value = ScriptCast.clamp(sender.floatValue)
        if sender.tag == 0 {
            cast.narratorSpeed = value
        } else if characterNames.indices.contains(sender.tag - 1) {
            cast.characterSpeeds[characterNames[sender.tag - 1]] = value
        }
        // Update the readout beside this slider without reloading the table,
        // so the drag is not interrupted mid-gesture.
        if let stack = sender.superview as? NSStackView,
           let readout = stack.arrangedSubviews
               .compactMap({ $0 as? NSTextField })
               .first(where: { $0.identifier == Self.speedReadoutID }) {
            readout.stringValue = Self.speedText(value)
        }
        persistCast()
        updateOverallSpeedLabel()
    }

    @objc private func changeOverallSpeed(_ sender: NSSlider) {
        cast.overallSpeed = ScriptCast.clamp(sender.floatValue)
        persistCast()
        updateOverallSpeedLabel()
    }

    private func updateOverallSpeedLabel() {
        let overall = ScriptCast.clamp(cast.overallSpeed)
        var text = String(format: "Overall speed  %.2f×", overall)
        // Spell out what the multiplier actually does to a couple of cast
        // members, so the interaction between the two controls is legible.
        let examples = characterNames.prefix(2).map { name in
            String(format: "%@ %.2f×", name, cast.effectiveSpeed(forCharacter: name))
        }
        if !examples.isEmpty {
            text += "  →  " + examples.joined(separator: ", ")
        }
        overallSpeedLabel.stringValue = text
    }

    @objc private func optionChanged() { updateState() }

    @objc private func play() {
        let options = ScriptCaster.Options(
            readSceneHeadings: skipHeadings.state != .on,
            readParentheticals: skipParentheticals.state != .on,
            readTransitions: skipTransitions.state != .on
        )
        // Formatted for the Reader AND cast for playback in one pass, so the
        // highlight ranges and the spoken chunks come from the same source and
        // cannot drift apart.
        let document = ScriptFormatter.format(elements: elements, cast: cast, options: options)
        guard !document.isEmpty else {
            statusLabel.stringValue = "Nothing to play with the current cast and skip options."
            return
        }
        do {
            try appDelegate.playScript(document)
            statusLabel.stringValue = "Playing table read."
        } catch {
            statusLabel.stringValue = "Couldn’t start playback: \(error.localizedDescription)"
        }
    }

    @objc private func buildTimeline() {
        let options = ScriptCaster.Options(
            readSceneHeadings: skipHeadings.state != .on,
            readParentheticals: skipParentheticals.state != .on,
            readTransitions: skipTransitions.state != .on
        )
        let segments = ScriptCaster.cast(elements: elements, cast: cast, options: options)
        guard !segments.isEmpty else {
            timelineStatus.stringValue = "Nothing to lay out with the current cast."
            return
        }

        var built = Timeline.fromCast(segments: segments)
        timelineView.timeline = built
        timelineStatus.stringValue = "Rendering \(built.clips.count) clips…"
        buildTimelineButton.isEnabled = false
        guard let timelineAudio else {
            buildTimelineButton.isEnabled = true
            timelineStatus.stringValue = "Audio engine is unavailable."
            return
        }
        timelineAudio.render(built) { [weak self] fraction in
            self?.timelineStatus.stringValue = "Rendering… \(Int(fraction * 100))%"
        } completion: { [weak self] rendered in
            guard let self else { return }
            var rendered = rendered
            rendered.relayoutSequentially()
            self.timelineView.timeline = rendered
            self.buildTimelineButton.isEnabled = true
            self.timelineStatus.stringValue = "Ready. \(rendered.clips.count) clips, \(Self.durationText(rendered.totalDurationMS))."
        }
    }

    @objc private func playTimeline() {
        guard let audio = timelineAudio else { return }
        let samples = audio.mixdown(timelineView.timeline)
        guard !samples.isEmpty else {
            timelineStatus.stringValue = "Nothing to play. Build the timeline first."
            return
        }
        do {
            try appDelegate.playTimelineMix(samples)
        } catch {
            timelineStatus.stringValue = "Couldn't start playback: \(error.localizedDescription)"
            return
        }

        playheadTimer?.invalidate()
        // Never touch the Timer parameter inside the isolated block: Timer is not
        // Sendable, so passing it across the MainActor boundary is a data race in
        // Swift 6. The MainActor-isolated `playheadTimer` property is the same
        // object and is safe to use, so stop via that instead. The VC invalidates
        // it on disappear/deinit, which covers the deallocated-self case.
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timelineView.playheadMS = Int(
                    (self.appDelegate.playbackPositionSeconds ?? 0) * 1000
                )
                if !self.appDelegate.isEnginePlaying {
                    self.playheadTimer?.invalidate()
                    self.playheadTimer = nil
                }
            }
        }
        playheadTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func stopTimeline() {
        appDelegate.stopTimelinePlayback()
        playheadTimer?.invalidate()
        playheadTimer = nil
    }

    @objc private func exportTimeline() {
        guard let audio = timelineAudio, let window = view.window else { return }
        let timeline = timelineView.timeline
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = "Table Read.m4a"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            audio.export(timeline, to: url) { [weak self] result in
                switch result {
                case .success(let url):
                    self?.timelineStatus.stringValue = "Exported to \(url.lastPathComponent)"
                case .failure(let error):
                    self?.timelineStatus.stringValue = error.localizedDescription
                }
            }
        }
    }

    @objc private func zoomInTimeline() {
        timelineView.zoomIn()
    }

    @objc private func zoomOutTimeline() {
        timelineView.zoomOut()
    }

    private func timelineChanged(_ updated: Timeline) {
        timelineStatus.stringValue = "\(updated.clips.count) clips, \(Self.durationText(updated.totalDurationMS))."
    }

    private func editClip(_ id: UUID) {
        guard var clip = timelineView.timeline.clip(id: id) else { return }
        let alert = NSAlert()
        alert.messageText = "Edit Timeline Clip"
        alert.informativeText = "Edit the text spoken by this clip."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = clip.text
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        clip.text = field.stringValue
        timelineView.timeline.update(clip)
        let edited = timelineView.timeline
        timelineStatus.stringValue = "Rendering edited clip…"
        timelineAudio?.render(edited) { [weak self] fraction in
            self?.timelineStatus.stringValue = "Rendering… \(Int(fraction * 100))%"
        } completion: { [weak self] rendered in
            guard let self else { return }
            var rendered = rendered
            rendered.relayoutSequentially()
            self.timelineView.timeline = rendered
            self.timelineStatus.stringValue = "Ready. \(rendered.clips.count) clips, \(Self.durationText(rendered.totalDurationMS))."
        }
    }

    private static func durationText(_ durationMS: Int) -> String {
        let totalSeconds = max(0, durationMS) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
