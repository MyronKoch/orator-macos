import Cocoa

enum OratorTab: Int, CaseIterable {
    case dashboard
    case voices
    case pronunciations
    case shortcuts
    case general

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .voices: return "Voices"
        case .pronunciations: return "Pronunciations"
        case .shortcuts: return "Shortcuts"
        case .general: return "General"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: return "chart.bar.xaxis"
        case .voices: return "waveform"
        case .pronunciations: return "text.book.closed"
        case .shortcuts: return "keyboard"
        case .general: return "gearshape"
        }
    }
}

/// The single, reusable home for Orator's dashboard and settings.
@MainActor
final class OratorWindowController: NSWindowController, NSWindowDelegate,
    NSTableViewDataSource, NSTableViewDelegate
{
    private unowned let appDelegate: AppDelegate
    private let sidebar = NSTableView()
    private let contentContainer = NSView()
    private var selectedTab: OratorTab = .dashboard
    private var isSelectingProgrammatically = false

    private lazy var dashboardController = DashboardViewController(appDelegate: appDelegate)
    private lazy var voicesController = VoicesSettingsViewController(appDelegate: appDelegate)
    private lazy var pronunciationsController = EmbeddedSettingsViewController(
        makeView: { [unowned appDelegate] in appDelegate.pronunciationsContentView() },
        onRefresh: { [unowned appDelegate] in appDelegate.refreshPronunciationsEditor() }
    )
    private lazy var shortcutsController = EmbeddedSettingsViewController(
        makeView: { [unowned appDelegate] in appDelegate.shortcutsContentView() },
        onRefresh: { [unowned appDelegate] in appDelegate.refreshShortcutsEditor() }
    )
    private lazy var generalController = GeneralSettingsViewController(appDelegate: appDelegate)

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configureWindow(window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(tab: OratorTab) {
        if selectedTab == .shortcuts, tab != .shortcuts {
            appDelegate.stopShortcutRecording()
        }
        selectedTab = tab
        isSelectingProgrammatically = true
        sidebar.selectRowIndexes(IndexSet(integer: tab.rawValue), byExtendingSelection: false)
        isSelectingProgrammatically = false
        display(tab)
        refresh(tab)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        refresh(selectedTab)
    }

    func refreshDashboard() {
        dashboardController.refresh()
    }

    func windowWillClose(_ notification: Notification) {
        appDelegate.stopShortcutRecording()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        OratorTab.allCases.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tab = OratorTab(rawValue: row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("OratorSidebarCell")
        let cell: NSTableCellView

        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            imageView.contentTintColor = .secondaryLabelColor

            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.font = .systemFont(ofSize: 13, weight: .medium)
            field.lineBreakMode = .byTruncatingTail

            cell.addSubview(imageView)
            cell.addSubview(field)
            cell.imageView = imageView
            cell.textField = field
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                field.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 7),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        cell.imageView?.image = NSImage(systemSymbolName: tab.symbolName, accessibilityDescription: nil)
        cell.textField?.stringValue = tab.title
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isSelectingProgrammatically else { return }
        guard let tab = OratorTab(rawValue: sidebar.selectedRow) else { return }
        if selectedTab == .shortcuts, tab != .shortcuts {
            appDelegate.stopShortcutRecording()
        }
        selectedTab = tab
        display(tab)
        refresh(tab)
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = "Orator"
        window.minSize = NSSize(width: 680, height: 500)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("OratorWindow")
        if !window.setFrameUsingName("OratorWindow") {
            window.center()
        }

        let root = NSView()

        let sidebarBackground = NSVisualEffectView()
        sidebarBackground.translatesAutoresizingMaskIntoConstraints = false
        sidebarBackground.material = .sidebar
        sidebarBackground.blendingMode = .behindWindow
        sidebarBackground.state = .active

        sidebar.headerView = nil
        sidebar.rowHeight = 38
        sidebar.intercellSpacing = NSSize(width: 0, height: 4)
        sidebar.style = .sourceList
        // A view-based NSTableView renders nothing without a column - viewFor
        // is never called - so the sidebar tabs need an explicit column.
        let tabColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("OratorSidebarColumn"))
        tabColumn.resizingMask = .autoresizingMask
        sidebar.addTableColumn(tabColumn)
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.allowsEmptySelection = false
        sidebar.backgroundColor = .clear
        sidebar.reloadData()

        let sidebarScroll = NSScrollView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = false
        sidebarScroll.drawsBackground = false
        sidebarBackground.addSubview(sidebarScroll)

        let separator = NSBox()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.boxType = .separator

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarBackground)
        root.addSubview(separator)
        root.addSubview(contentContainer)

        NSLayoutConstraint.activate([
            sidebarBackground.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarBackground.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarBackground.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarBackground.widthAnchor.constraint(equalToConstant: 158),

            sidebarScroll.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor, constant: 8),
            sidebarScroll.trailingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor, constant: -8),
            sidebarScroll.topAnchor.constraint(equalTo: sidebarBackground.topAnchor, constant: 16),
            sidebarScroll.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor, constant: -12),

            separator.leadingAnchor.constraint(equalTo: sidebarBackground.trailingAnchor),
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.topAnchor.constraint(equalTo: root.topAnchor),
            separator.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            contentContainer.leadingAnchor.constraint(equalTo: separator.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: root.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        window.contentView = root
    }

    private func controller(for tab: OratorTab) -> NSViewController {
        switch tab {
        case .dashboard: return dashboardController
        case .voices: return voicesController
        case .pronunciations: return pronunciationsController
        case .shortcuts: return shortcutsController
        case .general: return generalController
        }
    }

    private func display(_ tab: OratorTab) {
        for subview in contentContainer.subviews {
            subview.removeFromSuperview()
        }
        let tabView = controller(for: tab).view
        tabView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            tabView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
    }

    private func refresh(_ tab: OratorTab) {
        switch tab {
        case .dashboard: dashboardController.refresh()
        case .voices: voicesController.refresh()
        case .pronunciations: pronunciationsController.refresh()
        case .shortcuts: shortcutsController.refresh()
        case .general: generalController.refresh()
        }
    }
}

