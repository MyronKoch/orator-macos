import Cocoa
import Carbon.HIToolbox
import AVFoundation

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var currentTask: Process?
    private var isPlaying = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        checkAccessibilityPermission()
        setupStatusItem()
        registerGlobalHotKey()
        NSLog("KokoroSpeak: Ready (using localhost:8880)")
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
        menu.addItem(withTitle: "Hotkey: \u{2325} '  (Option + ')", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func quit() {
        currentTask?.terminate()
        let stop = Process()
        stop.executableURL = URL(fileURLWithPath: "/bin/bash")
        stop.arguments = ["-l", "-c", "\(NSHomeDirectory())/bin/kokoro-stop"]
        try? stop.run()
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
        NSLog("KokoroSpeak: InstallEventHandler: %d", handlerStatus)

        var hotKeyIDVar = hotKeyID
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_Quote),
            UInt32(optionKey),
            hotKeyIDVar,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        NSLog("KokoroSpeak: RegisterHotKey(Option+'): %d (0=ok)", status)
    }

    // MARK: - Toggle Handler

    func handleHotKey() {
        NSLog("KokoroSpeak: Hotkey fired! isPlaying=%d", isPlaying ? 1 : 0)

        // Toggle off
        if isPlaying {
            currentTask?.terminate()
            let stop = Process()
            stop.executableURL = URL(fileURLWithPath: "/bin/bash")
            stop.arguments = ["-l", "-c", "\(NSHomeDirectory())/bin/kokoro-stop"]
            try? stop.run()
            isPlaying = false
            updateIcon(speaking: false)
            return
        }

        // Copy selected text
        let pasteboard = NSPasteboard.general
        let saved = savePasteboard(pasteboard)
        let changeCount = pasteboard.changeCount
        simulateCopy()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }

            var text = ""
            if pasteboard.changeCount != changeCount {
                text = pasteboard.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            self.restorePasteboard(pasteboard, items: saved)

            // Normalize newlines
            text = text.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                NSLog("KokoroSpeak: No text selected")
                return
            }

            NSLog("KokoroSpeak: Speaking %d chars", text.count)
            self.updateIcon(speaking: true)

            // Pipe to kokoro-speak
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-l", "-c", "\(NSHomeDirectory())/bin/kokoro-speak"]

            let pipe = Pipe()
            if let data = text.data(using: .utf8) {
                pipe.fileHandleForWriting.write(data)
            }
            pipe.fileHandleForWriting.closeFile()
            task.standardInput = pipe

            task.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.isPlaying = false
                    self?.updateIcon(speaking: false)
                }
            }

            do {
                try task.run()
                self.currentTask = task
                self.isPlaying = true
            } catch {
                NSLog("KokoroSpeak: Failed: %@", error.localizedDescription)
                self.updateIcon(speaking: false)
            }
        }
    }

    // MARK: - Clipboard

    private func savePasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
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

    private func simulateCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func updateIcon(speaking: Bool) {
        if let button = statusItem.button {
            let name = speaking ? "headphones.circle.fill" : "headphones"
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Kokoro Speak")
        }
    }

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
