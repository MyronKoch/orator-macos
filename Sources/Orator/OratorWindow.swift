import Cocoa

enum OratorTab: Int, CaseIterable {
    case dashboard
    case voices
    case script
    case pronunciations
    case replacements
    case shortcuts
    case general

    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .voices: return "Voices"
        case .script: return "Script"
        case .pronunciations: return "Pronunciations"
        case .replacements: return "Replacements"
        case .shortcuts: return "Shortcuts"
        case .general: return "General"
        }
    }

    var symbolName: String {
        switch self {
        case .dashboard: return "chart.bar.xaxis"
        case .voices: return "waveform"
        case .script: return "theatermasks"
        case .pronunciations: return "text.book.closed"
        case .replacements: return "arrow.left.arrow.right"
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
    private lazy var scriptController = ScriptSettingsViewController(appDelegate: appDelegate)
    private lazy var pronunciationsController = PronunciationsSettingsViewController(
        appDelegate: appDelegate
    )
    private lazy var replacementsController = ReplacementsSettingsViewController()
    private lazy var shortcutsController = ShortcutsSettingsViewController(
        appDelegate: appDelegate
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

        // Version pinned to the sidebar foot - always answerable "what build am I on?"
        let sidebarVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "dev"
        let versionLabel = NSTextField(labelWithString: "v\(sidebarVersion)")
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        // addSubview BEFORE any constraint activation (guards the "no common ancestor" abort).
        sidebarBackground.addSubview(versionLabel)

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
            sidebarScroll.bottomAnchor.constraint(equalTo: versionLabel.topAnchor, constant: -8),

            versionLabel.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor, constant: 16),
            versionLabel.bottomAnchor.constraint(equalTo: sidebarBackground.bottomAnchor, constant: -12),

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
        case .script: return scriptController
        case .pronunciations: return pronunciationsController
        case .replacements: return replacementsController
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
        case .script: scriptController.refresh()
        case .pronunciations: pronunciationsController.refresh()
        case .replacements: replacementsController.refresh()
        case .shortcuts: shortcutsController.refresh()
        case .general: generalController.refresh()
        }
    }
}

@MainActor
func makeSettingsScrollView(
    hosting content: NSView,
    insets: NSEdgeInsets
) -> NSView {
    let rootView = NSView()

    let scrollView = NSScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.autohidesScrollers = true

    // A FLIPPED document view anchors its content to the TOP of the clip.
    // With a plain (non-flipped) NSView, a document shorter than the viewport
    // sits at the BOTTOM of the clip - which made short tabs (e.g. Shortcuts)
    // look blank with all their content pushed below the fold.
    let documentView = FlippedView()
    documentView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.documentView = documentView

    content.translatesAutoresizingMaskIntoConstraints = false
    documentView.addSubview(content)
    rootView.addSubview(scrollView)

    // Content bottom is <= (not ==) so short content keeps its natural height
    // (it doesn't stretch), while the document is forced to at least fill the
    // viewport so content stays pinned to the top. Tall content grows the
    // document and scrolls.
    let fillHeight = documentView.heightAnchor.constraint(
        greaterThanOrEqualTo: scrollView.contentView.heightAnchor
    )
    fillHeight.priority = .defaultHigh

    NSLayoutConstraint.activate([
        scrollView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
        scrollView.topAnchor.constraint(equalTo: rootView.topAnchor),
        scrollView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

        documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
        documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        fillHeight,
        content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: insets.left),
        content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -insets.right),
        content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: insets.top),
        content.bottomAnchor.constraint(lessThanOrEqualTo: documentView.bottomAnchor, constant: -insets.bottom),
    ])

    return rootView
}

/// A view whose coordinate origin is top-left, so a scroll document shorter
/// than its clip anchors content to the top instead of the bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class PronunciationsSettingsViewController: NSViewController {
    private unowned let appDelegate: AppDelegate

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let content = appDelegate.makePronunciationsContentView()
        view = makeSettingsScrollView(
            hosting: content,
            insets: NSEdgeInsets(top: 24, left: 26, bottom: 28, right: 26)
        )
    }

    func refresh() {
        appDelegate.refreshPronunciationsEditor()
    }
}

@MainActor
private final class ReplacementsSettingsViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate
{
    private enum Column {
        static let enabled = NSUserInterfaceItemIdentifier("ReplacementEnabled")
        static let find = NSUserInterfaceItemIdentifier("ReplacementFind")
        static let replace = NSUserInterfaceItemIdentifier("ReplacementReplace")
        static let regex = NSUserInterfaceItemIdentifier("ReplacementRegex")
    }