@MainActor
private final class EmbeddedSettingsViewController: NSViewController {
    private let makeEmbeddedView: () -> NSView
    private let onRefresh: () -> Void

    init(makeView: @escaping () -> NSView, onRefresh: @escaping () -> Void) {
        makeEmbeddedView = makeView
        self.onRefresh = onRefresh
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = makeEmbeddedView()
    }

    func refresh() {
        onRefresh()
    }
}

@MainActor
private final class VoicesSettingsViewController: NSViewController {
    private unowned let appDelegate: AppDelegate
    private let voicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let speedPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        documentView.addSubview(stack)

        let heading = NSTextField(labelWithString: "Voices")
        heading.font = .systemFont(ofSize: 26, weight: .bold)
        let helper = NSTextField(
            wrappingLabelWithString: "Choose the voice and pace Orator uses by default. Per-app profiles override these settings only for their app."
        )
        helper.font = .systemFont(ofSize: 13)
        helper.textColor = .secondaryLabelColor

        let voiceLabel = settingLabel("Voice")
        voicePopup.target = self
        voicePopup.action = #selector(changeVoice(_:))
        voicePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let speedLabel = settingLabel("Speed")
        speedPopup.target = self
        speedPopup.action = #selector(changeSpeed(_:))
        speedPopup.widthAnchor.constraint(equalToConstant: 104).isActive = true

