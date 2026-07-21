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

    @objc func readFilesWithOrator(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        let urls = fileURLs(from: pboard)
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async { AppDelegate.shared?.serviceReadFiles(urls) }
    }

    @objc func queueFilesInOrator(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        let urls = fileURLs(from: pboard)
        guard !urls.isEmpty else { return }
        DispatchQueue.main.async { AppDelegate.shared?.serviceQueueFiles(urls) }
    }

    private func readableText(from pboard: NSPasteboard) -> String? {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return text
    }

    private func fileURLs(from pboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = pboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        var urls = objects.compactMap { ($0 as? NSURL) as URL? }

        // Finder can still use the legacy filenames pasteboard type declared
        // in Info.plist, particularly when invoking Services for many files.
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if let filenames = pboard.propertyList(forType: filenamesType) as? [String] {
            urls.append(contentsOf: filenames.map { URL(fileURLWithPath: $0) })
        }

        var seen = Set<URL>()
        return urls.filter { seen.insert($0).inserted }
    }
}
