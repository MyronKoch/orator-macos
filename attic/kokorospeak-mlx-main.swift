import Cocoa
import Carbon.HIToolbox
import AVFoundation
import KokoroSwift
import MLX
import MLXUtilsLibrary

// MARK: - TTS Engine

final class TTSEngine: @unchecked Sendable {
    private let tts: KokoroTTS
    private var voices: [String: MLXArray] = [:]
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var isPlaying = false
    private let lock = NSLock()

    var currentVoice: String = "af_heart"
    var speed: Float = 1.0

    var voiceNames: [String] {
        voices.keys.map { $0.replacingOccurrences(of: ".npy", with: "") }.sorted()
    }

    var playing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isPlaying
    }

    init(modelPath: URL, voicesPath: URL) throws {
        // Configure GPU memory
        GPU.set(cacheLimit: 50 * 1024 * 1024)
        GPU.set(memoryLimit: 900 * 1024 * 1024)

        // Load model
        tts = KokoroTTS(modelPath: modelPath)

        // Load voices from NPZ
        guard let loadedVoices = NpyzReader.read(fileFromPath: voicesPath) else {
            throw TTSError.voicesNotFound
        }
        voices = loadedVoices

        // Audio format: 24kHz mono float32
        format = AVAudioFormat(standardFormatWithSampleRate: Double(KokoroTTS.Constants.samplingRate), channels: 1)!

        // Set up audio engine
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: format)
    }

    func speak(_ text: String) throws {
        guard let voiceEmbedding = voices[currentVoice + ".npy"] else {
            throw TTSError.voiceNotFound(currentVoice)
        }

        // Determine language from voice prefix
        let language: Language = currentVoice.hasPrefix("b") ? .enGB : .enUS
        NSLog("KokoroSpeak: Generating with voice=%@, lang=%@", currentVoice, language.rawValue)

        // Generate audio (synchronous MLX inference)
        let (samples, _) = try tts.generateAudio(
            voice: voiceEmbedding,
            language: language,
            text: text,
            speed: speed
        )

        guard !samples.isEmpty else { return }

        // Convert [Float] to AVAudioPCMBuffer
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { src in
            UnsafeMutableRawPointer(buffer.floatChannelData![0])
                .copyMemory(from: UnsafeRawPointer(src.baseAddress!), byteCount: src.count * MemoryLayout<Float>.stride)
        }

        // Play
        if !audioEngine.isRunning {
            try audioEngine.start()
        }

        lock.lock()
        isPlaying = true
        lock.unlock()

        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: .interrupts) { [weak self] in
            self?.lock.lock()
            self?.isPlaying = false
            self?.lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .ttsFinished, object: nil)
            }
        }
        playerNode.play()
    }

    func stop() {
        playerNode.stop()
        lock.lock()
        isPlaying = false
        lock.unlock()
    }
}

enum TTSError: Error {
    case modelNotFound
    case voicesNotFound
    case voiceNotFound(String)
}

