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

    static let keyCode: UInt16 = 39      // ANSI apostrophe
    static let altKeyCode: UInt16 = 36   // Return — accepted as an alternate chord

    private var carbonHotKeyRef: EventHotKeyRef?
    private var nsEventMonitor: Any?
    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?

    private var lastFire = Date.distantPast
    private let onFire: () -> Void

    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
    }

    // MARK: - Public

    func installAll() {
        requestInputMonitoringIfNeeded()
        installCarbon()
        installNSEventMonitor()
        installEventTap()
        censusEventTaps()
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

    /// Debounced dispatch - three paths may all fire for one keypress.
    fileprivate func fire(from source: String) {
        log("FIRE via \(source)")
        DispatchQueue.main.async { [self] in
            let now = Date()
            guard now.timeIntervalSince(lastFire) > 0.3 else { return }
            lastFire = now
            onFire()
        }
    }

    func log(_ message: String) {
        oratorLog(message)
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
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // MASShortcut-style: dispatcher target, not application target.
        let target = GetEventDispatcherTarget()
        let installStatus = InstallEventHandler(
            target,
            { (_, _, userData) -> OSStatus in
                guard let userData = userData else { return OSStatus(eventNotHandledErr) }
                Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue().fire(from: "carbon")
                return noErr
            },
            1, &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        let hotKeyID = EventHotKeyID(signature: OSType(0x4F524154) /* 'ORAT' */, id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(Self.keyCode), UInt32(optionKey), hotKeyID, target, 0, &carbonHotKeyRef
        )
        log("carbon install=\(installStatus) register=\(registerStatus)")
    }

    // MARK: - Path 2: NSEvent global monitor

    private func installNSEventMonitor() {
        nsEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == Self.keyCode,
                  event.modifierFlags.intersection([.option, .command, .control, .shift]) == .option
            else { return }
            self?.fire(from: "nsevent")
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
                if (keyCode == Int64(HotkeyManager.keyCode) || keyCode == Int64(HotkeyManager.altKeyCode)),
                   flags.contains(.maskAlternate),
                   !flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskShift) {
                    manager.fire(from: "eventtap")
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
