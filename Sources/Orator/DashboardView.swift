import Cocoa

@MainActor
final class DashboardViewController: NSViewController {

    private unowned let appDelegate: AppDelegate
    private let dashboardView: DashboardView

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        dashboardView = DashboardView(
            goalUpdater: { words in appDelegate.updateWeeklyGoalWords(words) },
            voiceDisplayName: { voice in appDelegate.displayName(for: voice) }
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = dashboardView
    }

    func refresh() {
        dashboardView.render(appDelegate.statsSnapshot)
    }
}

/// The flagship stats view. It consumes one immutable snapshot per refresh.
@MainActor
final class DashboardView: NSView {

    private let goalUpdater: (Int) -> ReadingStatsSnapshot
    private let voiceDisplayName: (String) -> String

    private let lifetimeWordsLabel = NSTextField(labelWithString: "0")
    private let hoursLabel = NSTextField(labelWithString: "0.0")
    private let streakLabel = NSTextField(labelWithString: "0 days")
    private let bestStreakLabel = NSTextField(labelWithString: "Best 0 days")
    private let goalRing = WeeklyGoalRingView()
    private let goalProgressLabel = NSTextField(labelWithString: "0 / 0 this week")
    private let goalField = NSTextField()
    private let goalStepper = NSStepper()
    private let weekChart = WeeklyBarChartView()
    private let sourcesList = RankingListView(maximumRows: 5)
    private let voicesList = RankingListView(maximumRows: 4)
    private let longestTitleLabel = NSTextField(wrappingLabelWithString: "No reads yet")
    private let longestDetailLabel = NSTextField(labelWithString: "Your longest read will appear here.")
    private let totalReadsLabel = NSTextField(labelWithString: "0")
    private let averageWordsLabel = NSTextField(labelWithString: "0")
    private let castReadsLabel = NSTextField(labelWithString: "0")

