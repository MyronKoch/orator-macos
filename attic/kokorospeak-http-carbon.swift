import Cocoa
import Carbon.HIToolbox

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private let pidFile = "/tmp/kokoro-speak.pid"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        registerGlobalHotKey()
        checkAccessibilityPermission()
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
        runScript("\(kokoroStopPath())")
        NSApp.terminate(nil)
    }

    // MARK: - Global Hotkey (Carbon)

    private func registerGlobalHotKey() {
        var hotKeyID = EventHotKeyID(signature: OSType(0x4B4F4B4F), id: 1)

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
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

        // Option + ' (apostrophe) - keycode 39
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_Quote),
            UInt32(optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status != noErr {
            NSLog("KokoroSpeak: Failed to register hotkey (status: %d)", status)
        }
    }

    // MARK: - Hotkey Handler

    func handleHotKey() {
        if isCurrentlySpeaking() {
            runScript("\(kokoroStopPath())")
            updateIcon(speaking: false)
        } else {
            speakSelectedText()
        }
    }

    private func isCurrentlySpeaking() -> Bool {
        guard FileManager.default.fileExists(atPath: pidFile),
              let pidString = try? String(contentsOfFile: pidFile, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidString) else {
            return false
        }
        return kill(pid, 0) == 0
    }

    // MARK: - Speak

    private func speakSelectedText() {
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let savedItems = savePasteboard(pasteboard)
        let changeCount = pasteboard.changeCount

        // Simulate Cmd+C to copy selected text
        simulateCopy()

        // Wait for clipboard to update
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }

            var text = ""
            if pasteboard.changeCount != changeCount {
                text = pasteboard.string(forType: .string)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }

            // Restore original clipboard
            self.restorePasteboard(pasteboard, items: savedItems)

            guard !text.isEmpty else { return }

            // Pipe text to kokoro-speak via stdin
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/bash")
            task.arguments = ["-l", "-c", self.kokoroSpeakPath()]

            let pipe = Pipe()
            if let data = text.data(using: .utf8) {
                pipe.fileHandleForWriting.write(data)
            }
            pipe.fileHandleForWriting.closeFile()
            task.standardInput = pipe

            task.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateIcon(speaking: false)
                }
            }

            do {
                try task.run()
                self.updateIcon(speaking: true)
            } catch {
                NSLog("KokoroSpeak: Failed to run kokoro-speak: %@", error.localizedDescription)
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

    // MARK: - Status Icon

    private func updateIcon(speaking: Bool) {
        if let button = statusItem.button {
            let name = speaking ? "headphones.circle.fill" : "headphones"
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Kokoro Speak")
        }
    }

    // MARK: - Accessibility Check

    private func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSLog("KokoroSpeak: Accessibility permission needed for global hotkey + copy simulation")
        }
    }

    // MARK: - Paths

    private func kokoroSpeakPath() -> String {
        return "\(NSHomeDirectory())/bin/kokoro-speak"
    }

    private func kokoroStopPath() -> String {
        return "\(NSHomeDirectory())/bin/kokoro-stop"
    }

    private func runScript(_ path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-l", "-c", path]
        try? task.run()
    }
}

// Entry point
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
