import Cocoa
import Carbon.HIToolbox
import IOKit.hid

/// Shared diagnostic logger (also used by AppDelegate's speech pipeline).
func oratorLog(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    let path = "/tmp/orator-hotkey.log"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
    NSLog("Orator: %@", message)
}

/// Global hotkey listener for Option+' with triple-redundant capture paths.
///
/// macOS has three ways to observe global keystrokes, each with different
/// permission requirements that have shifted across OS releases:
///   1. Carbon RegisterEventHotKey - no permission required (historically)
///   2. NSEvent global monitor      - Accessibility or Input Monitoring
///   3. CGEventTap (listen-only)    - Accessibility (session tap) / Input Monitoring
///
/// We install all three and dedupe: whichever fires first within a debounce
/// window wins. A debug log at /tmp/orator-hotkey.log records which paths
/// actually deliver events on this machine.
final class HotkeyManager: @unchecked Sendable {

    private var keyCode: UInt16 = 39                    // default: apostrophe
    private var altKeyCode: UInt16? = nil               // no secondary chord; custom combos are set via the recorder
    private var modifiers: NSEvent.ModifierFlags = [.option]

    // Second action: pause/resume. nil keyCode disables it entirely.
    private var pauseKeyCode: UInt16? = 35              // default: P
    private var pauseModifiers: NSEvent.ModifierFlags = [.option]

    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonPauseHotKeyRef: EventHotKeyRef?
    private var carbonInstallStatus: OSStatus?
    private var didInstallCarbonHandler = false
    private var nsEventMonitor: Any?
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?

    private var lastFire = Date.distantPast
    private var lastPauseFire = Date.distantPast
    private let onFire: () -> Void
    private let onPauseFire: (() -> Void)?

    init(onFire: @escaping () -> Void, onPauseFire: (() -> Void)? = nil) {
        self.onFire = onFire
        self.onPauseFire = onPauseFire
    }

    // MARK: - Public

    func installAll() {
        requestInputMonitoringIfNeeded()
        installCarbon()
        registerCarbonHotKey()
        registerCarbonPauseHotKey()
        installNSEventMonitor()
        installEventTap()
        censusEventTaps()
    }

    func reconfigure(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.altKeyCode = nil
        self.modifiers = modifiers
        registerCarbonHotKey()
        log("hotkey reconfigured: keyCode=\(keyCode) modifiers=\(modifiers.rawValue)")
    }

    /// Reconfigure (or disable, with nil keyCode) the pause/resume hotkey.
    func reconfigurePause(keyCode: UInt16?, modifiers: NSEvent.ModifierFlags) {
        self.pauseKeyCode = keyCode
        self.pauseModifiers = modifiers
        registerCarbonPauseHotKey()
        log("pause hotkey reconfigured: keyCode=\(keyCode.map(String.init) ?? "disabled") modifiers=\(modifiers.rawValue)")
    }