        let preview = NSButton(title: "Preview", target: self, action: #selector(previewVoice))
        preview.bezelStyle = .rounded

        let voiceColumn = NSStackView(views: [voiceLabel, voicePopup])
        voiceColumn.orientation = .vertical
        voiceColumn.alignment = .leading
        voiceColumn.spacing = 5
        let speedColumn = NSStackView(views: [speedLabel, speedPopup])
        speedColumn.orientation = .vertical
        speedColumn.alignment = .leading
        speedColumn.spacing = 5
        let controls = NSStackView(views: [voiceColumn, speedColumn, preview])
        controls.orientation = .horizontal
        controls.alignment = .bottom
        controls.spacing = 12

        let globalBox = NSBox()
        globalBox.boxType = .custom
        globalBox.title = "Default voice"
        globalBox.titlePosition = .atTop
        globalBox.fillColor = .controlBackgroundColor
        globalBox.borderColor = .separatorColor
        globalBox.cornerRadius = 10
        let boxContent = NSView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        boxContent.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: boxContent.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: boxContent.trailingAnchor, constant: -12),
            controls.topAnchor.constraint(equalTo: boxContent.topAnchor, constant: 12),
            controls.bottomAnchor.constraint(equalTo: boxContent.bottomAnchor, constant: -12),
        ])
        globalBox.contentView = boxContent

        let perApp = appDelegate.appVoiceProfilesContentView()
        perApp.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(helper)
        stack.setCustomSpacing(20, after: helper)
        stack.addArrangedSubview(globalBox)
        stack.addArrangedSubview(perApp)
        globalBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        perApp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -28),
        ])

        view = scrollView
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        rebuildVoiceMenu()
        rebuildSpeedMenu()
        appDelegate.refreshAppVoiceProfilesEditor()
    }

    private func rebuildVoiceMenu() {
        voicePopup.removeAllItems()
        let voices = appDelegate.availableVoiceNames
        let groups: [(title: String, prefix: String)] = [
            ("US · Female", "af"),
            ("US · Male", "am"),
            ("UK · Female", "bf"),
            ("UK · Male", "bm"),
        ]

        for (groupIndex, group) in groups.enumerated() {
            let matching = voices.filter { $0.hasPrefix(group.prefix + "_") }
            guard !matching.isEmpty else { continue }
            if groupIndex > 0, !(voicePopup.menu?.items.isEmpty ?? true) {
                voicePopup.menu?.addItem(.separator())
            }
            let header = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            voicePopup.menu?.addItem(header)
            for voice in matching {
                let item = NSMenuItem(
                    title: appDelegate.displayName(for: voice),
                    action: nil,
                    keyEquivalent: ""
                )
                item.representedObject = voice
                voicePopup.menu?.addItem(item)
            }
        }

        let groupedVoices = Set(groups.flatMap { group in voices.filter { $0.hasPrefix(group.prefix + "_") } })
        let remaining = voices.filter { !groupedVoices.contains($0) }
        if !remaining.isEmpty {
            if !(voicePopup.menu?.items.isEmpty ?? true) {
                voicePopup.menu?.addItem(.separator())
            }
            let header = NSMenuItem(title: "Other", action: nil, keyEquivalent: "")
            header.isEnabled = false
            voicePopup.menu?.addItem(header)
            for voice in remaining {
                let item = NSMenuItem(title: appDelegate.displayName(for: voice), action: nil, keyEquivalent: "")
                item.representedObject = voice
                voicePopup.menu?.addItem(item)
            }
        }

        if let index = voicePopup.menu?.items.firstIndex(where: {
            ($0.representedObject as? String) == appDelegate.selectedVoiceName
        }) {
            voicePopup.selectItem(at: index)
        }
        voicePopup.isEnabled = !voices.isEmpty
    }

    private func rebuildSpeedMenu() {
        speedPopup.removeAllItems()
        for speed in appDelegate.availableSpeedOptions {
            let item = NSMenuItem(title: String(format: "%.2gx", speed), action: nil, keyEquivalent: "")
            item.representedObject = speed
            speedPopup.menu?.addItem(item)
        }
        if let index = appDelegate.availableSpeedOptions.firstIndex(where: {
            abs($0 - appDelegate.selectedSpeed) < 0.001
        }) {
            speedPopup.selectItem(at: index)
        }
        speedPopup.isEnabled = !appDelegate.availableVoiceNames.isEmpty
    }

    private func settingLabel(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 12, weight: .medium)
        return field
    }

    @objc private func changeVoice(_ sender: NSPopUpButton) {
        guard let voice = sender.selectedItem?.representedObject as? String else { return }
        appDelegate.setSelectedVoice(voice)
        refresh()
    }

    @objc private func changeSpeed(_ sender: NSPopUpButton) {
        guard let speed = sender.selectedItem?.representedObject as? Float else { return }
        appDelegate.setSelectedSpeed(speed)
        refresh()
    }

    @objc private func previewVoice() {
        appDelegate.previewVoice(appDelegate.selectedVoiceName, speed: appDelegate.selectedSpeed)
    }
}

@MainActor
private final class GeneralSettingsViewController: NSViewController {
    private unowned let appDelegate: AppDelegate
    private let loginCheckbox = NSButton(checkboxWithTitle: "Start at Login", target: nil, action: nil)
    private let rememberCheckbox = NSButton(
        checkboxWithTitle: "Remember my reading", target: nil, action: nil
    )
    private let continuousCheckbox = NSButton(
        checkboxWithTitle: "Continuous reading", target: nil, action: nil
    )
    private let historyStack = NSStackView()
    private var historyTexts: [String] = []

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        documentView.addSubview(content)