    init(
        goalUpdater: @escaping (Int) -> ReadingStatsSnapshot,
        voiceDisplayName: @escaping (String) -> String
    ) {
        self.goalUpdater = goalUpdater
        self.voiceDisplayName = voiceDisplayName
        super.init(frame: .zero)
        configureView()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(_ snapshot: ReadingStatsSnapshot) {
        lifetimeWordsLabel.stringValue = formatted(snapshot.lifetimeWords)
        hoursLabel.stringValue = String(format: "%.1f", snapshot.lifetimeSeconds / 3_600)
        streakLabel.stringValue = dayCount(snapshot.currentStreakDays)
        bestStreakLabel.stringValue = "Best \(dayCount(snapshot.bestStreakDays).lowercased())"

        goalRing.fraction = snapshot.weeklyGoalFraction
        goalProgressLabel.stringValue = "\(formatted(snapshot.wordsThisWeek)) / "
            + "\(formatted(snapshot.weeklyGoalWords)) this week"
        goalField.integerValue = snapshot.weeklyGoalWords
        goalStepper.integerValue = snapshot.weeklyGoalWords

        weekChart.points = snapshot.week
        sourcesList.render(snapshot.topSources, name: { $0 })
        voicesList.render(snapshot.topVoices, name: voiceDisplayName)

        if let longest = snapshot.longest {
            longestTitleLabel.stringValue = longest.title
            let minutes = longest.seconds / 60
            longestDetailLabel.stringValue = "\(formatted(longest.words)) words  •  "
                + "\(String(format: "%.1f", minutes)) min  •  "
                + voiceDisplayName(longest.voice)
        } else {
            longestTitleLabel.stringValue = "No reads yet"
            longestDetailLabel.stringValue = "Your longest read will appear here."
        }

        totalReadsLabel.stringValue = formatted(snapshot.totalReads)
        averageWordsLabel.stringValue = formatted(snapshot.averageWordsPerRead)
        castReadsLabel.stringValue = formatted(snapshot.castReads)
    }

    private func configureView() {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        documentView.addSubview(content)

        let heading = NSTextField(labelWithString: "Dashboard")
        heading.font = .systemFont(ofSize: 26, weight: .bold)
        let intro = NSTextField(labelWithString: "Your reading, remembered privately on this Mac.")
        intro.font = .systemFont(ofSize: 13)
        intro.textColor = .secondaryLabelColor
        content.addArrangedSubview(heading)
        content.addArrangedSubview(intro)
        content.setCustomSpacing(20, after: intro)

        let heroRow = makeHeroRow()
        content.addArrangedSubview(heroRow)
        heroRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let goalCard = makeGoalCard()
        content.addArrangedSubview(goalCard)
        goalCard.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let chartCard = makeChartCard()
        content.addArrangedSubview(chartCard)
        chartCard.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let rankingsRow = makeRankingsRow()
        content.addArrangedSubview(rankingsRow)
        rankingsRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let longestCard = makeLongestCard()
        content.addArrangedSubview(longestCard)
        longestCard.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        let summaryRow = makeSummaryRow()
        content.addArrangedSubview(summaryRow)
        summaryRow.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 26),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -26),
            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -28),
        ])
    }

    private func makeHeroRow() -> NSStackView {
        configureMetricLabel(lifetimeWordsLabel, size: 36, weight: .bold)
        let lifetime = metricCard(
            value: lifetimeWordsLabel,
            caption: "words read aloud",
            accessibilityLabel: "Lifetime words read aloud"
        )

        configureMetricLabel(hoursLabel, size: 28, weight: .semibold)
        let hours = metricCard(
            value: hoursLabel,
            caption: "hours listened",
            accessibilityLabel: "Hours listened"
        )

        configureMetricLabel(streakLabel, size: 29, weight: .bold, color: .controlAccentColor)
        bestStreakLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        bestStreakLabel.textColor = .secondaryLabelColor
        let streakStack = NSStackView(views: [streakLabel, label("current streak"), bestStreakLabel])
        streakStack.orientation = .vertical
        streakStack.alignment = .leading
        streakStack.spacing = 4
        let streak = card(containing: streakStack)
        streak.setAccessibilityLabel("Current and best reading streak")

        let row = NSStackView(views: [lifetime, hours, streak])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.distribution = .fillEqually
        lifetime.heightAnchor.constraint(equalToConstant: 126).isActive = true
        hours.heightAnchor.constraint(equalTo: lifetime.heightAnchor).isActive = true
        streak.heightAnchor.constraint(equalTo: lifetime.heightAnchor).isActive = true
        return row
    }

    private func makeGoalCard() -> DashboardCardView {
        let heading = sectionHeading("Weekly goal")
        goalRing.translatesAutoresizingMaskIntoConstraints = false
        goalRing.widthAnchor.constraint(equalToConstant: 86).isActive = true
        goalRing.heightAnchor.constraint(equalToConstant: 86).isActive = true

        goalProgressLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        goalProgressLabel.lineBreakMode = .byTruncatingTail

        let helper = label("Set a motivating target. Your goal stays on this Mac.")
        helper.lineBreakMode = .byTruncatingTail

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 10_000_000
        goalField.formatter = formatter
        goalField.alignment = .right
        goalField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        goalField.placeholderString = "Weekly words"
        goalField.target = self
        goalField.action = #selector(commitGoal(_:))
        goalField.widthAnchor.constraint(equalToConstant: 106).isActive = true

        goalStepper.minValue = 0
        goalStepper.maxValue = 10_000_000
        goalStepper.increment = 500
        goalStepper.valueWraps = false
        goalStepper.target = self
        goalStepper.action = #selector(stepGoal(_:))

        let editLabel = NSTextField(labelWithString: "Goal")
        editLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let editRow = NSStackView(views: [editLabel, goalField, goalStepper])
        editRow.orientation = .horizontal
        editRow.alignment = .centerY
        editRow.spacing = 7

        let details = NSStackView(views: [heading, goalProgressLabel, helper, editRow])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 6

        let row = NSStackView(views: [goalRing, details])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        return card(containing: row)
    }

    private func makeChartCard() -> DashboardCardView {
        let heading = sectionHeading("This week")
        weekChart.translatesAutoresizingMaskIntoConstraints = false
        weekChart.heightAnchor.constraint(equalToConstant: 174).isActive = true
        let stack = NSStackView(views: [heading, weekChart])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        weekChart.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return card(containing: stack)
    }

    private func makeRankingsRow() -> NSStackView {
        let sourceStack = NSStackView(views: [sectionHeading("Where you read"), sourcesList])
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 10
        sourcesList.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true

        let voiceStack = NSStackView(views: [sectionHeading("Voices you pick"), voicesList])
        voiceStack.orientation = .vertical
        voiceStack.alignment = .leading
        voiceStack.spacing = 10
        voicesList.widthAnchor.constraint(equalTo: voiceStack.widthAnchor).isActive = true

        let sourceCard = card(containing: sourceStack)
        let voiceCard = card(containing: voiceStack)
        let row = NSStackView(views: [sourceCard, voiceCard])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.distribution = .fillEqually
        sourceCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 226).isActive = true
        voiceCard.heightAnchor.constraint(equalTo: sourceCard.heightAnchor).isActive = true
        return row
    }

    private func makeLongestCard() -> DashboardCardView {
        longestTitleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        longestTitleLabel.maximumNumberOfLines = 2
        longestDetailLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        longestDetailLabel.textColor = .secondaryLabelColor
        longestDetailLabel.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [sectionHeading("Longest read"), longestTitleLabel, longestDetailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        return card(containing: stack)
    }

    private func makeSummaryRow() -> NSStackView {
        configureMetricLabel(totalReadsLabel, size: 23, weight: .semibold)
        configureMetricLabel(averageWordsLabel, size: 23, weight: .semibold)
        configureMetricLabel(castReadsLabel, size: 23, weight: .semibold)

        let reads = metricCard(value: totalReadsLabel, caption: "reads", accessibilityLabel: "Total reads")
        let average = metricCard(
            value: averageWordsLabel,
            caption: "avg words / read",
            accessibilityLabel: "Average words per read"
        )
        let cast = metricCard(value: castReadsLabel, caption: "cast reads", accessibilityLabel: "Cast reads")
        let row = NSStackView(views: [reads, average, cast])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.distribution = .fillEqually
        reads.heightAnchor.constraint(equalToConstant: 94).isActive = true
        average.heightAnchor.constraint(equalTo: reads.heightAnchor).isActive = true
        cast.heightAnchor.constraint(equalTo: reads.heightAnchor).isActive = true
        return row
    }

    private func metricCard(
        value: NSTextField,
        caption: String,
        accessibilityLabel: String
    ) -> DashboardCardView {
        let stack = NSStackView(views: [value, label(caption)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        let result = card(containing: stack)
        result.setAccessibilityElement(true)
        result.setAccessibilityLabel(accessibilityLabel)
        return result
    }

    private func card(containing content: NSView) -> DashboardCardView {
        let result = DashboardCardView()
        result.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        result.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: result.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: result.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: result.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: result.bottomAnchor, constant: -14),
        ])
        return result
    }

    private func configureMetricLabel(
        _ field: NSTextField,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor = .labelColor
    ) {
        field.font = .monospacedDigitSystemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func sectionHeading(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 15, weight: .semibold)
        return field
    }

    private func label(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    @objc private func stepGoal(_ sender: NSStepper) {
        goalField.integerValue = sender.integerValue
        applyGoal(sender.integerValue)
    }

    @objc private func commitGoal(_ sender: NSTextField) {
        applyGoal(max(0, sender.integerValue))
    }

    private func applyGoal(_ words: Int) {
        let updated = goalUpdater(max(0, words))
        render(updated)
    }

    private func formatted(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func dayCount(_ days: Int) -> String {
        "\(days) \(days == 1 ? "day" : "days")"
    }
}

@MainActor
private final class DashboardCardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

@MainActor
private final class WeeklyGoalRingView: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 8
        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 8
        track.lineCapStyle = .round
        NSColor.quaternaryLabelColor.setStroke()
        track.stroke()

        let progress = NSBezierPath()
        progress.appendArc(
            withCenter: center,
            radius: radius,
            startAngle: 90,
            endAngle: 90 - CGFloat(min(1, max(0, fraction))) * 360,
            clockwise: true
        )
        progress.lineWidth = 8
        progress.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        progress.stroke()

        let text = "\(Int((min(1, max(0, fraction)) * 100).rounded()))%" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
    }
}

