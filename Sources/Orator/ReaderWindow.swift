import Cocoa

@MainActor
private protocol ReaderTextViewInteractionDelegate: AnyObject {
    func readerTextView(_ textView: ReaderTextView, clickedCharacterAt index: Int)
    func readerTextView(_ textView: ReaderTextView, handleKeyDown event: NSEvent) -> Bool
}

@MainActor
private final class ReaderTextView: NSTextView {
    weak var interactionDelegate: (any ReaderTextViewInteractionDelegate)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let characterIndex = characterIndexForInsertion(at: point)
        super.mouseDown(with: event)
        // super runs the full click/drag tracking loop. If it ended with a
        // selection (drag or double-click), the user was selecting text, not
        // asking to jump playback.
        guard selectedRange().length == 0 else { return }
        interactionDelegate?.readerTextView(self, clickedCharacterAt: characterIndex)
    }

    override func keyDown(with event: NSEvent) {
        if interactionDelegate?.readerTextView(self, handleKeyDown: event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

/// Reusable AppKit window for follow-along reading and sentence navigation.
@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate,
    ReaderTextViewInteractionDelegate
{
    var onFilesDropped: (([URL]) -> Void)?

    private let session: ReaderSession
    private let scrollView = NSScrollView()
    private let textView = ReaderTextView(frame: .zero)
    private let emptyMessage = NSTextField(
        wrappingLabelWithString: "Orator isn't reading anything. Select text and press your hotkey, or copy text and reopen the Reader."
    )
    private let progressLabel = NSTextField(labelWithString: "0:00")
    private let backButton = NSButton()
    private let playPauseButton = NSButton()
    private let stopButton = NSButton()
    private let forwardButton = NSButton()
    private var highlightedRange: NSRange?
    private var suppressAutoScrollUntil: TimeInterval = 0

    // Reader text size (⌘+/⌘-/⌘0), persisted across sessions.
    private static let fontSizeKey = "readerFontSize"
    private static let defaultFontSize: CGFloat = 16
    private var readerFontSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "readerFontSize")
        return saved >= 10 ? CGFloat(saved) : 16
    }()

    init(timeline: SpeechTimeline, engine: OratorEngine) {
        session = ReaderSession(timeline: timeline, engine: engine)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        configureWindow(window)
        configureContent(in: window)
        bindSession()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(text rawText: String?) {
        clearHighlight()
        session.load(rawText: rawText ?? "")
        presentWindow()
    }

    func showFollowingTimeline() {
        clearHighlight()
        session.syncFromTimeline()
        presentWindow()
    }

    private func presentWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
    }

    func windowWillClose(_ notification: Notification) {
        clearHighlight()
        session.cleanup()
    }

    private func configureWindow(_ window: NSWindow) {
        window.title = "Orator Reader"
        window.minSize = NSSize(width: 520, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("OratorReader")
    }

    private func configureContent(in window: NSWindow) {
        let contentView = FileDropTargetView()
        contentView.onDrop = { [weak self] urls in
            self?.onFilesDropped?(urls)
        }
        window.contentView = contentView

        configureTextView()
        configureControlButtons()

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let controlBar = NSView()
        controlBar.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [backButton, playPauseButton, stopButton, forwardButton])
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        progressLabel.translatesAutoresizingMaskIntoConstraints = false
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.alignment = .right
        progressLabel.setContentHuggingPriority(.required, for: .horizontal)

        emptyMessage.translatesAutoresizingMaskIntoConstraints = false
        emptyMessage.font = .systemFont(ofSize: 15)
        emptyMessage.textColor = .secondaryLabelColor
        emptyMessage.alignment = .center
        emptyMessage.maximumNumberOfLines = 0
        emptyMessage.preferredMaxLayoutWidth = 380

        contentView.addSubview(scrollView)
        contentView.addSubview(controlBar)
        contentView.addSubview(emptyMessage)
        controlBar.addSubview(controls)
        controlBar.addSubview(progressLabel)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: controlBar.topAnchor),

            controlBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            controlBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            controlBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            controlBar.heightAnchor.constraint(equalToConstant: 54),

            controls.centerXAnchor.constraint(equalTo: controlBar.centerXAnchor),
            controls.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),

            progressLabel.trailingAnchor.constraint(equalTo: controlBar.trailingAnchor, constant: -16),
            progressLabel.centerYAnchor.constraint(equalTo: controlBar.centerYAnchor),
            progressLabel.leadingAnchor.constraint(greaterThanOrEqualTo: controls.trailingAnchor, constant: 16),

            emptyMessage.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyMessage.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyMessage.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 40),
            emptyMessage.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -40),
        ])

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(userDidScroll(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        center.addObserver(
            self,
            selector: #selector(userDidScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
    }

    private func configureTextView() {
        textView.interactionDelegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.usesFindBar = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 24, height: 28)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
    }

    private func configureControlButtons() {
        configure(
            backButton,
            symbolName: "backward.fill",
            accessibilityLabel: "Previous sentence",
            action: #selector(skipBackward)
        )
        configure(
            playPauseButton,
            symbolName: "play.fill",
            accessibilityLabel: "Play",
            action: #selector(togglePlayPause)
        )
        configure(
            stopButton,
            symbolName: "stop.fill",
            accessibilityLabel: "Stop",
            action: #selector(stopPlayback)
        )
        configure(
            forwardButton,
            symbolName: "forward.fill",
            accessibilityLabel: "Next sentence",
            action: #selector(skipForward)
        )
    }

    private func configure(
        _ button: NSButton,
        symbolName: String,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )
        button.imagePosition = .imageOnly
        button.bezelStyle = .texturedRounded
        button.target = self
        button.action = action
        button.toolTip = accessibilityLabel
        button.setAccessibilityLabel(accessibilityLabel)
        button.widthAnchor.constraint(equalToConstant: 34).isActive = true
    }

    private func bindSession() {
        session.onActiveWordChanged = { [weak self] range in
            self?.showHighlight(for: range)
        }
        session.onStateChanged = { [weak self] _ in
            self?.updateControls()
        }
        session.onProgressChanged = { [weak self] elapsed, chunkIndex in
            self?.updateProgress(elapsed: elapsed, chunkIndex: chunkIndex)
        }
        session.onDocumentChanged = { [weak self] in
            self?.clearHighlight()
            self?.displayDocument()
        }
    }

    private func displayDocument() {
        textView.string = session.text

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = 1.35
        paragraphStyle.paragraphSpacing = 6
        let fullRange = NSRange(location: 0, length: session.text.utf16.count)
        textView.textStorage?.setAttributes([
            .font: NSFont.systemFont(ofSize: readerFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraphStyle,
        ], range: fullRange)

        emptyMessage.isHidden = !session.text.isEmpty
        textView.scrollToBeginningOfDocument(nil)
        updateProgress(elapsed: 0, chunkIndex: nil)
        updateControls()
    }

    private func applyReaderFont() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        storage.addAttribute(
            .font,
            value: NSFont.systemFont(ofSize: readerFontSize),
            range: NSRange(location: 0, length: storage.length)
        )
        // The word highlight is a temporary layout attribute; re-apply it so it
        // survives the relayout a font change triggers.
        if let range = highlightedRange { showHighlight(for: range) }
    }

    private func changeReaderFontSize(by delta: CGFloat) {
        setReaderFontSize(readerFontSize + delta)
    }

    private func setReaderFontSize(_ size: CGFloat) {
        readerFontSize = min(max(size, 10), 48)
        UserDefaults.standard.set(Double(readerFontSize), forKey: Self.fontSizeKey)
        applyReaderFont()
    }

    private func showHighlight(for range: NSRange?) {
        clearHighlight()
        guard let range,
              range.location != NSNotFound,
              NSMaxRange(range) <= textView.string.utf16.count,
              let layoutManager = textView.layoutManager
        else { return }

        layoutManager.addTemporaryAttribute(
            .backgroundColor,
            value: NSColor.controlAccentColor.withAlphaComponent(0.35),
            forCharacterRange: range
        )
        highlightedRange = range
        scrollToHighlightedWordIfNeeded(range)
    }

    private func clearHighlight() {
        guard let range = highlightedRange else { return }
        textView.layoutManager?.removeTemporaryAttribute(
            .backgroundColor,
            forCharacterRange: range
        )
        highlightedRange = nil
    }

    private func scrollToHighlightedWordIfNeeded(_ characterRange: NSRange) {
        guard ProcessInfo.processInfo.systemUptime >= suppressAutoScrollUntil,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        layoutManager.ensureLayout(forCharacterRange: characterRange)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var wordRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let origin = textView.textContainerOrigin
        wordRect.origin.x += origin.x
        wordRect.origin.y += origin.y

        let safeVisibleRect = textView.visibleRect.insetBy(dx: 0, dy: 60)
        if wordRect.minY < safeVisibleRect.minY || wordRect.maxY > safeVisibleRect.maxY {
            textView.scrollRangeToVisible(characterRange)
        }
    }

    @objc private func userDidScroll(_ notification: Notification) {
        suppressAutoScrollUntil = ProcessInfo.processInfo.systemUptime + 2
    }

    private func updateProgress(elapsed: TimeInterval, chunkIndex: Int?) {
        if let chunkIndex, session.chunkCount > 0 {
            progressLabel.stringValue = "sentence \(chunkIndex + 1) of \(session.chunkCount)"
        } else {
            let totalSeconds = max(0, Int(elapsed.rounded(.down)))
            progressLabel.stringValue = String(
                format: "%d:%02d",
                totalSeconds / 60,
                totalSeconds % 60
            )
        }
        updateControls()
    }

    private func updateControls() {
        let hasText = session.chunkCount > 0
        let currentIndex = session.currentChunkIndex ?? 0
        let isPlaying = session.state == .playing

        playPauseButton.image = NSImage(
            systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: isPlaying ? "Pause" : "Play"
        )
        playPauseButton.toolTip = isPlaying ? "Pause" : "Play"
        playPauseButton.setAccessibilityLabel(isPlaying ? "Pause" : "Play")
        playPauseButton.isEnabled = hasText
        stopButton.isEnabled = session.state != .idle
        backButton.isEnabled = hasText && currentIndex > 0
        forwardButton.isEnabled = hasText && currentIndex < session.chunkCount - 1
    }

    @objc private func skipBackward() {
        session.skip(by: -1)
    }

    @objc private func togglePlayPause() {
        session.togglePlayPause()
    }

    @objc private func stopPlayback() {
        session.stop()
    }

    @objc private func skipForward() {
        session.skip(by: 1)
    }

    fileprivate func readerTextView(_ textView: ReaderTextView, clickedCharacterAt index: Int) {
        guard let chunkIndex = session.chunkIndex(containingCharacterAt: index) else { return }
        session.play(fromChunk: chunkIndex)
    }

    fileprivate func readerTextView(_ textView: ReaderTextView, handleKeyDown event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            window?.performClose(nil)
            return true
        }

        // Standard text-size shortcuts: ⌘+ / ⌘= larger, ⌘- smaller, ⌘0 reset.
        if modifiers.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "=", "+":
                changeReaderFontSize(by: 2)
                return true
            case "-":
                changeReaderFontSize(by: -2)
                return true
            case "0":
                setReaderFontSize(Self.defaultFontSize)
                return true
            default:
                break
            }
        }

        let disallowedPlaybackModifiers: NSEvent.ModifierFlags = [.command, .option, .control]
        guard modifiers.intersection(disallowedPlaybackModifiers).isEmpty else { return false }

        switch event.keyCode {
        case 49:
            session.togglePlayPause()
            return true
        case 123:
            session.skip(by: -1)
            return true
        case 124:
            session.skip(by: 1)
            return true
        default:
            return false
        }
    }
}