extension Notification.Name {
    static let ttsFinished = Notification.Name("ttsFinished")
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var engine: TTSEngine?
    private var voiceMenuItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkAccessibilityPermission()
        loadEngine()
        setupStatusItem()
        registerGlobalHotKey()
    }

    // MARK: - Engine Setup

    private func loadEngine() {
        // Look for model in app bundle first, then HuggingFace cache
        let bundleResources = Bundle.main.resourceURL

        let modelPath = findFile(
            name: "kokoro-v1_0", ext: "safetensors",
            in: bundleResources,
            fallback: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub/models--prince-canuma--Kokoro-82M/snapshots")
        )

        let voicesPath = findFile(
            name: "voices", ext: "npz",
            in: bundleResources,
            fallback: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Projects/KokoroSpeak")
        )

        guard let modelPath = modelPath else {
            showNotification("Model not found", body: "kokoro-v1_0.safetensors not found")
            return
        }
        guard let voicesPath = voicesPath else {
            showNotification("Voices not found", body: "voices.npz not found")
            return
        }

        do {
            engine = try TTSEngine(modelPath: modelPath, voicesPath: voicesPath)
            NSLog("KokoroSpeak: Engine loaded (%d voices)", engine?.voiceNames.count ?? 0)
        } catch {
            showNotification("Engine failed", body: error.localizedDescription)
            NSLog("KokoroSpeak: Engine init failed: %@", error.localizedDescription)
        }
    }

    private func findFile(name: String, ext: String, in bundleDir: URL?, fallback: URL) -> URL? {
        // Check bundle
        if let bundleDir = bundleDir {
            let bundlePath = bundleDir.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: bundlePath.path) {
                return bundlePath
            }
        }

        // Check fallback directory recursively
        if let enumerator = FileManager.default.enumerator(at: fallback, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                if url.lastPathComponent == "\(name).\(ext)" {
                    return url
                }
            }
        }
        return nil
    }

    // MARK: - Menu Bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "headphones", accessibilityDescription: "Kokoro Speak")
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Kokoro Speak", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        // Voice submenu
        let voiceItem = NSMenuItem(title: "Voice", action: nil, keyEquivalent: "")
        let voiceMenu = NSMenu()
        for voiceName in engine?.voiceNames ?? [] {
            let item = NSMenuItem(title: formatVoiceName(voiceName), action: #selector(selectVoice(_:)), keyEquivalent: "")
            item.representedObject = voiceName
            item.target = self
            if voiceName == engine?.currentVoice {
                item.state = .on
            }
            voiceMenu.addItem(item)
            voiceMenuItems.append(item)
        }
        voiceItem.submenu = voiceMenu
        menu.addItem(voiceItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Hotkey: \u{2325} '  (Option + ')", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")

        statusItem.menu = menu
    }

    private func formatVoiceName(_ name: String) -> String {
        let parts = name.split(separator: "_")
        guard parts.count == 2 else { return name }
        let prefix = parts[0]
        let voiceName = parts[1].capitalized
        let accent = prefix.hasPrefix("a") ? "US" : "GB"
        let gender = prefix.hasSuffix("f") ? "F" : "M"
        return "\(voiceName) (\(accent) \(gender))"
    }

    @objc private func selectVoice(_ sender: NSMenuItem) {
        guard let voiceName = sender.representedObject as? String else { return }
        engine?.currentVoice = voiceName
        for item in voiceMenuItems {
            item.state = (item.representedObject as? String) == voiceName ? .on : .off
        }
    }

    @objc private func quit() {
        engine?.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Global Hotkey

    private func registerGlobalHotKey() {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B4F4B4F), id: 1)

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { delegate.handleHotKey() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        NSLog("KokoroSpeak: InstallEventHandler status: %d (0=success)", handlerStatus)

        var hotKeyIDVar = hotKeyID
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_Quote),
            UInt32(optionKey),
            hotKeyIDVar,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        NSLog("KokoroSpeak: RegisterEventHotKey(Option+Quote) status: %d (0=success)", status)
        NSLog("KokoroSpeak: RegisterEventHotKey(Option+Quote) status: %d (0=success)", status)

        if status != noErr {
            NSLog("KokoroSpeak: Failed to register hotkey (status: %d)", status)
        }
    }

    // MARK: - Hotkey Handler

    func handleHotKey() {
        guard let engine = engine else {
            showNotification("Engine not ready", body: "Kokoro TTS engine is not loaded")
            return
        }

        // Toggle: if playing, stop
        if engine.playing {
            engine.stop()
            updateIcon(speaking: false)
            return
        }

        // Get selected text via Cmd+C simulation
        let pasteboard = NSPasteboard.general
        let savedItems = savePasteboard(pasteboard)
        let changeCount = pasteboard.changeCount

        simulateCopy()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }

            var text = ""
            if pasteboard.changeCount != changeCount {
                text = pasteboard.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }

            // Restore clipboard
            self.restorePasteboard(pasteboard, items: savedItems)

            // Normalize text: collapse newlines into spaces
            text = text.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { return }

            self.updateIcon(speaking: true)

            // Run TTS on background thread (synchronous MLX call)
            NSLog("KokoroSpeak: Speaking text (%d chars): %@", text.count, String(text.prefix(80)))
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try engine.speak(text)
                } catch {
                    NSLog("KokoroSpeak: TTS error: %@ (type: %@)", error.localizedDescription, String(describing: type(of: error)))
                    DispatchQueue.main.async {
                        self.showNotification("TTS Error", body: "\(error)")
                        self.updateIcon(speaking: false)
                    }
                }
            }

            // Listen for playback completion
            NotificationCenter.default.addObserver(
                forName: .ttsFinished, object: nil, queue: .main
            ) { [weak self] _ in
                self?.updateIcon(speaking: false)
            }
        }
    }

    // MARK: - Clipboard Save/Restore

    private func savePasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            var dict = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
    }

    private func restorePasteboard(_ pb: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        for itemDict in items {
            let item = NSPasteboardItem()
            for (type, data) in itemDict {
                item.setData(data, forType: type)
            }
            pb.writeObjects([item])
        }
    }

    // MARK: - Simulate Cmd+C

    private func simulateCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - UI

    private func updateIcon(speaking: Bool) {
        if let button = statusItem.button {
            let name = speaking ? "headphones.circle.fill" : "headphones"
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Kokoro Speak")
        }
    }

    private func showNotification(_ title: String, body: String) {
        let script = "display notification \"\(body)\" with title \"\(title)\""
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(nil)
        }
    }

    // MARK: - Accessibility

    private func checkAccessibilityPermission() {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options = [promptKey: kCFBooleanTrue!] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog("KokoroSpeak: Accessibility permission needed")
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