@MainActor
private final class WeeklyBarChartView: NSView {
    var points: [ReadingStatsSnapshot.DayPoint] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !points.isEmpty else { return }

        let plot = bounds.insetBy(dx: 8, dy: 4)
        let baselineY = plot.minY + 25
        let chartTop = plot.maxY - 24
        let availableHeight = max(1, chartTop - baselineY)
        let maximum = max(1, points.map(\.words).max() ?? 1)
        let columnWidth = plot.width / CGFloat(points.count)
        let barWidth = min(28, columnWidth * 0.48)

        NSColor.separatorColor.setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: plot.minX, y: baselineY))
        baseline.line(to: NSPoint(x: plot.maxX, y: baselineY))
        baseline.lineWidth = 1
        baseline.stroke()

        for (index, point) in points.enumerated() {
            let centerX = plot.minX + columnWidth * (CGFloat(index) + 0.5)
            let height = max(3, CGFloat(point.words) / CGFloat(maximum) * availableHeight)
            let barRect = NSRect(
                x: centerX - barWidth / 2,
                y: baselineY,
                width: barWidth,
                height: height
            )
            (point.isToday ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()

            let value = NumberFormatter.localizedString(
                from: NSNumber(value: point.words),
                number: .decimal
            ) as NSString
            let valueAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: point.isToday ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            ]
            let valueSize = value.size(withAttributes: valueAttributes)
            value.draw(
                at: NSPoint(x: centerX - valueSize.width / 2, y: min(chartTop + 4, baselineY + height + 4)),
                withAttributes: valueAttributes
            )

            let weekday = point.weekdayInitial as NSString
            let dayAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: point.isToday ? .bold : .regular),
                .foregroundColor: point.isToday ? NSColor.controlAccentColor : NSColor.secondaryLabelColor,
            ]
            let weekdaySize = weekday.size(withAttributes: dayAttributes)
            weekday.draw(
                at: NSPoint(x: centerX - weekdaySize.width / 2, y: plot.minY + 5),
                withAttributes: dayAttributes
            )
        }
    }
}

