import AppKit

/// A focused editing surface for the same value-type timeline shown inline in
/// Script settings. Edits are pushed back immediately so both views stay useful.
@MainActor
final class TimelineEditorWindowController: NSWindowController, NSWindowDelegate {
    private var timeline: Timeline
    private let timelineView: TimelineView
    private let scrollView = NSScrollView()
    private let toolControl: NSSegmentedControl
    private let playPauseButton = NSButton()
    private let positionLabel = NSTextField(labelWithString: "0:00 / 0:00")

    private let timelineChangedHandler: (Timeline) -> Void
    private let playHandler: (Int) -> Void
    private let stopHandler: () -> Void
    private let playingProvider: () -> Bool
    private let playheadProvider: () -> Int

    private var playheadTimer: Timer?
    private var keyMonitor: Any?

    init(
        timeline: Timeline,
        envelopeProvider: @escaping (TimelineClip, Int) -> [Float],
        onTimelineChanged: @escaping (Timeline) -> Void,
        onPlay: @escaping (Int) -> Void,
        onStop: @escaping () -> Void,
        isPlaying: @escaping () -> Bool,
        playheadMS: @escaping () -> Int
    ) {
        self.timeline = timeline
        timelineView = TimelineView(timeline: timeline)
        timelineChangedHandler = onTimelineChanged
        playHandler = onPlay
        stopHandler = onStop
        playingProvider = isPlaying
        playheadProvider = playheadMS

        let pointerImage = NSImage(
            systemSymbolName: "cursorarrow",
            accessibilityDescription: "Pointer"
        ) ?? NSImage()
        let razorImage = NSImage(
            systemSymbolName: "scissors",
            accessibilityDescription: "Razor"
        ) ?? NSImage()
        toolControl = NSSegmentedControl(
            images: [pointerImage, razorImage],
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        window.title = "Timeline Editor"
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.setFrameAutosaveName("OratorTimelineEditor")
        window.delegate = self

        configureContent(envelopeProvider: envelopeProvider)
        updatePlayhead(playheadMS())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateTimeline(_ timeline: Timeline) {
        self.timeline = timeline
        timelineView.timeline = timeline
        timelineView.playheadMS = min(timelineView.playheadMS, timeline.totalDurationMS)
        updatePositionLabel()
    }

    func updatePlayhead(_ ms: Int) {
        timelineView.playheadMS = min(max(0, ms), max(0, timelineView.timeline.totalDurationMS))
        updatePositionLabel()
        updateTransportState()
        if playingProvider(), window?.isVisible == true {
            startPlayheadTimer()
        }
    }

    func show() {
        installKeyMonitorIfNeeded()
        updateTransportState()
        if playingProvider() { startPlayheadTimer() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(timelineView)
    }

    func windowWillClose(_ notification: Notification) {
        playheadTimer?.invalidate()
        playheadTimer = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func configureContent(
        envelopeProvider: @escaping (TimelineClip, Int) -> [Float]
    ) {
        guard let window else { return }

        toolControl.selectedSegment = 0
        toolControl.target = self
        toolControl.action = #selector(changeTool(_:))
        toolControl.setToolTip("Pointer", forSegment: 0)
        toolControl.setToolTip("Razor", forSegment: 1)

        let startButton = transportButton(
            symbolName: "backward.end.fill",
            description: "Jump to start",
            action: #selector(jumpToStart)
        )
        let backButton = transportButton(
            symbolName: "gobackward.5",
            description: "Move playhead back 5 seconds",
            action: #selector(skipBackward)
        )
        playPauseButton.target = self
        playPauseButton.action = #selector(togglePlayback)
        let stopButton = transportButton(
            symbolName: "stop.fill",
            description: "Stop",
            action: #selector(stopPlayback)
        )
        let forwardButton = transportButton(
            symbolName: "goforward.5",
            description: "Move playhead forward 5 seconds",
            action: #selector(skipForward)
        )
        let endButton = transportButton(
            symbolName: "forward.end.fill",
            description: "Jump to end",
            action: #selector(jumpToEnd)
        )

        positionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        positionLabel.alignment = .center
        positionLabel.setContentHuggingPriority(.required, for: .horizontal)

        let zoomOutButton = NSButton(title: "-", target: self, action: #selector(zoomOut))
        zoomOutButton.toolTip = "Zoom out"
        let zoomInButton = NSButton(title: "+", target: self, action: #selector(zoomIn))
        zoomInButton.toolTip = "Zoom in"
        let fitButton = NSButton(title: "Fit", target: self, action: #selector(zoomToFit))

        let bar = NSStackView(views: [
            toolControl,
            separator(),
            startButton,
            backButton,
            playPauseButton,
            stopButton,
            forwardButton,
            endButton,
            positionLabel,
            separator(),
            zoomOutButton,
            zoomInButton,
            fitButton,
        ])
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 7
        bar.edgeInsets = NSEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)

        timelineView.envelopeProvider = envelopeProvider
        timelineView.onTimelineChanged = { [weak self] updated in
            guard let self else { return }
            self.timeline = updated
            self.updatePositionLabel()
            self.timelineChangedHandler(updated)
        }
        timelineView.onToolChanged = { [weak self] tool in
            self?.toolControl.selectedSegment = tool == .pointer ? 0 : 1
        }
        timelineView.onScrub = { [weak self] ms in
            guard let self else { return }
            self.updatePlayhead(ms)
            if self.playingProvider() {
                self.playHandler(ms)
                self.startPlayheadTimer()
            }
        }
        timelineView.onTogglePlayback = { [weak self] in
            self?.togglePlayback()
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.documentView = timelineView
        timelineView.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(bar)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            timelineView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            timelineView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            timelineView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
            timelineView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
        ])
        window.contentView = root
    }

    private func transportButton(
        symbolName: String,
        description: String,
        action: Selector
    ) -> NSButton {
        let button = NSButton(title: description, target: self, action: action)
        if let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: description
        ) {
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        }
        button.toolTip = description
        button.setAccessibilityLabel(description)
        return button
    }

    private func separator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return separator
    }

    @objc private func changeTool(_ sender: NSSegmentedControl) {
        timelineView.tool = sender.selectedSegment == 1 ? .razor : .pointer
        window?.makeFirstResponder(timelineView)
    }

    @objc private func jumpToStart() {
        seek(to: 0)
    }

    @objc private func skipBackward() {
        seek(to: timelineView.playheadMS - 5_000)
    }

    @objc private func skipForward() {
        seek(to: timelineView.playheadMS + 5_000)
    }

    @objc private func jumpToEnd() {
        seek(to: timeline.totalDurationMS)
    }

    private func seek(to ms: Int) {
        updatePlayhead(ms)
        if playingProvider() {
            playHandler(timelineView.playheadMS)
            startPlayheadTimer()
        }
        window?.makeFirstResponder(timelineView)
    }

    @objc private func togglePlayback() {
        if playingProvider() {
            stopHandler()
            stopPlayheadTimer()
        } else {
            playHandler(timelineView.playheadMS)
            if playingProvider() { startPlayheadTimer() }
        }
        updateTransportState()
        window?.makeFirstResponder(timelineView)
    }

    @objc private func stopPlayback() {
        stopHandler()
        stopPlayheadTimer()
        updateTransportState()
        window?.makeFirstResponder(timelineView)
    }

    @objc private func zoomOut() {
        timelineView.zoomOut()
        window?.makeFirstResponder(timelineView)
    }

    @objc private func zoomIn() {
        timelineView.zoomIn()
        window?.makeFirstResponder(timelineView)
    }

    @objc private func zoomToFit() {
        timelineView.zoomToFit(width: scrollView.contentSize.width)
        window?.makeFirstResponder(timelineView)
    }

    private func startPlayheadTimer() {
        guard playheadTimer == nil else { return }
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.playingProvider() {
                    self.updatePlayhead(self.playheadProvider())
                    self.updateTransportState()
                } else {
                    self.playheadTimer?.invalidate()
                    self.playheadTimer = nil
                    self.updateTransportState()
                }
            }
        }
        playheadTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopPlayheadTimer() {
        playheadTimer?.invalidate()
        playheadTimer = nil
    }

    private func updateTransportState() {
        let playing = playingProvider()
        let symbolName = playing ? "pause.fill" : "play.fill"
        let description = playing ? "Pause" : "Play"
        playPauseButton.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: description
        )
        playPauseButton.imagePosition = .imageOnly
        playPauseButton.title = playPauseButton.image == nil ? description : ""
        playPauseButton.toolTip = description
        playPauseButton.setAccessibilityLabel(description)
    }

    private func updatePositionLabel() {
        let duration = max(0, timeline.totalDurationMS)
        let position = min(max(0, timelineView.playheadMS), duration)
        positionLabel.stringValue = "\(Self.durationText(position)) / \(Self.durationText(duration))"
    }

    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let windowNumber = event.windowNumber
            let characters = event.charactersIgnoringModifiers
            let modifiers = event.modifierFlags
            let handled = MainActor.assumeIsolated {
                self.handleToolKey(
                    windowNumber: windowNumber,
                    characters: characters,
                    modifiers: modifiers
                )
            }
            return handled ? nil : event
        }
    }

    private func handleToolKey(
        windowNumber: Int,
        characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard window?.windowNumber == windowNumber else { return false }
        let significantModifiers = modifiers.intersection([.command, .control, .option])
        guard significantModifiers.isEmpty else { return false }
        switch characters?.lowercased() {
        case "v":
            timelineView.tool = .pointer
        case "b":
            timelineView.tool = .razor
        default:
            return false
        }
        window?.makeFirstResponder(timelineView)
        return true
    }

    private static func durationText(_ durationMS: Int) -> String {
        let totalSeconds = max(0, durationMS) / 1000
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
