import Cocoa

/// An AppKit timeline editor for arranging, trimming, and inspecting speech clips.
@MainActor
final class TimelineView: NSView {
    var timeline: Timeline {
        didSet {
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    var selectedClipID: UUID? {
        didSet { needsDisplay = true }
    }

    var playheadMS: Int {
        didSet { needsDisplay = true }
    }

    var pixelsPerSecond: CGFloat {
        get { storedPixelsPerSecond }
        set {
            let clamped = min(400, max(10, newValue))
            guard clamped != storedPixelsPerSecond else { return }
            storedPixelsPerSecond = clamped
            needsDisplay = true
            invalidateIntrinsicContentSize()
        }
    }

    /// Waveform provider: given a clip and a bucket count, return peak values 0...1.
    /// Return [] when not yet rendered.
    var envelopeProvider: ((TimelineClip, Int) -> [Float])? {
        didSet { needsDisplay = true }
    }

    /// Reports the new value after a user edit so the host can persist and re-mix it.
    var onTimelineChanged: ((Timeline) -> Void)?
    var onSelectionChanged: ((UUID?) -> Void)?
    var onScrub: ((Int) -> Void)?
    var onEditClip: ((UUID) -> Void)?

    private let gutterWidth: CGFloat = 96
    private let rulerHeight: CGFloat = 22
    private let trackHeight: CGFloat = 56
    private let trailingSlack: CGFloat = 240
    private var storedPixelsPerSecond: CGFloat = 60
    private var clipboard: TimelineClip?
    private var trackingArea: NSTrackingArea?

    private enum DragMode {
        case move
        case trimHead
        case trimTail
    }

    private var dragMode: DragMode?
    private var draggedClipID: UUID?
    private var dragSnapshot: Timeline?
    private var grabOffsetMS = 0
    private var previousDragMS = 0
    private var isScrubbing = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        let durationWidth = CGFloat(timeline.totalDurationMS) / 1000 * pixelsPerSecond
        return NSSize(
            width: max(bounds.width, gutterWidth + durationWidth + trailingSlack),
            height: rulerHeight + CGFloat(max(0, timeline.trackCount)) * trackHeight
        )
    }

    override init(frame frameRect: NSRect) {
        timeline = Timeline()
        selectedClipID = nil
        playheadMS = 0
        super.init(frame: frameRect)
    }

    convenience init(timeline: Timeline) {
        self.init(frame: .zero)
        self.timeline = timeline
    }

    required init?(coder: NSCoder) {
        timeline = Timeline()
        selectedClipID = nil
        playheadMS = 0
        super.init(coder: coder)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // Scrolling must redraw instead of copying stale gutter pixels because
        // the gutter is positioned from visibleRect on every draw pass.
        enclosingScrollView?.contentView.copiesOnScroll = false
    }

    func zoomIn() {
        zoom(by: 1.25, anchorX: visibleCenterX)
    }

    func zoomOut() {
        zoom(by: 1 / 1.25, anchorX: visibleCenterX)
    }

    /// Trackpad pinch. `magnification` is a per-event DELTA (roughly -1...1), so
    /// the scale factor is 1 + delta rather than the value itself.
    override func magnify(with event: NSEvent) {
        guard event.magnification != 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + event.magnification, anchorX: point.x)
    }