    private let tableView = NSTableView()
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let moveUpButton = NSButton(title: "Move Up", target: nil, action: nil)
    private let moveDownButton = NSButton(title: "Move Down", target: nil, action: nil)
    private let testInput = NSTextField()
    private let testOutput = NSTextField(wrappingLabelWithString: "")
    private var rules: [UserReplacements.Rule] = []

    override func loadView() {
        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12

        let heading = NSTextField(labelWithString: "Replacements")
        heading.font = .systemFont(ofSize: 26, weight: .bold)
        let explainer = NSTextField(
            wrappingLabelWithString: "Rewrite symbols, abbreviations, or phrases before reading (supports regex). For how to pronounce a word, use Pronunciations."
        )
        explainer.font = .systemFont(ofSize: 13)
        explainer.textColor = .secondaryLabelColor

        configureTable()
        let tableScroll = NSScrollView()
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .bezelBorder
        tableScroll.documentView = tableView

        let addButton = NSButton(title: "Add", target: self, action: #selector(addRule))
        removeButton.target = self
        removeButton.action = #selector(removeRule)
        moveUpButton.target = self
        moveUpButton.action = #selector(moveRuleUp)
        moveDownButton.target = self
        moveDownButton.action = #selector(moveRuleDown)
        let buttonRow = NSStackView(views: [addButton, removeButton, moveUpButton, moveDownButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let testLabel = NSTextField(labelWithString: "Test")
        testLabel.font = .systemFont(ofSize: 12, weight: .medium)
        testInput.placeholderString = "Type sample text"
        testInput.delegate = self
        testOutput.textColor = .secondaryLabelColor
        testOutput.font = .systemFont(ofSize: 12)

        content.addArrangedSubview(heading)
        content.addArrangedSubview(explainer)
        content.addArrangedSubview(tableScroll)
        content.addArrangedSubview(buttonRow)
        content.setCustomSpacing(20, after: buttonRow)
        content.addArrangedSubview(testLabel)
        content.addArrangedSubview(testInput)
        content.addArrangedSubview(testOutput)

        explainer.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        tableScroll.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        tableScroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        testInput.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        testOutput.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        view = makeSettingsScrollView(
            hosting: content,
            insets: NSEdgeInsets(top: 24, left: 26, bottom: 28, right: 26)
        )
        refresh()
    }

    func refresh() {
        guard isViewLoaded else { return }
        rules = UserReplacements.shared.rules
        tableView.reloadData()
        updateControls()
        updateTestOutput()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rules.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rules.indices.contains(row), let identifier = tableColumn?.identifier else { return nil }
        let rule = rules[row]
        if identifier == Column.enabled || identifier == Column.regex {
            let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRule(_:)))
            button.identifier = identifier
            button.tag = row
            button.state = (identifier == Column.enabled ? rule.enabled : rule.isRegex) ? .on : .off
            return button
        }

        let field = NSTextField()
        field.identifier = identifier
        field.tag = row
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.bezelStyle = .squareBezel
        field.drawsBackground = true
        field.lineBreakMode = .byTruncatingTail
        field.delegate = self
        field.stringValue = identifier == Column.find ? rule.find : rule.replace
        field.textColor = identifier == Column.find && isInvalidRegex(rule)
            ? .systemRed
            : .labelColor
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        if field === testInput {
            updateTestOutput()
            return
        }
        guard rules.indices.contains(field.tag) else { return }
        if field.identifier == Column.find {
            rules[field.tag].find = field.stringValue
            field.textColor = isInvalidRegex(rules[field.tag]) ? .systemRed : .labelColor
        } else if field.identifier == Column.replace {
            rules[field.tag].replace = field.stringValue
        } else {
            return
        }
        saveRules()
    }

    private func configureTable() {
        tableView.headerView = NSTableHeaderView()
        tableView.rowHeight = 25
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat)] = [
            (Column.enabled, "Enabled", 62),
            (Column.find, "Find", 150),
            (Column.replace, "Replace", 150),
            (Column.regex, "Regex", 52),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            column.width = width
            column.minWidth = identifier == Column.find || identifier == Column.replace ? 80 : width
            column.resizingMask = identifier == Column.find || identifier == Column.replace
                ? .autoresizingMask
                : .userResizingMask
            tableView.addTableColumn(column)
        }
    }

    private func isInvalidRegex(_ rule: UserReplacements.Rule) -> Bool {
        rule.isRegex && !UserReplacements.isValidRegex(rule.find)
    }

    private func saveRules() {
        UserReplacements.shared.setRules(rules)
        updateTestOutput()
    }

    private func updateTestOutput() {
        let sample = testInput.stringValue
        testOutput.stringValue = sample.isEmpty
            ? ""
            : "Result: \(UserReplacements.shared.apply(to: sample))"
    }

    private func updateControls() {
        let row = tableView.selectedRow
        let hasSelection = rules.indices.contains(row)
        removeButton.isEnabled = hasSelection
        moveUpButton.isEnabled = hasSelection && row > 0
        moveDownButton.isEnabled = hasSelection && row < rules.count - 1
    }

    private func selectRow(_ row: Int) {
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        updateControls()
    }

    @objc private func toggleRule(_ sender: NSButton) {
        guard rules.indices.contains(sender.tag) else { return }
        if sender.identifier == Column.enabled {
            rules[sender.tag].enabled = sender.state == .on
        } else {
            rules[sender.tag].isRegex = sender.state == .on
            tableView.reloadData(forRowIndexes: IndexSet(integer: sender.tag), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        }
        saveRules()
    }

    @objc private func addRule() {
        rules.append(UserReplacements.Rule(find: "", replace: ""))
        saveRules()
        selectRow(rules.count - 1)
    }

    @objc private func removeRule() {
        let row = tableView.selectedRow
        guard rules.indices.contains(row) else { return }
        rules.remove(at: row)
        saveRules()
        tableView.reloadData()
        if !rules.isEmpty {
            let nextRow = min(row, rules.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
        }
        updateControls()
    }

    @objc private func moveRuleUp() {
        moveSelectedRule(by: -1)
    }

    @objc private func moveRuleDown() {
        moveSelectedRule(by: 1)
    }

    private func moveSelectedRule(by offset: Int) {
        let row = tableView.selectedRow
        let destination = row + offset
        guard rules.indices.contains(row), rules.indices.contains(destination) else { return }
        rules.swapAt(row, destination)
        saveRules()
        selectRow(destination)
    }
}

@MainActor
private final class ShortcutsSettingsViewController: NSViewController {
    private unowned let appDelegate: AppDelegate

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let content = appDelegate.makeShortcutsContentView()
        view = makeSettingsScrollView(
            hosting: content,
            insets: NSEdgeInsets(top: 24, left: 26, bottom: 28, right: 26)
        )
    }

    func refresh() {
        appDelegate.refreshShortcutsEditor()
    }
}