        let heading = NSTextField(labelWithString: "General")
        heading.font = .systemFont(ofSize: 26, weight: .bold)
        content.addArrangedSubview(heading)

        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin(_:))
        rememberCheckbox.target = self
        rememberCheckbox.action = #selector(toggleRememberReading(_:))
        continuousCheckbox.target = self
        continuousCheckbox.action = #selector(toggleContinuousReading(_:))
        content.addArrangedSubview(loginCheckbox)
        content.addArrangedSubview(rememberCheckbox)
        content.addArrangedSubview(continuousCheckbox)

        let rememberHelp = NSTextField(
            wrappingLabelWithString: "Reading history and Dashboard stats are stored locally only when “Remember my reading” is on."
        )
        rememberHelp.font = .systemFont(ofSize: 11)
        rememberHelp.textColor = .secondaryLabelColor
        content.addArrangedSubview(rememberHelp)
        rememberHelp.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        let clearHistory = NSButton(
            title: "Clear Reading History", target: self, action: #selector(clearReadingHistory)
        )
        clearHistory.bezelStyle = .rounded
        let clearStats = NSButton(title: "Clear Stats…", target: self, action: #selector(confirmClearStats))
        clearStats.bezelStyle = .rounded
        actions.addArrangedSubview(clearHistory)
        actions.addArrangedSubview(clearStats)
        content.addArrangedSubview(actions)

        let separator = NSBox()
        separator.boxType = .separator
        content.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let recentHeading = NSTextField(labelWithString: "Recent reads")
        recentHeading.font = .systemFont(ofSize: 15, weight: .semibold)
        content.addArrangedSubview(recentHeading)

        historyStack.orientation = .vertical
        historyStack.alignment = .leading
        historyStack.spacing = 5
        content.addArrangedSubview(historyStack)
        historyStack.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let aboutSeparator = NSBox()
        aboutSeparator.boxType = .separator
        content.addArrangedSubview(aboutSeparator)
        aboutSeparator.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let aboutHeading = NSTextField(labelWithString: "About")
        aboutHeading.font = .systemFont(ofSize: 15, weight: .semibold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "Development"
        let about = NSTextField(labelWithString: "Orator \(version)  •  100% local")
        about.font = .systemFont(ofSize: 12)
        about.textColor = .secondaryLabelColor
        content.addArrangedSubview(aboutHeading)
        content.addArrangedSubview(about)

        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -28),
            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -28),
        ])

        view = scrollView
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        loginCheckbox.state = appDelegate.startAtLoginEnabled ? .on : .off
        rememberCheckbox.state = appDelegate.remembersReading ? .on : .off
        continuousCheckbox.state = appDelegate.continuousReadingEnabled ? .on : .off
        rebuildHistory()
    }

    private func rebuildHistory() {
        for view in historyStack.arrangedSubviews {
            historyStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let entries = appDelegate.recentReadingEntries
        historyTexts = entries.map(\.text)
        guard !entries.isEmpty else {
            let empty = NSTextField(labelWithString: "No recent reads")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            historyStack.addArrangedSubview(empty)
            return
        }

        for (index, entry) in entries.enumerated() {
            let button = NSButton(title: entry.title, target: self, action: #selector(readHistory(_:)))
            button.tag = index
            button.bezelStyle = .inline
            button.alignment = .left
            button.font = .systemFont(ofSize: 12)
            button.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Read again")
            button.imagePosition = .imageLeading
            button.lineBreakMode = .byTruncatingTail
            historyStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: historyStack.widthAnchor).isActive = true
        }
    }

    @objc private func toggleLogin(_ sender: NSButton) {
        appDelegate.setStartAtLogin(sender.state == .on)
        refresh()
    }

    @objc private func toggleRememberReading(_ sender: NSButton) {
        appDelegate.setRemembersReading(sender.state == .on)
        refresh()
    }

    @objc private func toggleContinuousReading(_ sender: NSButton) {
        appDelegate.setContinuousReading(sender.state == .on)
        refresh()
    }

    @objc private func clearReadingHistory() {
        appDelegate.clearReadingHistory()
        refresh()
    }

    @objc private func confirmClearStats() {
        let alert = NSAlert()
        alert.messageText = "Clear all reading stats?"
        alert.informativeText = "This removes Dashboard totals, streaks, rankings, and the longest read. Your weekly goal is kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear Stats")
        alert.addButton(withTitle: "Cancel")

        guard let window = view.window else {
            if alert.runModal() == .alertFirstButtonReturn {
                appDelegate.clearReadingStats()
                refresh()
            }
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                self?.appDelegate.clearReadingStats()
                self?.refresh()
            }
        }
    }

    @objc private func readHistory(_ sender: NSButton) {
        guard historyTexts.indices.contains(sender.tag) else { return }
        appDelegate.speakHistoryText(historyTexts[sender.tag])
    }
}