    /// Option + two-finger scroll also zooms, the DAW convention, so the gesture
    /// works for a mouse as well as a trackpad.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.option) else {
            super.scrollWheel(with: event)
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.deltaY / 10
        guard delta != 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        zoom(by: 1 + delta, anchorX: point.x)
    }

    private var visibleCenterX: CGFloat {
        guard let scrollView = enclosingScrollView else { return bounds.midX }
        return scrollView.documentVisibleRect.midX
    }

    /// Scale the zoom while PINNING the moment under `anchorX` in place. Without
    /// this the content slides out from under the fingers, which is what makes a
    /// naive pinch feel broken. Remember the time at the anchor, rescale, then
    /// scroll so that time lands back at the same on-screen position.
    private func zoom(by factor: CGFloat, anchorX: CGFloat) {
        let anchorMS = xToMS(anchorX)
        let previous = pixelsPerSecond
        pixelsPerSecond = previous * factor
        guard pixelsPerSecond != previous else { return }

        guard let scrollView = enclosingScrollView else { return }
        // Lay out at the new width first, or the clip view clamps the scroll to
        // the OLD document bounds and the anchor drifts at high zoom.
        layoutSubtreeIfNeeded()
        let visibleRect = scrollView.documentVisibleRect
        let offsetOnScreen = anchorX - visibleRect.minX
        let targetOriginX = max(0, msToX(anchorMS) - offsetOnScreen)
        scrollView.contentView.scroll(
            to: NSPoint(x: targetOriginX, y: visibleRect.origin.y)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func zoomToFit(width: CGFloat) {
        guard timeline.totalDurationMS > 0 else {
            pixelsPerSecond = 60
            return
        }
        let usableWidth = max(1, width - gutterWidth - trailingSlack)
        pixelsPerSecond = usableWidth / (CGFloat(timeline.totalDurationMS) / 1000)
    }

    func deleteSelected() {
        guard let id = selectedClipID, timeline.clip(id: id) != nil else { return }
        timeline.remove(id: id)
        setSelection(nil)
        onTimelineChanged?(timeline)
    }

    func duplicateSelected() {
        guard let id = selectedClipID else { return }
        let before = timeline
        guard let newID = timeline.duplicate(id: id), timeline != before else { return }
        setSelection(newID)
        onTimelineChanged?(timeline)
    }

    func copySelected() {
        guard let id = selectedClipID else { return }
        clipboard = timeline.clip(id: id)
    }

    func paste() {
        guard var copy = clipboard else { return }
        let track = selectedClipID.flatMap { timeline.clip(id: $0)?.track } ?? 0
        copy.id = UUID()
        copy.track = max(0, min(max(0, timeline.trackCount - 1), track))
        guard let start = timeline.nearestFreeStart(
            id: copy.id,
            track: copy.track,
            startMS: max(0, playheadMS),
            durationMS: copy.durationMS
        ) else { return }
        copy.startMS = start
        timeline.add(copy)
        setSelection(copy.id)
        onTimelineChanged?(timeline)
    }

    func msToX(_ ms: Int) -> CGFloat {
        gutterWidth + CGFloat(ms) / 1000 * pixelsPerSecond
    }

    func xToMS(_ x: CGFloat) -> Int {
        max(0, Int(((x - gutterWidth) / pixelsPerSecond * 1000).rounded()))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawTracks(in: dirtyRect)
        drawRuler(in: dirtyRect)
        drawClips(in: dirtyRect)
        drawPlayhead(in: dirtyRect)
        // The document view scrolls beneath this final overlay, keeping headers pinned.
        drawGutter(in: dirtyRect)
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let options: NSTrackingArea.Options = [
            .mouseMoved, .activeInKeyWindow, .inVisibleRect,
        ]
        let area = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard point.x >= visibleGutterMaxX, let hit = hitTestClip(at: point) else {
            NSCursor.arrow.set()
            return
        }
        switch hit.zone {
        case .trimHead, .trimTail: NSCursor.resizeLeftRight.set()
        case .body: NSCursor.openHand.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)

        if point.y < rulerHeight, point.x >= visibleGutterMaxX {
            isScrubbing = true
            scrub(to: point)
            return
        }

        guard point.x >= visibleGutterMaxX, let hit = hitTestClip(at: point) else {
            setSelection(nil)
            return
        }

        setSelection(hit.clip.id)
        if event.clickCount == 2 {
            onEditClip?(hit.clip.id)
            return
        }

        draggedClipID = hit.clip.id
        dragSnapshot = timeline
        previousDragMS = xToMS(point.x)
        grabOffsetMS = previousDragMS - hit.clip.startMS
        switch hit.zone {
        case .trimHead: dragMode = .trimHead
        case .trimTail: dragMode = .trimTail
        case .body:
            dragMode = .move
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isScrubbing {
            scrub(to: point)
            return
        }

        guard let id = draggedClipID, let mode = dragMode else { return }
        switch mode {
        case .move:
            guard let clip = timeline.clip(id: id), timeline.trackCount > 0 else { return }
            let desiredStart = xToMS(point.x) - grabOffsetMS
            let snappedStart = snappedStartMS(for: clip, proposedStartMS: max(0, desiredStart))
            let track = trackIndex(at: point.y, clamped: true) ?? clip.track
            if !timeline.move(id: id, toTrack: track, startMS: snappedStart),
               let free = timeline.nearestFreeStart(
                   id: id,
                   track: track,
                   startMS: snappedStart,
                   durationMS: clip.durationMS
               )
            {
                // A rejected overlap falls back to the nearest legal edge.
                _ = timeline.move(id: id, toTrack: track, startMS: free)
            }
        case .trimHead, .trimTail:
            guard let beforeTrim = timeline.clip(id: id) else { return }
            let currentMS = xToMS(point.x)
            let delta = currentMS - previousDragMS
            // Relative deltas prevent each drag event from re-applying prior movement.
            if mode == .trimHead {
                timeline.trim(id: id, headDeltaMS: delta, tailDeltaMS: 0)
            } else {
                timeline.trim(id: id, headDeltaMS: 0, tailDeltaMS: -delta)
            }
            if let trimmed = timeline.clip(id: id), timeline.wouldOverlap(
                id: id,
                track: trimmed.track,
                startMS: trimmed.startMS,
                durationMS: trimmed.durationMS
            ) {
                timeline.update(beforeTrim)
            }
            previousDragMS = currentMS
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isScrubbing {
            scrub(to: point)
            isScrubbing = false
            return
        }

        let snapshot = dragSnapshot
        dragMode = nil
        draggedClipID = nil
        dragSnapshot = nil
        NSCursor.arrow.set()
        if let snapshot, timeline != snapshot {
            onTimelineChanged?(timeline)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        let characters = event.charactersIgnoringModifiers ?? ""

        if event.keyCode == 51 || event.keyCode == 117 {
            deleteSelected()
        } else if command, characters.lowercased() == "c" {
            copySelected()
        } else if command, characters.lowercased() == "v" {
            paste()
        } else if command, characters.lowercased() == "d" {
            duplicateSelected()
        } else if event.keyCode == 123 {
            nudgeSelected(by: shift ? -100 : -10)
        } else if event.keyCode == 124 {
            nudgeSelected(by: shift ? 100 : 10)
        } else if characters == "+" || characters == "=" {
            zoomIn()
        } else if characters == "-" || characters == "_" {
            zoomOut()
        } else {
            super.keyDown(with: event)
        }
    }

    private var visibleGutterMinX: CGFloat { visibleRect.minX }
    private var visibleGutterMaxX: CGFloat { visibleGutterMinX + gutterWidth }

    private func trackIndex(at y: CGFloat, clamped: Bool) -> Int? {
        guard timeline.trackCount > 0 else { return nil }
        let raw = Int(floor((y - rulerHeight) / trackHeight))
        if clamped { return min(timeline.trackCount - 1, max(0, raw)) }
        guard raw >= 0, raw < timeline.trackCount else { return nil }
        return raw
    }

    private func clipRect(for clip: TimelineClip) -> NSRect {
        let x = msToX(clip.startMS)
        let naturalWidth = CGFloat(clip.durationMS) / 1000 * pixelsPerSecond
        let width = max(3, naturalWidth)
        return NSRect(
            x: x,
            y: rulerHeight + CGFloat(clip.track) * trackHeight + 4,
            width: width,
            height: trackHeight - 8
        )
    }

    private enum HitZone {
        case trimHead
        case body
        case trimTail
    }

    private func hitTestClip(at point: NSPoint) -> (clip: TimelineClip, zone: HitZone)? {
        guard let track = trackIndex(at: point.y, clamped: false) else { return nil }
        for clip in timeline.clips(onTrack: track).reversed() {
            let rect = clipRect(for: clip)
            guard rect.contains(point) else { continue }
            // Very short markers have no meaningful middle zone. Treat the
            // whole marker as a body so zero-duration placeholders can move.
            if rect.width < 15 { return (clip, .body) }
            if point.x <= rect.minX + 7 { return (clip, .trimHead) }
            if point.x >= rect.maxX - 7 { return (clip, .trimTail) }
            return (clip, .body)
        }
        return nil
    }

    private func snappedStartMS(for clip: TimelineClip, proposedStartMS: Int) -> Int {
        var anchors = [0, max(0, playheadMS)]
        for other in timeline.clips where other.id != clip.id {
            anchors.append(other.startMS)
            anchors.append(other.endMS)
        }

        var bestDelta: Int?
        for anchor in anchors {
            for edge in [proposedStartMS, proposedStartMS + clip.durationMS] {
                let delta = anchor - edge
                let distance = abs(CGFloat(delta) / 1000 * pixelsPerSecond)
                if distance <= 8, bestDelta == nil || abs(delta) < abs(bestDelta!) {
                    bestDelta = delta
                }
            }
        }
        // Comparing edge deltas makes START and END snapping compete fairly.
        return max(0, proposedStartMS + (bestDelta ?? 0))
    }

    private func scrub(to point: NSPoint) {
        let value = xToMS(point.x)
        playheadMS = value
        onScrub?(value)
    }

    private func setSelection(_ id: UUID?) {
        guard selectedClipID != id else { return }
        selectedClipID = id
        onSelectionChanged?(id)
    }

    private func nudgeSelected(by deltaMS: Int) {
        guard let id = selectedClipID, let clip = timeline.clip(id: id) else { return }
        let before = timeline
        let proposed = max(0, clip.startMS + deltaMS)
        if !timeline.move(id: id, toTrack: clip.track, startMS: proposed),
           let free = timeline.nearestFreeStart(
               id: id,
               track: clip.track,
               startMS: proposed,
               durationMS: clip.durationMS
           )
        {
            _ = timeline.move(id: id, toTrack: clip.track, startMS: free)
        }
        if timeline != before { onTimelineChanged?(timeline) }
    }

    private func drawTracks(in dirtyRect: NSRect) {
        for track in 0..<max(0, timeline.trackCount) {
            let rect = NSRect(
                x: dirtyRect.minX,
                y: rulerHeight + CGFloat(track) * trackHeight,
                width: dirtyRect.width,
                height: trackHeight
            )
            guard rect.intersects(dirtyRect) else { continue }
            let base = NSColor.controlBackgroundColor
            let color = track.isMultiple(of: 2)
                ? base
                : base.blended(withFraction: 0.06, of: .black) ?? base
            color.setFill()
            rect.fill()

            NSColor.separatorColor.setFill()
            NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
        }
    }

    private func drawRuler(in dirtyRect: NSRect) {
        let rulerRect = NSRect(x: dirtyRect.minX, y: 0, width: dirtyRect.width, height: rulerHeight)
        NSColor.windowBackgroundColor.setFill()
        rulerRect.fill()

        let intervals: [CGFloat] = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60]
        let majorSeconds = intervals.first { $0 * pixelsPerSecond >= 56 } ?? 60
        let minorSeconds = majorSeconds / 5
        let visibleStart = max(0, (dirtyRect.minX - gutterWidth) / pixelsPerSecond)
        let visibleEnd = max(0, (dirtyRect.maxX - gutterWidth) / pixelsPerSecond)
        let firstMinor = Int(floor(visibleStart / minorSeconds))
        let lastMinor = Int(ceil(visibleEnd / minorSeconds))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        NSColor.separatorColor.setStroke()
        for index in firstMinor...max(firstMinor, lastMinor) {
            let seconds = CGFloat(index) * minorSeconds
            let x = gutterWidth + seconds * pixelsPerSecond
            let isMajor = index.isMultiple(of: 5)
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: x, y: isMajor ? 10 : 16))
            path.line(to: NSPoint(x: x, y: rulerHeight))
            path.stroke()
            if isMajor {
                let totalSeconds = Int(seconds.rounded())
                let label = String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
                label.draw(at: NSPoint(x: x + 3, y: 1), withAttributes: attributes)
            }
        }

        NSColor.separatorColor.setFill()
        NSRect(x: dirtyRect.minX, y: rulerHeight - 1, width: dirtyRect.width, height: 1).fill()
    }

    private func drawClips(in dirtyRect: NSRect) {
        for clip in timeline.clips {
            let rect = clipRect(for: clip)
            guard rect.intersects(dirtyRect) else { continue }
            let selected = clip.id == selectedClipID
            let envelope = envelopeProvider?(clip, max(1, Int(rect.width / 2))) ?? []
            let placeholder = envelope.isEmpty
            let alpha: CGFloat = (selected ? 0.55 : 0.30) * (placeholder ? 0.5 : 1)
            let shape = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            NSColor.controlAccentColor.withAlphaComponent(alpha).setFill()
            shape.fill()

            if selected {
                NSColor.keyboardFocusIndicatorColor.setStroke()
                shape.lineWidth = 2
                shape.stroke()
            }

            if placeholder {
                drawPlaceholder(in: rect)
            } else {
                drawWaveform(envelope, in: rect)
            }
            if rect.width > 34 { drawLabel(clip.speaker, in: rect) }
        }
    }

    private func drawWaveform(_ envelope: [Float], in rect: NSRect) {
        let centerY = rect.midY
        let maximumHeight = max(1, rect.height - 12)
        let path = NSBezierPath()
        path.lineWidth = 1
        for (index, peak) in envelope.enumerated() {
            let x = rect.minX + 1 + CGFloat(index) * 2
            guard x < rect.maxX - 1 else { break }
            let halfHeight = CGFloat(min(1, max(0, peak))) * maximumHeight / 2
            path.move(to: NSPoint(x: x, y: centerY - halfHeight))
            path.line(to: NSPoint(x: x, y: centerY + halfHeight))
        }
        let color = NSColor.controlAccentColor.blended(withFraction: 0.30, of: .black)
            ?? NSColor.controlAccentColor
        color.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    private func drawPlaceholder(in rect: NSRect) {
        let path = NSBezierPath()
        path.lineWidth = 1
        path.setLineDash([3, 3], count: 2, phase: 0)
        path.move(to: NSPoint(x: rect.minX + 4, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX - 4, y: rect.midY))
        NSColor.secondaryLabelColor.setStroke()
        path.stroke()
    }

    private func drawLabel(_ label: String, in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        let labelRect = NSRect(x: rect.minX + 5, y: rect.minY + 3, width: rect.width - 10, height: 13)
        label.draw(in: labelRect, withAttributes: attributes)
    }

    private func drawPlayhead(in dirtyRect: NSRect) {
        let x = msToX(playheadMS)
        guard x >= dirtyRect.minX - 1, x <= dirtyRect.maxX + 1 else { return }
        NSColor.systemRed.setFill()
        NSRect(x: x - 0.5, y: 0, width: 1, height: bounds.height).fill()
    }

    private func drawGutter(in dirtyRect: NSRect) {
        let gutterRect = NSRect(
            x: visibleGutterMinX,
            y: dirtyRect.minY,
            width: gutterWidth,
            height: dirtyRect.height
        )
        guard gutterRect.intersects(dirtyRect) else { return }
        NSColor.windowBackgroundColor.setFill()
        gutterRect.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        for track in 0..<max(0, timeline.trackCount) {
            let rect = NSRect(
                x: visibleGutterMinX + 8,
                y: rulerHeight + CGFloat(track) * trackHeight + (trackHeight - 14) / 2,
                width: gutterWidth - 16,
                height: 14
            )
            guard rect.intersects(dirtyRect) else { continue }
            timeline.label(forTrack: track).draw(in: rect, withAttributes: attributes)
        }

        NSColor.separatorColor.setFill()
        NSRect(x: visibleGutterMaxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height).fill()
        NSRect(x: visibleGutterMinX, y: rulerHeight - 1, width: gutterWidth, height: 1).fill()
    }
}
