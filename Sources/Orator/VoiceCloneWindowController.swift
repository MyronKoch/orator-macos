import Cocoa
import AVFoundation
import UniformTypeIdentifiers

/// Owns the take until the sheet closes, so recordings never become library files.
@MainActor
final class VoiceCloneWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private unowned let appDelegate: AppDelegate
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let chooseButton = NSButton(title: "Choose File...", target: nil, action: nil)
    private let playButton = NSButton(title: "Play", target: nil, action: nil)
    private let createButton = NSButton(title: "Create Voice", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let sampleLabel = NSTextField(wrappingLabelWithString: "Record a sample or choose an audio file.")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let nameField = NSTextField(string: "")
    private let sanitizedLabel = NSTextField(labelWithString: "Voice name: ")
    private let consentCheckbox = NSButton(
        checkboxWithTitle: "This is my own voice, or I have the speaker's permission to clone it.",
        target: nil, action: nil
    )
    private let levelMeter = NSLevelIndicator()
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var audioURL: URL?
    private var duration: TimeInterval = 0
    private var temporaryFiles: [URL] = []
    private var uploadTask: Task<Void, Never>?
    private var isRequestingMicrophone = false
    private var isChoosingFile = false
    private var isCreating = false
    private var isClosed = false

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 560),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = "Clone a Voice"
        window.isReleasedWhenClosed = false
        window.delegate = self
        configureContent(window)
        updateControls()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func beginSheet(on parent: NSWindow, completion: @escaping () -> Void) {
        guard let window else { return }
        parent.beginSheet(window) { [self] _ in
            cleanUp()
            completion()
        }
    }

    override func close() {
        cleanUp()
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            super.close()
        }
    }

    func windowWillClose(_ notification: Notification) {
        cleanUp()
    }

    private func configureContent(_ window: NSWindow) {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12

        let heading = NSTextField(labelWithString: "Clone a Voice")
        heading.font = .systemFont(ofSize: 22, weight: .bold)
        let helper = NSTextField(
            wrappingLabelWithString: "Read naturally in a quiet room for 15-30 seconds. At least 8 seconds are required. Your sample stays on this Mac."
        )
        helper.font = .systemFont(ofSize: 13)
        helper.textColor = .secondaryLabelColor

        let passage = NSTextView(frame: NSRect(x: 0, y: 0, width: 532, height: 120))
        passage.isEditable = false
        passage.isSelectable = true
        passage.isRichText = false
        passage.font = .systemFont(ofSize: 14)
        passage.textContainerInset = NSSize(width: 8, height: 8)
        passage.isHorizontallyResizable = false
        passage.isVerticallyResizable = true
        passage.autoresizingMask = [.width]
        passage.textContainer?.widthTracksTextView = true
        passage.string = """
        On a bright spring morning, Julia walked through the village garden, listening to birds chatter above the quiet fountain. A gentle breeze shook the silver leaves while a friendly dog chased shadows across the path. She paused beside a wooden bench and smiled. Somewhere nearby, fresh bread was baking, and the rich scent drifted through an open window. What a lovely place to share a story with an old friend.
        """
        let scroll = NSScrollView()
        scroll.documentView = passage
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true

        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        chooseButton.target = self
        chooseButton.action = #selector(chooseFile)
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        for button in [recordButton, chooseButton, playButton, createButton, cancelButton] {
            button.bezelStyle = .rounded
        }
        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        levelMeter.levelIndicatorStyle = .continuousCapacity
        levelMeter.minValue = 0
        levelMeter.maxValue = 1
        levelMeter.warningValue = 0.8
        levelMeter.criticalValue = 0.95
        levelMeter.setAccessibilityLabel("Microphone level")
        levelMeter.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let recordingRow = NSStackView(views: [recordButton, elapsedLabel, levelMeter, chooseButton, playButton])
        recordingRow.orientation = .horizontal
        recordingRow.alignment = .centerY
        recordingRow.spacing = 10

        nameField.placeholderString = "my-voice"
        nameField.delegate = self
        nameField.setAccessibilityLabel("Voice name")
        sanitizedLabel.font = .systemFont(ofSize: 11)
        sanitizedLabel.textColor = .secondaryLabelColor
        sampleLabel.font = .systemFont(ofSize: 12)
        sampleLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        // Reserve room for route and validation errors without moving the action buttons.
        statusLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        consentCheckbox.target = self
        consentCheckbox.action = #selector(consentChanged)
        consentCheckbox.font = .systemFont(ofSize: 12)
        consentCheckbox.cell?.wraps = true

        createButton.target = self
        createButton.action = #selector(createVoice)
        createButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancelButton, createButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let children: [NSView] = [
            heading, helper, scroll, recordingRow, sampleLabel,
            NSTextField(labelWithString: "Name (lowercase letters, digits, and hyphens; up to 40 characters)"),
            nameField, sanitizedLabel, consentCheckbox, statusLabel, buttons,
        ]
        for child in children {
            stack.addArrangedSubview(child)
        }
        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
            helper.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sampleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            consentCheckbox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        // Fit the wrapped consent and help text instead of clipping them in a fixed-height sheet.
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 580, height: max(560, stack.fittingSize.height + 48)))
    }

    func controlTextDidChange(_ notification: Notification) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let raw = nameField.stringValue.lowercased().replacingOccurrences(of: " ", with: "-")
        let sanitized = String(String.UnicodeScalarView(raw.unicodeScalars.filter { allowed.contains($0) }))
        nameField.stringValue = String(sanitized.prefix(40))
        sanitizedLabel.stringValue = "Voice name: \(nameField.stringValue)"
        updateControls()
    }

    private func updateControls() {
        let available = appDelegate.pocketServerURL != nil
        let recording = recorder != nil
        let busy = isCreating || isRequestingMicrophone || isChoosingFile || isClosed
        recordButton.title = recording ? "Stop" : "Record"
        recordButton.isEnabled = (available || recording) && !busy
        chooseButton.isEnabled = available && !recording && !busy
        playButton.isEnabled = audioURL != nil && !recording && !busy
        nameField.isEnabled = !isCreating && !isClosed
        consentCheckbox.isEnabled = !isCreating && !isClosed
        createButton.isEnabled = available && !recording && !busy && audioURL != nil
            && duration >= 8 && !nameField.stringValue.isEmpty && consentCheckbox.state == .on
        if !available {
            statusLabel.stringValue = "Pocket TTS is not running on this Mac. Start Pocket TTS, then reopen this sheet."
        }
    }

    @objc private func consentChanged() {
        updateControls()
    }

    @objc private func toggleRecording() {
        if recorder != nil {
            stopRecording()
            return
        }
        guard appDelegate.pocketServerURL != nil, !isRequestingMicrophone, !isClosed else { return }
        stopPlayback()
        isRequestingMicrophone = true
        updateControls()
        // Permission must resolve before opening an input device, including on the first take.
        Task { [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard let self, !self.isClosed else { return }
            self.isRequestingMicrophone = false
            self.updateControls()
            guard granted else {
                self.showAlert(
                    title: "Microphone access is off",
                    message: "Enable Orator in System Settings > Privacy & Security > Microphone, then try recording again."
                )
                return
            }
            self.startRecording()
        }
    }

    private func startRecording() {
        guard appDelegate.pocketServerURL != nil, !isClosed else { return }
        let url = temporaryURL(extension: "wav")
        do {
            let take = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            take.isMeteringEnabled = true
            guard take.prepareToRecord(), take.record() else {
                throw NSError(domain: "Orator.VoiceClone", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The microphone could not start recording. Check your audio input in System Settings."
                ])
            }
            recorder = take
            audioURL = url
            duration = 0
            elapsedLabel.stringValue = "0:00"
            statusLabel.stringValue = "Recording. Read the passage naturally, then press Stop."
            sampleLabel.stringValue = "New microphone recording"
            startTimer()
        } catch {
            showAlert(title: "Recording failed", message: error.localizedDescription)
        }
        updateControls()
    }

    private func stopRecording() {
        guard let recorder else { return }
        duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        timer?.invalidate()
        timer = nil
        levelMeter.doubleValue = 0
        // Reopen the finalized WAV to validate the sample, including interrupted recordings.
        do {
            if let audioURL {
                let take = try AVAudioPlayer(contentsOf: audioURL)
                duration = take.duration
            }
            updateElapsed(duration)
            statusLabel.stringValue = duration >= 8 ? "Sample ready. Listen to it before creating your voice."
                : "The sample is too short. Record or choose at least 8 seconds of speech."
        } catch {
            audioURL = nil
            duration = 0
            statusLabel.stringValue = "The recording could not be read. Please record another take."
        }
        updateControls()
    }

    private func startTimer() {
        timer?.invalidate()
        // A selector timer stays on the main run loop, where AppKit and recorder state live.
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(updateAudio), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func updateAudio() {
        if let recorder {
            guard recorder.isRecording else {
                stopRecording()
                return
            }
            updateElapsed(recorder.currentTime)
            recorder.updateMeters()
            levelMeter.doubleValue = pow(10, Double(recorder.averagePower(forChannel: 0)) / 20)
        } else if player?.isPlaying != true {
            stopPlayback()
        }
    }

    private func updateElapsed(_ time: TimeInterval) {
        let seconds = Int(max(0, time))
        elapsedLabel.stringValue = String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    @objc private func chooseFile() {
        guard let window, !isClosed, !isCreating, recorder == nil else { return }
        stopPlayback()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["wav", "m4a", "mp3", "aiff"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        isChoosingFile = true
        updateControls()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, !self.isClosed else { return }
            self.isChoosingFile = false
            defer { self.updateControls() }
            guard response == .OK, let source = panel.url else { return }
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            do {
                // Own a copy so the chosen file can move without invalidating a later upload.
                let copy = self.temporaryURL(extension: source.pathExtension.lowercased())
                try FileManager.default.copyItem(at: source, to: copy)
                let take = try AVAudioPlayer(contentsOf: copy)
                guard take.duration.isFinite, take.duration > 0 else {
                    throw NSError(domain: "Orator.VoiceClone", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Choose an audio file containing speech."
                    ])
                }
                self.audioURL = copy
                self.duration = take.duration
                self.sampleLabel.stringValue = source.lastPathComponent
                self.updateElapsed(take.duration)
                self.statusLabel.stringValue = take.duration >= 8 ? "Sample ready. Listen to it before creating your voice."
                    : "The sample is too short. Choose at least 8 seconds of speech."
            } catch {
                self.showAlert(title: "Could not open audio", message: error.localizedDescription)
            }
        }
    }

    @objc private func togglePlayback() {
        if player != nil {
            stopPlayback()
            return
        }
        guard let audioURL, recorder == nil, !isCreating, !isClosed else { return }
        do {
            let take = try AVAudioPlayer(contentsOf: audioURL)
            guard take.play() else {
                throw NSError(domain: "Orator.VoiceClone", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "The sample could not be played. Check your audio output."
                ])
            }
            player = take
            playButton.title = "Stop Playback"
            startTimer()
        } catch {
            showAlert(title: "Playback failed", message: error.localizedDescription)
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playButton.title = "Play"
        if recorder == nil {
            timer?.invalidate()
            timer = nil
        }
    }

    @objc private func createVoice() {
        updateControls()
        guard createButton.isEnabled, let baseURL = appDelegate.pocketServerURL,
              LocalTTSProvider.isLoopback(baseURL), let audioURL else { return }
        stopPlayback()
        isCreating = true
        statusLabel.stringValue = "Creating your voice on this Mac..."
        updateControls()
        let name = nameField.stringValue
        uploadTask = Task { [weak self] in
            guard let self else { return }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 300
            let session = URLSession(configuration: configuration, delegate: VoiceCloneSessionDelegate(), delegateQueue: nil)
            defer {
                session.invalidateAndCancel()
                self.isCreating = false
                self.uploadTask = nil
                if !self.isClosed { self.updateControls() }
            }
            do {
                let boundary = "Orator-\(UUID().uuidString)"
                var request = URLRequest(url: baseURL.appendingPathComponent("v1/voices"))
                request.httpMethod = "POST"
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.httpBody = try self.multipartBody(name: name, audioURL: audioURL, boundary: boundary)
                let (data, response) = try await session.data(for: request)
                guard !self.isClosed, !Task.isCancelled else { return }
                guard let http = response as? HTTPURLResponse else {
                    self.statusLabel.stringValue = "Pocket TTS returned an unreadable response."
                    return
                }
                switch http.statusCode {
                case 201:
                    self.appDelegate.refreshLocalVoices()
                    self.statusLabel.stringValue = "Voice created"
                    self.showAlert(title: "Voice created", message: "\(name) is now available in Orator.") { [weak self] in
                        self?.close()
                    }
                case 400, 409:
                    let fallback = http.statusCode == 409 ? "That voice name is taken. Choose another name."
                        : "Pocket TTS could not create this voice. Check the sample and name."
                    self.statusLabel.stringValue = self.serverMessage(data) ?? fallback
                case 404:
                    self.statusLabel.stringValue = "Pocket TTS is not running on this Mac, or this server does not support voice cloning yet. Start or update Pocket TTS and try again."
                default:
                    self.statusLabel.stringValue = self.serverMessage(data) ?? "Pocket TTS returned HTTP \(http.statusCode). Please try again."
                }
            } catch {
                guard !self.isClosed, !Task.isCancelled else { return }
                if let error = error as? URLError,
                   [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .timedOut].contains(error.code) {
                    self.statusLabel.stringValue = "Pocket TTS is not running or could not be reached on this Mac. Start Pocket TTS with voice cloning support and try again."
                } else {
                    self.statusLabel.stringValue = "Could not create voice: \(error.localizedDescription)"
                }
            }
        }
    }

    private func multipartBody(name: String, audioURL: URL, boundary: String) throws -> Data {
        let contentType: String
        switch audioURL.pathExtension.lowercased() {
        case "m4a": contentType = "audio/mp4"
        case "mp3": contentType = "audio/mpeg"
        case "aiff", "aif": contentType = "audio/aiff"
        default: contentType = "audio/wav"
        }
        var body = Data()
        func append(_ text: String) { body.append(contentsOf: text.utf8) }
        for (field, value) in [("name", name), ("consent", "true")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"\r\n\r\n\(value)\r\n")
        }
        // Use our generated filename, never a user's filename in an HTTP header.
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"sample.\(audioURL.pathExtension)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private func serverMessage(_ data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            for key in ["message", "detail", "error"] {
                if let message = json[key] as? String, !message.isEmpty { return message }
            }
        }
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.flatMap { $0.isEmpty ? nil : String($0.prefix(1000)) }
    }

    private func showAlert(title: String, message: String, completion: (() -> Void)? = nil) {
        guard let window, !isClosed else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in completion?() }
    }

    private func temporaryURL(extension fileExtension: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Orator-voice-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        temporaryFiles.append(url)
        return url
    }

    @objc private func cancel() {
        close()
    }

    private func cleanUp() {
        guard !isClosed else { return }
        isClosed = true
        uploadTask?.cancel()
        uploadTask = nil
        recorder?.stop()
        recorder = nil
        stopPlayback()
        for url in temporaryFiles where FileManager.default.fileExists(atPath: url.path) {
            do {
                _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                oratorLog("Could not clean up voice sample: \(error.localizedDescription)")
            }
        }
        temporaryFiles.removeAll()
        audioURL = nil
    }
}

/// A local upload must never follow a redirect that could send the sample off this Mac.
private final class VoiceCloneSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