    /// Log every process holding a system event tap - identifies key-swallowers.
    private func censusEventTaps() {
        var count: UInt32 = 0
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: 64)
        guard CGGetEventTapList(64, &taps, &count) == .success else {
            log("tap census failed")
            return
        }
        for tap in taps.prefix(Int(count)) {
            let keyboardMask: UInt64 = (1 << CGEventType.keyDown.rawValue)
            let listensKeys = tap.eventsOfInterest & keyboardMask != 0
            let pid = tap.tappingProcess
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? processName(pid: pid) ?? "pid \(pid)"
            log("tap census: \(name) pid=\(pid) keys=\(listensKeys) options=\(tap.options.rawValue) enabled=\(tap.enabled)")
        }
    }

    private func processName(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
    }

    fileprivate enum Action { case speak, pause }

    /// Debounced dispatch - three paths may all fire for one keypress.
    /// Debounce windows are per-action so a pause right after a speak works.
    fileprivate func fire(from source: String, action: Action = .speak) {
        log("FIRE via \(source)")
        DispatchQueue.main.async { [self] in
            let now = Date()
            switch action {
            case .speak:
                guard now.timeIntervalSince(lastFire) > 0.3 else { return }
                lastFire = now
                onFire()
            case .pause:
                guard now.timeIntervalSince(lastPauseFire) > 0.3 else { return }
                lastPauseFire = now
                onPauseFire?()
            }
        }
    }

    func log(_ message: String) {
        oratorLog(message)
    }

    private func carbonModifiers(for target: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if target.contains(.option) { result |= UInt32(optionKey) }
        if target.contains(.command) { result |= UInt32(cmdKey) }
        if target.contains(.control) { result |= UInt32(controlKey) }
        if target.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func matchesCGEventModifiers(_ flags: CGEventFlags, target: NSEvent.ModifierFlags) -> Bool {
        (flags.contains(.maskAlternate) == target.contains(.option))
            && (flags.contains(.maskCommand) == target.contains(.command))
            && (flags.contains(.maskControl) == target.contains(.control))
            && (flags.contains(.maskShift) == target.contains(.shift))
    }

    private func matchesNSEventModifiers(_ flags: NSEvent.ModifierFlags, target: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.option, .command, .control, .shift]) == target
    }

    // MARK: - Permissions

    private func requestInputMonitoringIfNeeded() {
        let status = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        log("InputMonitoring status: \(status.rawValue) (0=granted 1=denied 2=unknown)")
        if status != kIOHIDAccessTypeGranted {
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            log("InputMonitoring request → \(granted)")
        }
    }

    // MARK: - Path 1: Carbon

    private func installCarbon() {
        guard !didInstallCarbonHandler else { return }
        didInstallCarbonHandler = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // MASShortcut-style: dispatcher target, not application target.
        let target = GetEventDispatcherTarget()
        let installStatus = InstallEventHandler(
            target,
            { (_, event, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                if hotKeyID.id == 2 {
                    manager.fire(from: "carbon-pause", action: .pause)
                } else {
                    manager.fire(from: "carbon")
                }
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        carbonInstallStatus = installStatus
    }

    private func registerCarbonHotKey() {
        if let carbonHotKeyRef {
            UnregisterEventHotKey(carbonHotKeyRef)
            self.carbonHotKeyRef = nil
        }

        let target = GetEventDispatcherTarget()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F524154) /* 'ORAT' */, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(keyCode), carbonModifiers(for: modifiers), hotKeyID, target, 0, &carbonHotKeyRef
        )
        let installStatus = carbonInstallStatus ?? OSStatus(eventNotHandledErr)
        log("carbon install=\(installStatus) register=\(registerStatus)")
    }

    private func registerCarbonPauseHotKey() {
        if let carbonPauseHotKeyRef {
            UnregisterEventHotKey(carbonPauseHotKeyRef)
            self.carbonPauseHotKeyRef = nil
        }
        guard let pauseKeyCode else {
            log("carbon pause: disabled")
            return
        }

        let target = GetEventDispatcherTarget()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F524154) /* 'ORAT' */, id: 2)
        let registerStatus = RegisterEventHotKey(
            UInt32(pauseKeyCode), carbonModifiers(for: pauseModifiers), hotKeyID, target, 0, &carbonPauseHotKeyRef
        )
        log("carbon pause register=\(registerStatus)")
    }

    // MARK: - Path 2: NSEvent global monitor

    private func installNSEventMonitor() {
        nsEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let matchesKey = event.keyCode == self.keyCode
                || (self.altKeyCode.map { event.keyCode == $0 } ?? false)
            if matchesKey, self.matchesNSEventModifiers(event.modifierFlags, target: self.modifiers) {
                self.fire(from: "nsevent")
                return
            }
            if let pauseKeyCode = self.pauseKeyCode,
               event.keyCode == pauseKeyCode,
               self.matchesNSEventModifiers(event.modifierFlags, target: self.pauseModifiers) {
                self.fire(from: "nsevent-pause", action: .pause)
            }
        }
        log("nsevent monitor installed=\(nsEventMonitor != nil)")
    }

    // MARK: - Path 3: CGEventTap (listen-only)

    private func installEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if type == .keyDown, let userInfo = userInfo {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags
                let matchesKey = keyCode == Int64(manager.keyCode)
                    || (manager.altKeyCode.map { keyCode == Int64($0) } ?? false)
                if matchesKey, manager.matchesCGEventModifiers(flags, target: manager.modifiers) {
                    manager.fire(from: "eventtap")
                } else if let pauseKeyCode = manager.pauseKeyCode,
                          keyCode == Int64(pauseKeyCode),
                          manager.matchesCGEventModifiers(flags, target: manager.pauseModifiers) {
                    manager.fire(from: "eventtap-pause", action: .pause)
                }
            }
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            log("eventtap: tapCreate FAILED (permission not effective)")
            return
        }
        eventTap = tap
        tapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("eventtap installed OK")
    }
}
