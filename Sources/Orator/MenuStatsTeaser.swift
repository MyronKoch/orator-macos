import Cocoa

/// A compact, live reading-stats summary hosted by an `NSMenuItem`.
/// The caller hands it one value snapshot so drawing never touches the store.
@MainActor
final class MenuStatsTeaser: NSView {

    weak var menuItem: NSMenuItem?

    private let snapshot: ReadingStatsSnapshot
    private weak var actionTarget: AnyObject?
    private let action: Selector
    private var trackingArea: NSTrackingArea?
    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(snapshot: ReadingStatsSnapshot, target: AnyObject, action: Selector) {
        self.snapshot = snapshot
        actionTarget = target
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 286, height: 58))
        toolTip = "Open the Orator Dashboard"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(
            "Reading stats: \(snapshot.wordsToday) words today, "
                + "\(snapshot.currentStreakDays)-day streak. Open Dashboard."
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        menuItem?.menu?.cancelTracking()
        NSApp.sendAction(action, to: actionTarget, from: self)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        if isHovered {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 2), xRadius: 6, yRadius: 6).fill()
        }

        let primaryColor: NSColor = isHovered ? .alternateSelectedControlTextColor : .labelColor
        let secondaryColor: NSColor = isHovered ? .alternateSelectedControlTextColor : .secondaryLabelColor
        drawSparkline(color: isHovered ? .alternateSelectedControlTextColor : .controlAccentColor)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let wordsText = "\(formatted(snapshot.wordsToday)) words today" as NSString
        wordsText.draw(
            in: NSRect(x: 112, y: 30, width: bounds.width - 124, height: 18),
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: primaryColor,
                .paragraphStyle: paragraph,
            ]
        )

        let streakText = "\(snapshot.currentStreakDays)-day streak" as NSString
        streakText.draw(
            in: NSRect(x: 112, y: 12, width: bounds.width - 124, height: 16),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: secondaryColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func drawSparkline(color: NSColor) {
        let points = Array(snapshot.week.prefix(7))
        guard !points.isEmpty else { return }

        let graphRect = NSRect(x: 14, y: 12, width: 84, height: 34)
        let maximum = max(1, points.map(\.words).max() ?? 1)
        let path = NSBezierPath()
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        for (index, point) in points.enumerated() {
            let x = graphRect.minX
                + (points.count == 1 ? 0 : CGFloat(index) / CGFloat(points.count - 1) * graphRect.width)
            let y = graphRect.minY + CGFloat(point.words) / CGFloat(maximum) * graphRect.height
            let location = NSPoint(x: x, y: max(graphRect.minY + 1, y))
            index == 0 ? path.move(to: location) : path.line(to: location)
        }
        color.setStroke()
        path.stroke()

        if let todayIndex = points.lastIndex(where: \.isToday) {
            let point = points[todayIndex]
            let x = graphRect.minX
                + (points.count == 1 ? 0 : CGFloat(todayIndex) / CGFloat(points.count - 1) * graphRect.width)
            let y = max(
                graphRect.minY + 1,
                graphRect.minY + CGFloat(point.words) / CGFloat(maximum) * graphRect.height
            )
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 3, y: y - 3, width: 6, height: 6)).fill()
        }
    }

    private func formatted(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}
