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

/// The global actions a chord can trigger. Each action owns a stable Carbon
/// hotkey ID so the shared Carbon handler can route events back to it.
enum HotkeyAction: String, CaseIterable, Sendable {
    case speak
    case pause
    case queue
    case dramatize

    var carbonID: UInt32 {
        switch self {
        case .speak: return 1
        case .pause: return 2
        case .queue: return 3
        case .dramatize: return 4
        }
    }

    static func from(carbonID id: UInt32) -> HotkeyAction? {
        allCases.first { $0.carbonID == id }
    }
}

/// Global hotkey listener with triple-redundant capture paths.
///
/// macOS has three ways to observe global keystrokes, each with different
/// permission requirements that have shifted across OS releases:
///   1. Carbon RegisterEventHotKey - no permission required (historically)
///   2. NSEvent global monitor      - Accessibility or Input Monitoring
///   3. CGEventTap (listen-only)    - Accessibility (session tap) / Input Monitoring
///
/// We install all three and dedupe: whichever fires first within a per-action
/// debounce window wins. A debug log at /tmp/orator-hotkey.log records which
/// paths actually deliver events on this machine.
///
/// Multiple actions are supported via a binding table; each action carries a
/// stable Carbon hotkey ID and its own debounce clock. All mutation happens on
/// the main thread, and all three capture paths deliver on the main run loop.
final class HotkeyManager: @unchecked Sendable {

    struct Binding {
        /// nil disables the action entirely.
        var keyCode: UInt16?
        var modifiers: NSEvent.ModifierFlags
    }

    /// Defaults: Option+' speaks, Option+P pauses, Option+Q queues.
    private var bindings: [HotkeyAction: Binding] = [
        .speak: Binding(keyCode: 39, modifiers: [.option]),
        .pause: Binding(keyCode: 35, modifiers: [.option]),
        .queue: Binding(keyCode: 12, modifiers: [.option]),
        .dramatize: Binding(keyCode: nil, modifiers: [.option]),
    ]
    /// Legacy secondary chord for speak. Stays nil; custom combos come from
    /// the recorder. NEVER default this to Return (keyCode 36) - it was
    /// removed in v1.1.1 for interfering with normal typing.
    private var altKeyCode: UInt16? = nil

    private var carbonRefs: [HotkeyAction: EventHotKeyRef] = [:]
    private var carbonInstallStatus: OSStatus?
    private var didInstallCarbonHandler = false
    private var nsEventMonitor: Any?
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?

    private var lastFires: [HotkeyAction: Date] = [:]
    private let onAction: (HotkeyAction) -> Void

    init(onAction: @escaping (HotkeyAction) -> Void) {
        self.onAction = onAction
    }

    // MARK: - Public

    func installAll() {
        requestInputMonitoringIfNeeded()
        installCarbon()
        for action in HotkeyAction.allCases {
            registerCarbonHotKey(for: action)
        }
        installNSEventMonitor()
        installEventTap()
        censusEventTaps()
    }

    /// Reconfigure (or disable, with nil keyCode) an action's chord.
    func reconfigure(_ action: HotkeyAction, keyCode: UInt16?, modifiers: NSEvent.ModifierFlags) {
        bindings[action] = Binding(keyCode: keyCode, modifiers: modifiers)
        if action == .speak { altKeyCode = nil }
        registerCarbonHotKey(for: action)
        log("hotkey reconfigured: \(action.rawValue) keyCode=\(keyCode.map(String.init) ?? "disabled") modifiers=\(modifiers.rawValue)")
    }

    /// The current chord for an action (nil keyCode means disabled).
    func binding(for action: HotkeyAction) -> Binding? {
        bindings[action]
    }

    // MARK: - Legacy conveniences (existing call sites)

    func reconfigure(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        reconfigure(.speak, keyCode: keyCode, modifiers: modifiers)
    }

    func reconfigurePause(keyCode: UInt16?, modifiers: NSEvent.ModifierFlags) {
        reconfigure(.pause, keyCode: keyCode, modifiers: modifiers)
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

    /// Match a pressed key against the binding table. Returns the action to
    /// fire, or nil. The legacy speak alt chord is honored when set.
    fileprivate func action(forKeyCode keyCode: UInt16, nsModifiers flags: NSEvent.ModifierFlags) -> HotkeyAction? {
        let pressed = flags.intersection([.option, .command, .control, .shift])
        for action in HotkeyAction.allCases {
            guard let binding = bindings[action], let bound = binding.keyCode else { continue }
            let matchesKey = keyCode == bound
                || (action == .speak && (altKeyCode.map { keyCode == $0 } ?? false))
            if matchesKey, pressed == binding.modifiers {
                return action
            }
        }
        return nil
    }

    fileprivate func nsModifiers(fromCGFlags flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if flags.contains(.maskAlternate) { result.insert(.option) }
        if flags.contains(.maskCommand) { result.insert(.command) }
        if flags.contains(.maskControl) { result.insert(.control) }
        if flags.contains(.maskShift) { result.insert(.shift) }
        return result
    }

    /// Debounced dispatch - three paths may all fire for one keypress.
    /// Debounce windows are per-action so, e.g., pause right after speak works.
    fileprivate func fire(from source: String, action: HotkeyAction) {
        log("FIRE via \(source)")
        DispatchQueue.main.async { [self] in
            let now = Date()
            let last = lastFires[action] ?? .distantPast
            guard now.timeIntervalSince(last) > 0.3 else { return }
            lastFires[action] = now
            onAction(action)
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
                let action = HotkeyAction.from(carbonID: hotKeyID.id) ?? .speak
                manager.fire(from: "carbon-\(action.rawValue)", action: action)
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        carbonInstallStatus = installStatus
    }

    private func registerCarbonHotKey(for action: HotkeyAction) {
        if let existing = carbonRefs[action] {
            UnregisterEventHotKey(existing)
            carbonRefs[action] = nil
        }
        guard let binding = bindings[action], let keyCode = binding.keyCode else {
            log("carbon \(action.rawValue): disabled")
            return
        }

        let target = GetEventDispatcherTarget()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F524154) /* 'ORAT' */, id: action.carbonID)
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(
            UInt32(keyCode), carbonModifiers(for: binding.modifiers), hotKeyID, target, 0, &ref
        )
        carbonRefs[action] = ref
        let installStatus = carbonInstallStatus ?? OSStatus(eventNotHandledErr)
        log("carbon \(action.rawValue) install=\(installStatus) register=\(registerStatus)")
    }

    // MARK: - Path 2: NSEvent global monitor

    private func installNSEventMonitor() {
        nsEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            if let action = self.action(forKeyCode: event.keyCode, nsModifiers: event.modifierFlags) {
                self.fire(from: "nsevent-\(action.rawValue)", action: action)
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
                let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
                let modifiers = manager.nsModifiers(fromCGFlags: event.flags)
                if let action = manager.action(forKeyCode: keyCode, nsModifiers: modifiers) {
                    manager.fire(from: "eventtap-\(action.rawValue)", action: action)
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
