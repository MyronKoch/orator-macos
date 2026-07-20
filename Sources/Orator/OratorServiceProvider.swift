import Cocoa

/// Handles the macOS Services entries ("Speak with Orator", "Add to Orator
/// Queue") that appear in the right-click menu after selecting text in any app.
///
/// The Services are declared under `NSServices` in Info.plist; each `NSMessage`
/// there names one of the `@objc` methods below. macOS delivers the selected
/// text on a pasteboard; we hop to the main actor and hand it to AppDelegate.
final class OratorServiceProvider: NSObject {

    @objc func speakWithOrator(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        guard let text = readableText(from: pboard) else { return }
        DispatchQueue.main.async { AppDelegate.shared?.serviceSpeak(text) }
    }

    @objc func addToOratorQueue(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        guard let text = readableText(from: pboard) else { return }
        DispatchQueue.main.async { AppDelegate.shared?.serviceQueue(text) }
    }

    private func readableText(from pboard: NSPasteboard) -> String? {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }
}
