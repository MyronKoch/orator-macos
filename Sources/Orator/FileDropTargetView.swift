import AppKit

/// A lightweight AppKit drop destination shared by the Reader and status item.
@MainActor
final class FileDropTargetView: NSView {
    var onDrop: (([URL]) -> Void)?
    var forwardsClicksTo: NSButton?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        supportedURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !supportedURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = supportedURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if let forwardsClicksTo {
            forwardsClicksTo.performClick(nil)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func supportedURLs(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        let urls = objects.compactMap { ($0 as? NSURL) as URL? }
        guard !urls.isEmpty, urls.allSatisfy(FileTextExtractor.supports) else { return [] }
        return urls
    }
}
