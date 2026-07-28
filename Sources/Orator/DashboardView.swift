import Cocoa
import CoreText

// MARK: - Design system

private enum DashboardTheme {
    static let windowBackground = dynamic(
        "WindowBG", light: 0xF6F4F0, dark: 0x1B1A18
    )
    static let cardBackground = dynamic(
        "CardBG", light: 0xFFFDFB, dark: 0x2A2824
    )
    static let heroCardBackground = dynamic(
        "CardBG_Hero", light: 0xFFFFFF, dark: 0x302D28
    )
    static let hairline = dynamic(
        "Hairline", light: 0xE7E3DC, dark: 0x3A3833
    )
    static let track = dynamic(
        "Track", light: 0xECE8E1, dark: 0x34322D
    )
    static let barNeutral = dynamic(
        "BarNeutral", light: 0xC9C2B6, dark: 0x4A4741
    )
    static let textPrimary = dynamic(
        "TextPrimary", light: 0x1F1D1A, dark: 0xF2EFE9
    )
    static let textSecondary = dynamic(
        "TextSecondary", light: 0x6B665E, dark: 0xA7A199
    )
    static let textTertiary = dynamic(
        "TextTertiary", light: 0x9A948B, dark: 0x736E66
    )
    static let ember = dynamic(
        "Ember", light: 0xBE6E2A, dark: 0xE7A45C
    )
    static let emberText = dynamic(
        "EmberText", light: 0xA85D22, dark: 0xEDB06A
    )
    static let emberSoft = dynamic(
        "EmberSoft",
        light: 0xBE6E2A,
        dark: 0xE7A45C,
        lightAlpha: 0.12,
        darkAlpha: 0.16
    )
    static let emberGlow = dynamic(
        "EmberGlow",
        light: 0xBE6E2A,
        dark: 0xE7A45C,
        lightAlpha: 0.22,
        darkAlpha: 0.34
    )

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static func dynamic(
        _ name: String,
        light: UInt32,
        dark: UInt32,
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> NSColor {
        NSColor(name: NSColor.Name("Orator.Dashboard.\(name)")) { appearance in
            if isDark(appearance) {
                return fixed(dark, alpha: darkAlpha)
            }
            return fixed(light, alpha: lightAlpha)
        }
    }

    private static func fixed(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            deviceRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

private enum DashboardFont {
    static func roundedTabular(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
        let tabular = rounded.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
            ]],
        ])
        return NSFont(descriptor: tabular, size: size) ?? base
    }
}