@MainActor
private final class VoicesSettingsViewController: NSViewController {
    private unowned let appDelegate: AppDelegate
    private let voicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let speedPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let autoCastCheckbox = NSButton(
        checkboxWithTitle: "Dramatize dialogue", target: nil, action: nil
    )
    private let castGenderControl = NSSegmentedControl(
        labels: ["Auto", "Female", "Male"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    // nonisolated(unsafe): the deinit (nonisolated) removes this observer, and
    // NotificationCenter.removeObserver is thread-safe, so unchecked access is fine.
    private nonisolated(unsafe) var autoCastObserver: NSObjectProtocol?
    // Same rationale: removed in deinit; NSEvent.removeMonitor is thread-safe.
    private nonisolated(unsafe) var voiceKeyMonitor: Any?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let autoCastObserver {
            NotificationCenter.default.removeObserver(autoCastObserver)
        }
        if let voiceKeyMonitor {
            NSEvent.removeMonitor(voiceKeyMonitor)
        }
    }

    override func loadView() {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        let heading = NSTextField(labelWithString: "Voices")
        heading.font = .systemFont(ofSize: 26, weight: .bold)
        let helper = NSTextField(
            wrappingLabelWithString: "Choose the voice and pace Orator uses by default. Per-app profiles override these settings only for their app."
        )
        helper.font = .systemFont(ofSize: 13)
        helper.textColor = .secondaryLabelColor

        autoCastCheckbox.target = self
        autoCastCheckbox.action = #selector(toggleAutoCast(_:))
        let autoCastHelp = NSTextField(
            wrappingLabelWithString: "Quoted speech is read by a different voice per speaker. Off by default."
        )
        autoCastHelp.font = .systemFont(ofSize: 11)
        autoCastHelp.textColor = .secondaryLabelColor

        castGenderControl.target = self
        castGenderControl.action = #selector(changeCastGender(_:))
        castGenderControl.segmentStyle = .rounded
        let castGenderLabel = NSTextField(labelWithString: "Dialogue voices")
        castGenderLabel.font = .systemFont(ofSize: 11)
        castGenderLabel.textColor = .secondaryLabelColor
        let castGenderRow = NSStackView(views: [castGenderLabel, castGenderControl])
        castGenderRow.orientation = .horizontal
        castGenderRow.alignment = .centerY
        castGenderRow.spacing = 8

        let autoCastControls = NSStackView(views: [autoCastCheckbox, autoCastHelp, castGenderRow])
        autoCastControls.orientation = .vertical
        autoCastControls.alignment = .leading
        autoCastControls.spacing = 6

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

        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(helper)
        stack.setCustomSpacing(20, after: helper)
        stack.addArrangedSubview(autoCastControls)
        autoCastHelp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(globalBox)
        let auditionHint = NSTextField(
            wrappingLabelWithString: "Tip: press [ or ] to step through voices and hear each one instantly."
        )
        auditionHint.font = .systemFont(ofSize: 11)
        auditionHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(auditionHint)
        let perApp = appDelegate.makeAppVoiceProfilesContentView()
        perApp.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(perApp)
        globalBox.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        perApp.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        view = makeSettingsScrollView(
            hosting: stack,
            insets: NSEdgeInsets(top: 24, left: 26, bottom: 28, right: 26)
        )
        autoCastObserver = NotificationCenter.default.addObserver(
            forName: .oratorAutoCastChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncAutoCastState()
            }
        }
        // Audition voices from the keyboard: [ = previous, ] = next, each auto-previews.
        // Local monitors deliver on the main thread; scoped below to when this tab is showing.
        voiceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Extract Sendable primitives here; never move the non-Sendable NSEvent
            // across the MainActor boundary. Local monitors deliver on the main thread.
            let characters = event.charactersIgnoringModifiers
            let modifiers = event.modifierFlags
            let handled = MainActor.assumeIsolated {
                self.handleVoiceKey(characters: characters, modifiers: modifiers)
            }
            return handled ? nil : event
        }
        refresh()
    }

    /// [ / ] step through the voice list and auto-preview, but only while the Voices
    /// tab is actually on screen (display(_:) removes off-screen tabs, so voicePopup.window
    /// is nil for other tabs) and not while editing text. Returns true if it consumed the key.
    private func handleVoiceKey(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let window = voicePopup.window, window.isKeyWindow, voicePopup.isEnabled else { return false }
        if let editor = window.firstResponder as? NSText, editor.isFieldEditor { return false }
        guard modifiers.intersection(.deviceIndependentFlagsMask).isEmpty else { return false }
        switch characters {
        case "]": stepVoice(1); return true
        case "[": stepVoice(-1); return true
        default: return false
        }
    }

    /// Move the voice selection by `direction` (skipping group headers/separators),
    /// commit it, and preview it. Wraps around the ends for fast auditioning.
    private func stepVoice(_ direction: Int) {
        guard let items = voicePopup.menu?.items else { return }
        let voiceIndices = items.indices.filter { (items[$0].representedObject as? String) != nil }
        guard !voiceIndices.isEmpty else { return }
        let current = voicePopup.indexOfSelectedItem
        let pos = voiceIndices.firstIndex(of: current)
        let nextPos: Int
        if let pos {
            nextPos = (pos + direction + voiceIndices.count) % voiceIndices.count
        } else {
            nextPos = direction > 0 ? 0 : voiceIndices.count - 1
        }
        let targetIndex = voiceIndices[nextPos]
        guard let voice = items[targetIndex].representedObject as? String else { return }
        voicePopup.selectItem(at: targetIndex)
        appDelegate.setSelectedVoice(voice)
        appDelegate.previewVoice(voice, speed: appDelegate.selectedSpeed)
    }

    func refresh() {
        guard isViewLoaded else { return }
        rebuildVoiceMenu()
        rebuildSpeedMenu()
        syncAutoCastState()
        appDelegate.refreshAppVoiceProfilesEditor()
    }

    private func syncAutoCastState() {
        let enabled = appDelegate.autoCastEnabled
        autoCastCheckbox.state = enabled ? .on : .off
        switch appDelegate.castGender {
        case "female": castGenderControl.selectedSegment = 1
        case "male": castGenderControl.selectedSegment = 2
        default: castGenderControl.selectedSegment = 0
        }
        // The gender constraint only applies while dramatizing.
        castGenderControl.isEnabled = enabled
    }

    @objc private func changeCastGender(_ sender: NSSegmentedControl) {
        let value: String
        switch sender.selectedSegment {
        case 1: value = "female"
        case 2: value = "male"
        default: value = "auto"
        }
        appDelegate.setCastGender(value)
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

    @objc private func toggleAutoCast(_ sender: NSButton) {
        appDelegate.setAutoCast(sender.state == .on)
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
        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14

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

        view = makeSettingsScrollView(
            hosting: content,
            insets: NSEdgeInsets(top: 24, left: 28, bottom: 28, right: 28)
        )
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