@MainActor
private final class RankingListView: NSStackView {
    private let maximumRows: Int

    init(maximumRows: Int) {
        self.maximumRows = maximumRows
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 9
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(
        _ entries: [ReadingStatsSnapshot.Ranked],
        name transform: (String) -> String
    ) {
        for view in arrangedSubviews {
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard !entries.isEmpty else {
            let empty = NSTextField(labelWithString: "No reading data yet")
            empty.font = .systemFont(ofSize: 12)
            empty.textColor = .secondaryLabelColor
            addArrangedSubview(empty)
            return
        }

        for entry in entries.prefix(maximumRows) {
            let name = NSTextField(labelWithString: transform(entry.name))
            name.font = .systemFont(ofSize: 11, weight: .medium)
            name.lineBreakMode = .byTruncatingTail
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

            let percent = NSTextField(
                labelWithString: "\(Int((entry.fraction * 100).rounded()))%"
            )
            percent.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            percent.textColor = .secondaryLabelColor
            percent.alignment = .right
            percent.widthAnchor.constraint(equalToConstant: 36).isActive = true

            let titleRow = NSStackView(views: [name, percent])
            titleRow.orientation = .horizontal
            titleRow.alignment = .centerY
            titleRow.spacing = 6

            let bar = FractionBarView()
            bar.fraction = entry.fraction
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 5).isActive = true

            let words = NSTextField(
                labelWithString: "\(NumberFormatter.localizedString(from: NSNumber(value: entry.words), number: .decimal)) words"
            )
            words.font = .monospacedDigitSystemFont(ofSize: 9, weight: .regular)
            words.textColor = .tertiaryLabelColor

            let row = NSStackView(views: [titleRow, bar, words])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 3
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            titleRow.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
            bar.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
    }
}

@MainActor
private final class FractionBarView: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()

        let width = bounds.width * CGFloat(min(1, max(0, fraction)))
        guard width > 0 else { return }
        let fill = NSBezierPath(
            roundedRect: NSRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height),
            xRadius: bounds.height / 2,
            yRadius: bounds.height / 2
        )
        NSColor.controlAccentColor.setFill()
        fill.fill()
    }
}