// MARK: - Dashboard host

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
    private let todayDeltaLabel = NSTextField(labelWithString: "")
    private let hoursLabel = NSTextField(labelWithString: "0.0")
    private let streakLabel = NSTextField(labelWithString: "0")
    private let streakCaptionLabel = NSTextField(labelWithString: "Start today")
    private let bestStreakLabel = NSTextField(labelWithString: "Best 0")
    private let streakIcon = DashboardSymbolView(
        name: "flame.fill",
        pointSize: 14,
        color: DashboardTheme.track
    )

    private let goalRing = WeeklyGoalRingView()
    private let goalProgressLabel = NSTextField(labelWithString: "0 / 0")
    private let goalField = NSTextField()
    private let goalStepper = NSStepper()
    private let weekChart = WeeklyBarChartView()

    private let sourcesList = RankingListView(kind: .sources, maximumRows: 5)
    private let voicesList = RankingListView(kind: .voices, maximumRows: 4)

    private let longestCrown = DashboardSymbolView(
        name: "crown.fill",
        pointSize: 13,
        color: DashboardTheme.textTertiary
    )
    private let longestTitleLabel = NSTextField(wrappingLabelWithString: "No reads yet")
    private let longestEmptyDetailLabel = NSTextField(
        labelWithString: "Your longest read will appear here."
    )
    private let longestChipsRow = NSStackView()
    private let longestWordsChip = DashboardMetadataChip(symbol: "textformat.size")
    private let longestMinutesChip = DashboardMetadataChip(symbol: "clock")
    private let longestVoiceChip = DashboardMetadataChip(symbol: "waveform")

    private let totalReadsLabel = NSTextField(labelWithString: "0")
    private let averageWordsLabel = NSTextField(labelWithString: "0")
    private let castReadsLabel = NSTextField(labelWithString: "0")

    private var lastWeekWords = 0
    private var lastWeeklyGoal = 0

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

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DashboardTheme.windowBackground.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        updateGoalProgressLabel(words: lastWeekWords, goal: lastWeeklyGoal)
    }

    func render(_ snapshot: ReadingStatsSnapshot) {
        lifetimeWordsLabel.stringValue = formatted(snapshot.lifetimeWords)
        todayDeltaLabel.stringValue = snapshot.wordsToday > 0
            ? "＋\(formatted(snapshot.wordsToday)) today"
            : ""
        todayDeltaLabel.isHidden = snapshot.wordsToday == 0

        hoursLabel.stringValue = String(format: "%.1f", snapshot.lifetimeSeconds / 3_600)
        streakLabel.stringValue = formatted(snapshot.currentStreakDays)
        bestStreakLabel.stringValue = "Best \(formatted(snapshot.bestStreakDays))"
        let hasStreak = snapshot.currentStreakDays > 0
        streakCaptionLabel.stringValue = hasStreak ? "day streak" : "Start today"
        streakIcon.color = hasStreak ? DashboardTheme.ember : DashboardTheme.track
        streakLabel.textColor = hasStreak ? DashboardTheme.emberText : DashboardTheme.textTertiary

        lastWeekWords = snapshot.wordsThisWeek
        lastWeeklyGoal = snapshot.weeklyGoalWords
        updateGoalProgressLabel(
            words: snapshot.wordsThisWeek,
            goal: snapshot.weeklyGoalWords
        )
        goalRing.fraction = snapshot.weeklyGoalFraction
        goalRing.setAccessibilityLabel(
            "Weekly goal \(Int((snapshot.weeklyGoalFraction * 100).rounded())) percent complete"
        )
        goalField.integerValue = snapshot.weeklyGoalWords
        goalStepper.integerValue = snapshot.weeklyGoalWords

        weekChart.points = snapshot.week
        sourcesList.render(snapshot.topSources, name: { $0 })
        voicesList.render(snapshot.topVoices, name: voiceDisplayName)

        if let longest = snapshot.longest {
            longestCrown.color = DashboardTheme.ember
            longestTitleLabel.stringValue = longest.title
            longestEmptyDetailLabel.isHidden = true
            longestChipsRow.isHidden = false
            longestWordsChip.text = "\(formatted(longest.words)) words"
            longestMinutesChip.text = "\(String(format: "%.1f", longest.seconds / 60)) min"
            longestVoiceChip.text = voiceDisplayName(longest.voice)
        } else {
            longestCrown.color = DashboardTheme.textTertiary
            longestTitleLabel.stringValue = "No reads yet"
            longestEmptyDetailLabel.isHidden = false
            longestChipsRow.isHidden = true
        }

        totalReadsLabel.stringValue = formatted(snapshot.totalReads)
        averageWordsLabel.stringValue = formatted(snapshot.averageWordsPerRead)
        castReadsLabel.stringValue = formatted(snapshot.castReads)
    }

    private func configureView() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let documentView = DashboardBackgroundView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        let content = NSStackView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        documentView.addSubview(content)

        let header = makeHeaderBand()
        addFullWidth(header, to: content)
        content.setCustomSpacing(10, after: header)

        let hero = makeHeroCard()
        addFullWidth(hero, to: content)
        content.setCustomSpacing(10, after: hero)

        let week = makeThisWeekCard()
        addFullWidth(week, to: content)
        content.setCustomSpacing(10, after: week)

        let rankings = makeRankingsRow()
        addFullWidth(rankings, to: content)
        content.setCustomSpacing(10, after: rankings)

        let longest = makeLongestCard()
        addFullWidth(longest, to: content)

        let footer = makeFooterStatStrip()
        addFullWidth(footer, to: content)

        addSubview(scrollView)

        let preferredLeading = content.leadingAnchor.constraint(
            greaterThanOrEqualTo: documentView.leadingAnchor,
            constant: 32
        )
        preferredLeading.priority = .defaultHigh
        let preferredTrailing = content.trailingAnchor.constraint(
            lessThanOrEqualTo: documentView.trailingAnchor,
            constant: -32
        )
        preferredTrailing.priority = .defaultHigh
        let preferredWidth = content.widthAnchor.constraint(
            equalTo: documentView.widthAnchor,
            constant: -64
        )
        preferredWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            documentView.heightAnchor.constraint(
                greaterThanOrEqualTo: scrollView.contentView.heightAnchor
            ),

            content.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 780),
            content.leadingAnchor.constraint(
                greaterThanOrEqualTo: documentView.leadingAnchor,
                constant: 24
            ),
            content.trailingAnchor.constraint(
                lessThanOrEqualTo: documentView.trailingAnchor,
                constant: -24
            ),
            preferredLeading,
            preferredTrailing,
            preferredWidth,
            content.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 10),
            // lessThanOrEqualTo, NOT equalTo: the document view is forced to be
            // at least the viewport tall, so pinning content to its bottom would
            // stretch the stack to fill and inflate the one card without a fixed
            // height (the week card) into a big empty gap. Let content keep its
            // natural height; any slack becomes harmless space below the footer.
            content.bottomAnchor.constraint(
                lessThanOrEqualTo: documentView.bottomAnchor,
                constant: -10
            ),
        ])
    }

    private func makeHeaderBand() -> NSView {
        let title = NSTextField(labelWithString: "Dashboard")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = DashboardTheme.textPrimary

        let subtitle = NSTextField(
            labelWithString: "Your reading, remembered privately on this Mac."
        )
        subtitle.font = .systemFont(ofSize: 13, weight: .regular)
        subtitle.textColor = DashboardTheme.textSecondary
        subtitle.lineBreakMode = .byTruncatingTail

        let titles = NSStackView(views: [title, subtitle])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 4

        let privacyPill = DashboardPillView(
            symbol: "lock.fill",
            text: "On this Mac",
            fill: DashboardTheme.track
        )
        privacyPill.setAccessibilityLabel("Reading history stays on this Mac")

        let spacer = flexibleSpacer()
        let row = NSStackView(views: [titles, spacer, privacyPill])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        return row
    }

    private func makeHeroCard() -> DashboardCardView {
        configureStatLabel(lifetimeWordsLabel, size: 40, weight: .bold)

        let caption = NSTextField(labelWithString: "words read aloud")
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = DashboardTheme.textSecondary
        caption.attributedStringValue = NSAttributedString(
            string: caption.stringValue,
            attributes: [
                .font: caption.font as Any,
                .foregroundColor: DashboardTheme.textSecondary,
                .kern: 0.2,
            ]
        )

        todayDeltaLabel.font = DashboardFont.roundedTabular(13, .semibold)
        todayDeltaLabel.textColor = DashboardTheme.emberText

        let lifetime = NSStackView(views: [
            lifetimeWordsLabel,
            caption,
            todayDeltaLabel,
        ])
        lifetime.orientation = .vertical
        lifetime.alignment = .leading
        lifetime.spacing = 4

        let divider = DashboardDividerView(.vertical)
        divider.heightAnchor.constraint(equalToConstant: 70).isActive = true

        configureStatLabel(hoursLabel, size: 24, weight: .semibold)
        let hoursUnit = makeLabel(
            "hrs",
            font: .systemFont(ofSize: 13, weight: .medium),
            color: DashboardTheme.textSecondary
        )
        let hoursNumbers = NSStackView(views: [hoursLabel, hoursUnit])
        hoursNumbers.orientation = .horizontal
        hoursNumbers.alignment = .firstBaseline
        hoursNumbers.spacing = 5
        let hoursTop = NSStackView(views: [
            DashboardSymbolView(
                name: "headphones",
                pointSize: 13,
                color: DashboardTheme.textSecondary
            ),
            hoursNumbers,
        ])
        hoursTop.orientation = .horizontal
        hoursTop.alignment = .centerY
        hoursTop.spacing = 8
        let hoursSatellite = NSStackView(views: [
            hoursTop,
            makeLabel(
                "hours listened",
                font: .systemFont(ofSize: 11, weight: .medium),
                color: DashboardTheme.textSecondary
            ),
        ])
        hoursSatellite.orientation = .vertical
        hoursSatellite.alignment = .leading
        hoursSatellite.spacing = 2
        hoursSatellite.setAccessibilityElement(true)
        hoursSatellite.setAccessibilityLabel("Hours listened")

        configureStatLabel(
            streakLabel,
            size: 24,
            weight: .semibold,
            color: DashboardTheme.textTertiary
        )
        let streakTop = NSStackView(views: [streakIcon, streakLabel])
        streakTop.orientation = .horizontal
        streakTop.alignment = .centerY
        streakTop.spacing = 8
        streakCaptionLabel.font = .systemFont(ofSize: 11, weight: .medium)
        streakCaptionLabel.textColor = DashboardTheme.textSecondary
        bestStreakLabel.font = .systemFont(ofSize: 11, weight: .medium)
        bestStreakLabel.textColor = DashboardTheme.textTertiary
        let streakDetails = NSStackView(views: [
            streakCaptionLabel,
            flexibleSpacer(),
            bestStreakLabel,
        ])
        streakDetails.orientation = .horizontal
        streakDetails.alignment = .firstBaseline
        streakDetails.spacing = 8
        let streakSatellite = NSStackView(views: [streakTop, streakDetails])
        streakSatellite.orientation = .vertical
        streakSatellite.alignment = .leading
        streakSatellite.spacing = 1
        streakDetails.widthAnchor.constraint(equalTo: streakSatellite.widthAnchor).isActive = true
        streakSatellite.setAccessibilityElement(true)
        streakSatellite.setAccessibilityLabel("Current and best reading streak")

        let satelliteDivider = DashboardDividerView(.horizontal)
        let satellites = NSStackView(views: [
            hoursSatellite,
            satelliteDivider,
            streakSatellite,
        ])
        satellites.orientation = .vertical
        satellites.alignment = .leading
        satellites.spacing = 1
        satelliteDivider.widthAnchor.constraint(equalTo: satellites.widthAnchor).isActive = true
        hoursSatellite.heightAnchor.constraint(equalTo: streakSatellite.heightAnchor).isActive = true

        let spacer = flexibleSpacer()
        let heroContent = NSStackView(views: [
            lifetime,
            spacer,
            divider,
            satellites,
        ])
        heroContent.orientation = .horizontal
        heroContent.alignment = .centerY
        heroContent.spacing = 20

        let result = DashboardCardView(
            isHero: true,
            horizontalPadding: 20,
            verticalPadding: 10
        )
        result.setContent(heroContent)
        result.heightAnchor.constraint(equalToConstant: 112).isActive = true
        let satelliteWidth = satellites.widthAnchor.constraint(
            equalTo: result.widthAnchor,
            multiplier: 0.42,
            constant: -20
        )
        satelliteWidth.priority = .defaultHigh
        satelliteWidth.isActive = true
        result.setAccessibilityElement(true)
        result.setAccessibilityLabel("Reading lifetime summary")
        return result
    }

    private func makeThisWeekCard() -> DashboardCardView {
        let heading = sectionHeading(symbol: "chart.bar.fill", title: "This week")
        let spacer = flexibleSpacer()

        goalProgressLabel.font = DashboardFont.roundedTabular(13, .semibold)
        goalProgressLabel.lineBreakMode = .byTruncatingTail
        goalProgressLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        goalRing.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            goalRing.widthAnchor.constraint(equalToConstant: 40),
            goalRing.heightAnchor.constraint(equalToConstant: 40),
        ])
        goalRing.setAccessibilityElement(true)

        let header = NSStackView(views: [heading, spacer, goalProgressLabel, goalRing])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        weekChart.translatesAutoresizingMaskIntoConstraints = false
        weekChart.heightAnchor.constraint(equalToConstant: 88).isActive = true

        configureGoalControls()
        let footerSpacer = flexibleSpacer()
        let footer = NSStackView(views: [
            DashboardSymbolView(
                name: "target",
                pointSize: 12,
                color: DashboardTheme.textTertiary
            ),
            makeLabel(
                "Weekly goal",
                font: .systemFont(ofSize: 11, weight: .medium),
                color: DashboardTheme.textSecondary
            ),
            footerSpacer,
            goalField,
            goalStepper,
        ])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let divider = DashboardDividerView(.horizontal)
        let stack = NSStackView(views: [header, weekChart, divider, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        weekChart.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let result = DashboardCardView(horizontalPadding: 16, verticalPadding: 8)
        result.setContent(stack)
        return result
    }

    private func configureGoalControls() {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 10_000_000
        goalField.formatter = formatter
        goalField.alignment = .right
        goalField.font = DashboardFont.roundedTabular(12, .medium)
        goalField.placeholderString = "Weekly words"
        goalField.target = self
        goalField.action = #selector(commitGoal(_:))
        goalField.widthAnchor.constraint(equalToConstant: 92).isActive = true

        goalStepper.minValue = 0
        goalStepper.maxValue = 10_000_000
        goalStepper.increment = 500
        goalStepper.valueWraps = false
        goalStepper.target = self
        goalStepper.action = #selector(stepGoal(_:))
    }

    private func makeRankingsRow() -> NSStackView {
        let sourceStack = NSStackView(views: [
            sectionHeading(symbol: "macwindow", title: "Where you read"),
            sourcesList,
        ])
        sourceStack.orientation = .vertical
        sourceStack.alignment = .leading
        sourceStack.spacing = 6
        sourcesList.widthAnchor.constraint(equalTo: sourceStack.widthAnchor).isActive = true

        let voiceStack = NSStackView(views: [
            sectionHeading(symbol: "waveform", title: "Voices you pick"),
            voicesList,
        ])
        voiceStack.orientation = .vertical
        voiceStack.alignment = .leading
        voiceStack.spacing = 6
        voicesList.widthAnchor.constraint(equalTo: voiceStack.widthAnchor).isActive = true

        let sourceCard = DashboardCardView(horizontalPadding: 16, verticalPadding: 8)
        sourceCard.setContent(sourceStack)
        let voiceCard = DashboardCardView(horizontalPadding: 16, verticalPadding: 8)
        voiceCard.setContent(voiceStack)

        let row = NSStackView(views: [sourceCard, voiceCard])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.distribution = .fillEqually
        return row
    }

    private func makeLongestCard() -> DashboardCardView {
        let header = NSStackView(views: [
            longestCrown,
            makeLabel(
                "Longest read",
                font: .systemFont(ofSize: 15, weight: .semibold),
                color: DashboardTheme.textPrimary
            ),
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        longestTitleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        longestTitleLabel.textColor = DashboardTheme.textPrimary
        longestTitleLabel.maximumNumberOfLines = 2
        longestTitleLabel.lineBreakMode = .byWordWrapping

        longestEmptyDetailLabel.font = .systemFont(ofSize: 13, weight: .regular)
        longestEmptyDetailLabel.textColor = DashboardTheme.textSecondary

        longestChipsRow.orientation = .horizontal
        longestChipsRow.alignment = .centerY
        longestChipsRow.spacing = 8
        longestChipsRow.addArrangedSubview(longestWordsChip)
        longestChipsRow.addArrangedSubview(longestMinutesChip)
        longestChipsRow.addArrangedSubview(longestVoiceChip)
        longestChipsRow.isHidden = true

        let stack = NSStackView(views: [
            header,
            longestTitleLabel,
            longestEmptyDetailLabel,
            longestChipsRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        let result = DashboardCardView(horizontalPadding: 16, verticalPadding: 8)
        result.setContent(stack)
        return result
    }

    private func makeFooterStatStrip() -> DashboardCardView {
        configureStatLabel(totalReadsLabel, size: 20, weight: .semibold)
        configureStatLabel(averageWordsLabel, size: 20, weight: .semibold)
        configureStatLabel(castReadsLabel, size: 20, weight: .semibold)

        let reads = footerCell(
            value: totalReadsLabel,
            symbol: "book.pages",
            symbolFallback: "book",
            caption: "reads",
            accessibilityLabel: "Total reads"
        )
        let average = footerCell(
            value: averageWordsLabel,
            symbol: "text.word.spacing",
            symbolFallback: "textformat",
            caption: "avg words / read",
            accessibilityLabel: "Average words per read"
        )
        let cast = footerCell(
            value: castReadsLabel,
            symbol: "airplayaudio",
            symbolFallback: "airplay.audio",
            caption: "cast reads",
            accessibilityLabel: "Cast reads"
        )

        let dividerOne = DashboardDividerView(.vertical)
        let dividerTwo = DashboardDividerView(.vertical)
        dividerOne.heightAnchor.constraint(equalToConstant: 34).isActive = true
        dividerTwo.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let row = NSStackView(views: [reads, dividerOne, average, dividerTwo, cast])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 0
        row.distribution = .fill

        // Equal-width constraints relate three DIFFERENT cells, so they need a
        // common ancestor - which only exists once the cells are in `row`.
        // Activating them earlier throws "no common ancestor" and silently
        // aborts the whole dashboard build (the window then never appears).
        reads.widthAnchor.constraint(equalTo: average.widthAnchor).isActive = true
        average.widthAnchor.constraint(equalTo: cast.widthAnchor).isActive = true

        let result = DashboardCardView(horizontalPadding: 0, verticalPadding: 0)
        result.setContent(row)
        result.heightAnchor.constraint(equalToConstant: 52).isActive = true
        return result
    }

    private func footerCell(
        value: NSTextField,
        symbol: String,
        symbolFallback: String,
        caption: String,
        accessibilityLabel: String
    ) -> NSView {
        let captionRow = NSStackView(views: [
            DashboardSymbolView(
                name: symbol,
                fallback: symbolFallback,
                pointSize: 11,
                color: DashboardTheme.textSecondary
            ),
            makeLabel(
                caption,
                font: .systemFont(ofSize: 11, weight: .medium),
                color: DashboardTheme.textSecondary
            ),
        ])
        captionRow.orientation = .horizontal
        captionRow.alignment = .centerY
        captionRow.spacing = 5

        let stack = NSStackView(views: [value, captionRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 3

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 1),
        ])
        container.setAccessibilityElement(true)
        container.setAccessibilityLabel(accessibilityLabel)
        return container
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func updateGoalProgressLabel(words: Int, goal: Int) {
        let value = NSMutableAttributedString(
            string: formatted(words),
            attributes: [
                .font: DashboardFont.roundedTabular(13, .semibold),
                .foregroundColor: DashboardTheme.textPrimary,
            ]
        )
        value.append(NSAttributedString(
            string: " / \(formatted(goal))",
            attributes: [
                .font: DashboardFont.roundedTabular(13, .semibold),
                .foregroundColor: DashboardTheme.textSecondary,
            ]
        ))
        goalProgressLabel.attributedStringValue = value
    }

    private func configureStatLabel(
        _ field: NSTextField,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor = DashboardTheme.textPrimary
    ) {
        field.font = DashboardFont.roundedTabular(size, weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func sectionHeading(symbol: String, title: String) -> NSStackView {
        let row = NSStackView(views: [
            DashboardSymbolView(
                name: symbol,
                pointSize: 13,
                color: DashboardTheme.textSecondary
            ),
            makeLabel(
                title,
                font: .systemFont(ofSize: 15, weight: .semibold),
                color: DashboardTheme.textPrimary
            ),
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func makeLabel(_ title: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = font
        field.textColor = color
        return field
    }

    private func flexibleSpacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
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
}

// MARK: - Surfaces and shared components

@MainActor
private final class DashboardBackgroundView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DashboardTheme.windowBackground.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class DashboardCardView: NSView {
    private let isHero: Bool
    private let horizontalPadding: CGFloat
    private let verticalPadding: CGFloat
    private let surface: DashboardCardSurfaceView

    override var wantsUpdateLayer: Bool { true }

    init(
        isHero: Bool = false,
        horizontalPadding: CGFloat = 18,
        verticalPadding: CGFloat = 16
    ) {
        self.isHero = isHero
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        surface = DashboardCardSurfaceView(isHero: isHero)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContent(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(
                equalTo: surface.leadingAnchor,
                constant: horizontalPadding
            ),
            content.trailingAnchor.constraint(
                equalTo: surface.trailingAnchor,
                constant: -horizontalPadding
            ),
            content.topAnchor.constraint(
                equalTo: surface.topAnchor,
                constant: verticalPadding
            ),
            content.bottomAnchor.constraint(
                equalTo: surface.bottomAnchor,
                constant: -verticalPadding
            ),
        ])
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let layer else { return }
            layer.backgroundColor = NSColor.clear.cgColor
            layer.masksToBounds = false
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = DashboardTheme.isDark(effectiveAppearance)
                ? (isHero ? 0.36 : 0.30)
                : (isHero ? 0.07 : 0.05)
            layer.shadowRadius = isHero ? 14 : 10
            layer.shadowOffset = CGSize(width: 0, height: isHero ? -2 : -1)
            layer.shadowPath = CGPath(
                roundedRect: bounds,
                cornerWidth: 14,
                cornerHeight: 14,
                transform: nil
            )
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        surface.needsDisplay = true
    }
}

@MainActor
private final class DashboardCardSurfaceView: NSView {
    private let isHero: Bool

    override var wantsUpdateLayer: Bool { true }

    init(isHero: Bool) {
        self.isHero = isHero
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let layer else { return }
            layer.cornerRadius = 14
            layer.backgroundColor = (
                isHero ? DashboardTheme.heroCardBackground : DashboardTheme.cardBackground
            ).cgColor
            layer.borderWidth = 1
            layer.borderColor = DashboardTheme.hairline.cgColor
            layer.masksToBounds = true
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class DashboardSymbolView: NSImageView {
    var color: NSColor {
        didSet { contentTintColor = color }
    }

    init(
        name: String,
        fallback: String? = nil,
        pointSize: CGFloat,
        weight: NSFont.Weight = .medium,
        color: NSColor
    ) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        image = NSImage(
            systemSymbolName: name,
            accessibilityDescription: nil
        ) ?? fallback.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)
        }
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        imageScaling = .scaleNone
        contentTintColor = color
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class DashboardDividerView: NSView {
    enum Orientation {
        case horizontal
        case vertical
    }

    private let orientation: Orientation
    override var wantsUpdateLayer: Bool { true }

    init(_ orientation: Orientation) {
        self.orientation = orientation
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        if orientation == .horizontal {
            heightAnchor.constraint(equalToConstant: 1).isActive = true
        } else {
            widthAnchor.constraint(equalToConstant: 1).isActive = true
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DashboardTheme.hairline.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class DashboardPillView: NSView {
    private let fill: NSColor
    override var wantsUpdateLayer: Bool { true }

    init(symbol: String, text: String, fill: NSColor) {
        self.fill = fill
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        let content = NSStackView(views: [
            DashboardSymbolView(
                name: symbol,
                pointSize: 10,
                color: DashboardTheme.textSecondary
            ),
            {
                let label = NSTextField(labelWithString: text)
                label.font = .systemFont(ofSize: 11, weight: .medium)
                label.textColor = DashboardTheme.textSecondary
                return label
            }(),
        ])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 5
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.cornerRadius = 8
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class DashboardMetadataChip: NSView {
    private let label = NSTextField(labelWithString: "")

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override var wantsUpdateLayer: Bool { true }

    init(symbol: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = DashboardTheme.textSecondary
        label.lineBreakMode = .byTruncatingTail

        let content = NSStackView(views: [
            DashboardSymbolView(
                name: symbol,
                pointSize: 10,
                color: DashboardTheme.textSecondary
            ),
            label,
        ])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 5
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DashboardTheme.emberSoft.cgColor
            layer?.cornerRadius = 8
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Weekly goal ring

@MainActor
private final class WeeklyGoalRingView: NSView {
    private var targetFraction: CGFloat = 0

    @objc dynamic private var displayedFraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    var fraction: Double {
        get { Double(targetFraction) }
        set {
            let target = CGFloat(min(1, max(0, newValue)))
            targetFraction = target
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window == nil {
                displayedFraction = target
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.35
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    animator().setValue(target, forKey: "displayedFraction")
                }
            }
            needsDisplay = true
        }
    }

    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        if key == "displayedFraction" {
            let animation = CABasicAnimation()
            animation.duration = 0.35
            animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
            return animation
        }
        return super.defaultAnimation(forKey: key)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let fraction = min(1, max(0, displayedFraction))
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 5

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = 6
        track.lineCapStyle = .round
        DashboardTheme.track.setStroke()
        track.stroke()

        if fraction > 0 {
            let progress = NSBezierPath()
            progress.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: 90,
                endAngle: 90 - fraction * 360,
                clockwise: true
            )
            progress.lineWidth = 6
            progress.lineCapStyle = .round

            if DashboardTheme.isDark(effectiveAppearance),
               !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = DashboardTheme.emberGlow
                glow.shadowBlurRadius = 6
                glow.shadowOffset = .zero
                glow.set()
                DashboardTheme.ember.setStroke()
                progress.stroke()
                NSGraphicsContext.restoreGraphicsState()
            }

            DashboardTheme.ember.setStroke()
            progress.stroke()
        }

        if fraction >= 0.999 {
            let checkmarkConfiguration = NSImage.SymbolConfiguration(
                pointSize: 11,
                weight: .semibold
            ).applying(
                NSImage.SymbolConfiguration(paletteColors: [DashboardTheme.ember])
            )
            if let checkmark = NSImage(
                systemSymbolName: "checkmark",
                accessibilityDescription: nil
            )?.withSymbolConfiguration(checkmarkConfiguration) {
                let size = checkmark.size
                checkmark.draw(
                    at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                    from: .zero,
                    operation: .sourceOver,
                    fraction: 1
                )
            }
        } else {
            let text = "\(Int((fraction * 100).rounded()))%" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: DashboardFont.roundedTabular(15, .semibold),
                .foregroundColor: DashboardTheme.textPrimary,
            ]
            let size = text.size(withAttributes: attributes)
            text.draw(
                at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Weekly chart

@MainActor
private final class WeeklyBarChartView: NSView {
    private var columnTrackingAreas: [NSTrackingArea] = []
    private var accessibilityColumns: [DashboardChartAccessibilityView] = []
    private var hoveredIndex: Int? {
        didSet {
            if oldValue != hoveredIndex {
                needsDisplay = true
            }
        }
    }

    var points: [ReadingStatsSnapshot.DayPoint] = [] {
        didSet {
            hoveredIndex = nil
            rebuildAccessibilityColumns()
            needsDisplay = true
            updateTrackingAreas()
        }
    }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        layoutAccessibilityColumns()
    }

    override func updateTrackingAreas() {
        for area in columnTrackingAreas {
            removeTrackingArea(area)
        }
        columnTrackingAreas.removeAll()

        guard !points.isEmpty else {
            super.updateTrackingAreas()
            return
        }

        let plot = bounds.insetBy(dx: 8, dy: 4)
        let columnWidth = plot.width / CGFloat(points.count)
        for index in points.indices {
            let rect = NSRect(
                x: plot.minX + columnWidth * CGFloat(index),
                y: plot.minY,
                width: columnWidth,
                height: plot.height
            )
            let area = NSTrackingArea(
                rect: rect,
                options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self,
                userInfo: ["index": index]
            )
            addTrackingArea(area)
            columnTrackingAreas.append(area)
        }
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        hoveredIndex = event.trackingArea?.userInfo?["index"] as? Int
    }

    override func mouseExited(with event: NSEvent) {
        guard let index = event.trackingArea?.userInfo?["index"] as? Int else {
            hoveredIndex = nil
            return
        }
        if hoveredIndex == index {
            hoveredIndex = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !points.isEmpty else { return }

        let plot = bounds.insetBy(dx: 8, dy: 4)
        let baselineY = plot.minY + 22
        let chartTop = plot.maxY - 20
        let availableHeight = max(1, chartTop - baselineY)
        let columnWidth = plot.width / CGFloat(points.count)
        let barWidth = min(22, columnWidth * 0.42)
        let allEmpty = points.allSatisfy { $0.words == 0 }
        let maximum = points.map(\.words).max() ?? 0
        let niceMaximum = niceCeiling(for: Double(maximum) / 0.82)

        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: plot.minX, y: baselineY))
        baseline.line(to: NSPoint(x: plot.maxX, y: baselineY))
        baseline.lineWidth = 1
        DashboardTheme.hairline.setStroke()
        baseline.stroke()

        var barRects: [NSRect] = []
        for (index, point) in points.enumerated() {
            let centerX = plot.minX + columnWidth * (CGFloat(index) + 0.5)
            let scaledHeight = niceMaximum > 0
                ? CGFloat(Double(point.words) / niceMaximum) * availableHeight
                : 0
            let height: CGFloat
            if allEmpty {
                height = 6
            } else if point.words == 0 {
                height = 2
            } else {
                height = max(2, scaledHeight)
            }

            let barRect = NSRect(
                x: centerX - barWidth / 2,
                y: baselineY,
                width: barWidth,
                height: height
            )
            barRects.append(barRect)

            let path = topRoundedBarPath(
                rect: barRect,
                radius: min(6, barWidth / 2)
            )
            let fill: NSColor
            if allEmpty || point.words == 0 {
                fill = DashboardTheme.track
            } else {
                fill = point.isToday ? DashboardTheme.ember : DashboardTheme.barNeutral
            }

            if point.isToday,
               point.words > 0,
               DashboardTheme.isDark(effectiveAppearance),
               !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = DashboardTheme.emberGlow
                glow.shadowBlurRadius = 8
                glow.shadowOffset = .zero
                glow.set()
                fill.setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
            }

            fill.setFill()
            path.fill()

            if point.isToday, !allEmpty {
                let markerRect = NSRect(
                    x: centerX - 1.5,
                    y: barRect.maxY + 4.5,
                    width: 3,
                    height: 3
                )
                DashboardTheme.ember.setFill()
                NSBezierPath(ovalIn: markerRect).fill()

                let value = formatted(point.words) as NSString
                let valueAttributes: [NSAttributedString.Key: Any] = [
                    .font: DashboardFont.roundedTabular(10, .semibold),
                    .foregroundColor: DashboardTheme.ember,
                ]
                let valueSize = value.size(withAttributes: valueAttributes)
                value.draw(
                    at: NSPoint(
                        x: centerX - valueSize.width / 2,
                        y: min(chartTop + 4, barRect.maxY + 11)
                    ),
                    withAttributes: valueAttributes
                )
            }

            drawWeekday(point, centerX: centerX, plot: plot)
        }

        if allEmpty {
            let message = "No reading yet this week" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: DashboardTheme.textSecondary,
            ]
            let size = message.size(withAttributes: attributes)
            message.draw(
                at: NSPoint(
                    x: plot.midX - size.width / 2,
                    y: baselineY + availableHeight / 2 - size.height / 2
                ),
                withAttributes: attributes
            )
        }

        if let hoveredIndex,
           points.indices.contains(hoveredIndex),
           barRects.indices.contains(hoveredIndex) {
            drawTooltip(
                for: points[hoveredIndex],
                barRect: barRects[hoveredIndex],
                plot: plot
            )
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func drawWeekday(
        _ point: ReadingStatsSnapshot.DayPoint,
        centerX: CGFloat,
        plot: NSRect
    ) {
        let weekday = point.weekdayInitial as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(
                ofSize: 10,
                weight: point.isToday ? .semibold : .regular
            ),
            .foregroundColor: point.isToday
                ? DashboardTheme.ember
                : DashboardTheme.textTertiary,
        ]
        let size = weekday.size(withAttributes: attributes)
        weekday.draw(
            at: NSPoint(x: centerX - size.width / 2, y: plot.minY + 4),
            withAttributes: attributes
        )
        if point.isToday {
            DashboardTheme.ember.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: centerX - 1.5,
                y: plot.minY + 1,
                width: 3,
                height: 3
            )).fill()
        }
    }

    private func drawTooltip(
        for point: ReadingStatsSnapshot.DayPoint,
        barRect: NSRect,
        plot: NSRect
    ) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE, MMM d"
        let date = dateFormatter.string(from: point.date) as NSString
        let words = "\(formatted(point.words)) words" as NSString

        let dateAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: DashboardTheme.textSecondary,
        ]
        let wordsAttributes: [NSAttributedString.Key: Any] = [
            .font: DashboardFont.roundedTabular(13, .semibold),
            .foregroundColor: DashboardTheme.textPrimary,
        ]
        let dateSize = date.size(withAttributes: dateAttributes)
        let wordsSize = words.size(withAttributes: wordsAttributes)
        let bubbleSize = NSSize(
            width: max(dateSize.width, wordsSize.width) + 16,
            height: dateSize.height + wordsSize.height + 12
        )
        var originX = barRect.midX - bubbleSize.width / 2
        originX = min(max(originX, plot.minX), plot.maxX - bubbleSize.width)
        var originY = barRect.maxY + 10
        if originY + bubbleSize.height > plot.maxY {
            originY = max(plot.minY + 22, barRect.maxY - bubbleSize.height - 8)
        }
        let bubbleRect = NSRect(origin: NSPoint(x: originX, y: originY), size: bubbleSize)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(
            DashboardTheme.isDark(effectiveAppearance) ? 0.30 : 0.05
        )
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        DashboardTheme.cardBackground.setFill()
        NSBezierPath(roundedRect: bubbleRect, xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.restoreGraphicsState()

        DashboardTheme.hairline.setStroke()
        let border = NSBezierPath(
            roundedRect: bubbleRect.insetBy(dx: 0.5, dy: 0.5),
            xRadius: 8,
            yRadius: 8
        )
        border.lineWidth = 1
        border.stroke()

        date.draw(
            at: NSPoint(x: bubbleRect.minX + 8, y: bubbleRect.maxY - 6 - dateSize.height),
            withAttributes: dateAttributes
        )
        words.draw(
            at: NSPoint(x: bubbleRect.minX + 8, y: bubbleRect.minY + 6),
            withAttributes: wordsAttributes
        )
    }

    private func topRoundedBarPath(rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let radius = min(radius, rect.height, rect.width / 2)
        let kappa: CGFloat = 0.552_284_75
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
        path.curve(
            to: NSPoint(x: rect.minX + radius, y: rect.maxY),
            controlPoint1: NSPoint(
                x: rect.minX,
                y: rect.maxY - radius + radius * kappa
            ),
            controlPoint2: NSPoint(
                x: rect.minX + radius - radius * kappa,
                y: rect.maxY
            )
        )
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
        path.curve(
            to: NSPoint(x: rect.maxX, y: rect.maxY - radius),
            controlPoint1: NSPoint(
                x: rect.maxX - radius + radius * kappa,
                y: rect.maxY
            ),
            controlPoint2: NSPoint(
                x: rect.maxX,
                y: rect.maxY - radius + radius * kappa
            )
        )
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.close()
        return path
    }

    private func niceCeiling(for value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        let normalized = value / magnitude
        let multiplier: Double
        if normalized <= 1 {
            multiplier = 1
        } else if normalized <= 2 {
            multiplier = 2
        } else if normalized <= 5 {
            multiplier = 5
        } else {
            multiplier = 10
        }
        return multiplier * magnitude
    }

    private func formatted(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }

    private func rebuildAccessibilityColumns() {
        for column in accessibilityColumns {
            column.removeFromSuperview()
        }
        accessibilityColumns = points.map { point in
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            let day = formatter.string(from: point.date)
            let label = "\(day), \(formatted(point.words)) words"
            let view = DashboardChartAccessibilityView(label: label)
            addSubview(view)
            return view
        }
        layoutAccessibilityColumns()
    }

    private func layoutAccessibilityColumns() {
        guard !accessibilityColumns.isEmpty else { return }
        let plot = bounds.insetBy(dx: 8, dy: 4)
        let columnWidth = plot.width / CGFloat(accessibilityColumns.count)
        for (index, column) in accessibilityColumns.enumerated() {
            column.frame = NSRect(
                x: plot.minX + CGFloat(index) * columnWidth,
                y: plot.minY,
                width: columnWidth,
                height: plot.height
            )
        }
    }
}

@MainActor
private final class DashboardChartAccessibilityView: NSView {
    init(label: String) {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// MARK: - Rankings

@MainActor
private final class RankingListView: NSStackView {
    enum Kind {
        case sources
        case voices
    }

    private let kind: Kind
    private let maximumRows: Int

    init(kind: Kind, maximumRows: Int) {
        self.kind = kind
        self.maximumRows = maximumRows
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 4
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
            empty.font = .systemFont(ofSize: 13, weight: .regular)
            empty.textColor = DashboardTheme.textSecondary
            empty.alignment = .center
            addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            return
        }

        for (index, entry) in entries.prefix(maximumRows).enumerated() {
            let row = RankingRowView(
                symbol: identitySymbol(for: entry.name),
                name: transform(entry.name),
                words: entry.words,
                fraction: entry.fraction,
                isLeader: index == 0
            )
            addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
    }

    private func identitySymbol(for name: String) -> String {
        guard kind == .sources else { return "waveform" }
        let value = name.lowercased()
        if value.contains("safari") { return "safari" }
        if value.contains("chrome") { return "globe" }
        if value.contains("mail") { return "envelope.fill" }
        if value.contains("books") { return "book.closed.fill" }
        if value.contains("news") { return "newspaper.fill" }
        if value.contains("notes") { return "note.text" }
        if value.contains("messages") { return "message.fill" }
        if value.contains("slack") { return "number" }
        if value.contains("preview") || value.contains("pdf") { return "doc.fill" }
        if value.contains("kindle") { return "book.fill" }
        return "app.dashed"
    }
}

@MainActor
private final class RankingRowView: NSView {
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false {
        didSet {
            if oldValue != isHovered {
                needsDisplay = true
            }
        }
    }

    init(
        symbol: String,
        name: String,
        words: Int,
        fraction: Double,
        isLeader: Bool
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 12, weight: isLeader ? .semibold : .medium)
        nameLabel.textColor = DashboardTheme.textPrimary
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let rawCount = NSTextField(
            labelWithString: "· \(formatted(words)) words"
        )
        rawCount.font = .systemFont(ofSize: 10, weight: .regular)
        rawCount.textColor = DashboardTheme.textTertiary
        rawCount.lineBreakMode = .byTruncatingTail
        rawCount.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let percent = NSTextField(
            labelWithString: "\(Int((fraction * 100).rounded()))%"
        )
        percent.font = DashboardFont.roundedTabular(12, .semibold)
        percent.textColor = DashboardTheme.textPrimary
        percent.alignment = .right
        percent.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true

        let top = NSStackView(views: [
            DashboardSymbolView(
                name: symbol,
                fallback: "app.dashed",
                pointSize: 14,
                color: DashboardTheme.textSecondary
            ),
            nameLabel,
            rawCount,
            flexibleSpacer(),
            percent,
        ])
        top.orientation = .horizontal
        top.alignment = .centerY
        top.spacing = 6

        let bar = FractionBarView()
        bar.fraction = fraction
        bar.fillAlpha = isLeader ? 1 : 0.75
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 4).isActive = true

        let content = NSStackView(views: [top, bar])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 2
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            top.widthAnchor.constraint(equalTo: content.widthAnchor),
            bar.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel(
            "\(name), \(formatted(words)) words, \(Int((fraction * 100).rounded())) percent"
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isHovered
                ? DashboardTheme.emberSoft.cgColor
                : NSColor.clear.cgColor
            layer?.cornerRadius = 8
        }
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func flexibleSpacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    private func formatted(_ value: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

@MainActor
private final class FractionBarView: NSView {
    var fraction: Double = 0 {
        didSet { needsDisplay = true }
    }
    var fillAlpha: CGFloat = 1 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let track = NSBezierPath(
            roundedRect: bounds,
            xRadius: 2,
            yRadius: 2
        )
        DashboardTheme.track.setFill()
        track.fill()

        let width = bounds.width * CGFloat(min(1, max(0, fraction)))
        guard width > 0 else { return }
        let fill = NSBezierPath(
            roundedRect: NSRect(
                x: bounds.minX,
                y: bounds.minY,
                width: width,
                height: bounds.height
            ),
            xRadius: 2,
            yRadius: 2
        )
        DashboardTheme.ember.withAlphaComponent(fillAlpha).setFill()
        fill.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
