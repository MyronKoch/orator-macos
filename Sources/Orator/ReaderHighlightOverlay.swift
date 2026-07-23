import AppKit
import QuartzCore

/// A viewport-sized compositor above the text view. It is deliberately not a
/// text-system participant: selection, links, and document attributes remain
/// owned entirely by NSTextView.
@MainActor
final class ReaderHighlightOverlayView: NSView {

    private struct FragmentGeometry {
        let glyphRange: NSRange
        let containerRect: NSRect
        let lineHeight: CGFloat
    }

    private final class FragmentLayers {
        let geometry: FragmentGeometry
        let washLayer = CALayer()
        let progressClipLayer = CALayer()
        let highlightColorLayer = CALayer()
        let sweepMaskLayer = CAGradientLayer()
        var logicalWidth: CGFloat { geometry.containerRect.width }

        init(geometry: FragmentGeometry) {
            self.geometry = geometry
        }
    }

    private final class WordLayers {
        let characterRange: NSRange
        let rootLayer = CALayer()
        let fragments: [FragmentLayers]
        let totalWidth: CGFloat
        let isShortWord: Bool
        let duration: TimeInterval
        var progress: Double
        var releaseID = UUID()

        init(
            characterRange: NSRange,
            fragments: [FragmentLayers],
            duration: TimeInterval,
            progress: Double
        ) {
            self.characterRange = characterRange
            self.fragments = fragments
            totalWidth = fragments.reduce(0) { $0 + $1.logicalWidth }
            isShortWord = duration > 0 && duration < 0.110
            self.duration = duration
            self.progress = progress
        }
    }

    private weak var textView: NSTextView?
    private weak var clipView: NSClipView?
    private var currentWord: WordLayers?
    private var releasingWord: WordLayers?
    // nonisolated(unsafe): mutated only on the main actor, and read in the
    // nonisolated deinit of a @MainActor view (which also runs on main).
    nonisolated(unsafe) private var observerTokens: [NSObjectProtocol] = []
    private var backingScale: CGFloat = 2

    override var isFlipped: Bool { true }

    init(textView: NSTextView, clipView: NSClipView) {
        self.textView = textView
        self.clipView = clipView
        super.init(frame: clipView.bounds)

        wantsLayer = true
        layer?.masksToBounds = true
        autoresizingMask = [.width, .height]
        backingScale = textView.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2

        clipView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clipBoundsDidChange()
            }
        })
        observerTokens.append(center.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Not filtered by window: Notification/NSWindow are non-Sendable and
            // cannot cross into the isolated block. screenDidChange() re-reads our
            // own window's backingScaleFactor and no-ops when it is unchanged, so
            // reacting to any window's screen change is correct and cheap.
            MainActor.assumeIsolated {
                self?.screenDidChange()
            }
        })
        observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rebuildLiveWords()
            }
        })
        DispatchQueue.main.async { [weak self] in
            self?.clipBoundsDidChange()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuildLiveWords()
    }

    func showWord(characterRange: NSRange, duration: TimeInterval) {
        guard currentWord?.characterRange != characterRange else { return }
        releaseCurrentWord()
        currentWord = makeWord(
            characterRange: characterRange,
            duration: duration,
            progress: 0
        )
        guard let currentWord else { return }
        layer?.addSublayer(currentWord.rootLayer)
        position(currentWord)
        configureSecondaryProperties(for: currentWord, animated: true)
        updateProgressLayers(in: currentWord)
    }

    func updateWord(characterRange: NSRange, progress: Double) {
        guard let currentWord, currentWord.characterRange == characterRange else { return }
        currentWord.progress = min(max(progress, 0), 1)
        updateProgressLayers(in: currentWord)
    }

    func clear(animated: Bool) {
        guard currentWord != nil || releasingWord != nil else { return }
        if animated {
            releaseCurrentWord()
        } else {
            currentWord?.rootLayer.removeFromSuperlayer()
            currentWord = nil
            removeReleasingWord()
        }
    }

    /// Re-reads TextKit geometry and re-rasterizes the active mask. Used after
    /// font, container-width, live-resize, scale, or appearance changes.
    func layoutDidChange() {
        removeReleasingWord()
        rebuildLiveWords()
    }

    private func rebuildLiveWords() {
        guard let oldWord = currentWord else { return }
        let range = oldWord.characterRange
        let progress = oldWord.progress
        oldWord.rootLayer.removeFromSuperlayer()
        currentWord = makeWord(
            characterRange: range,
            duration: oldWord.duration,
            progress: progress
        )
        guard let currentWord else { return }
        layer?.addSublayer(currentWord.rootLayer)
        position(currentWord)
        configureSecondaryProperties(for: currentWord, animated: false)
        updateProgressLayers(in: currentWord)
    }

    private func makeWord(
        characterRange: NSRange,
        duration: TimeInterval,
        progress: Double
    ) -> WordLayers? {
        guard let textView,
              let layoutManager = textView.layoutManager,
              textView.textContainer != nil,
              characterRange.location != NSNotFound,
              NSMaxRange(characterRange) <= textView.string.utf16.count
        else { return nil }

        layoutManager.ensureLayout(forCharacterRange: characterRange)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        var geometries: [FragmentGeometry] = []
        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            lineRect, _, container, lineGlyphRange, _ in
            let intersection = NSIntersectionRange(glyphRange, lineGlyphRange)
            guard intersection.length > 0 else { return }
            let rect = layoutManager.boundingRect(
                forGlyphRange: intersection,
                in: container
            )
            guard rect.width > 0, rect.height > 0 else { return }
            geometries.append(FragmentGeometry(
                glyphRange: intersection,
                containerRect: rect,
                lineHeight: max(lineRect.height, rect.height)
            ))
        }
        guard !geometries.isEmpty else { return nil }

        let accent = readingAccentColor()
        let fragments = geometries.compactMap {
            makeFragment(
                geometry: $0,
                layoutManager: layoutManager,
                accent: accent
            )
        }
        guard !fragments.isEmpty else { return nil }
        return WordLayers(
            characterRange: characterRange,
            fragments: fragments,
            duration: duration,
            progress: progress
        )
    }

    private func makeFragment(
        geometry: FragmentGeometry,
        layoutManager: NSLayoutManager,
        accent: NSColor
    ) -> FragmentLayers? {
        guard let glyphImage = rasterizedGlyphImage(
            geometry: geometry,
            layoutManager: layoutManager,
            accent: accent
        ) else { return nil }

        let fragment = FragmentLayers(geometry: geometry)
        let washAlpha: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? 0.15
            : 0.08
        fragment.washLayer.backgroundColor = accent.withAlphaComponent(washAlpha).cgColor
        fragment.washLayer.cornerRadius = min(4, geometry.containerRect.height * 0.18)

        fragment.highlightColorLayer.contents = glyphImage
        fragment.highlightColorLayer.contentsGravity = .resize
        fragment.progressClipLayer.addSublayer(fragment.highlightColorLayer)
        fragment.progressClipLayer.mask = fragment.sweepMaskLayer

        fragment.sweepMaskLayer.startPoint = CGPoint(x: 0, y: 0.5)
        fragment.sweepMaskLayer.endPoint = CGPoint(x: 1, y: 0.5)
        fragment.sweepMaskLayer.colors = [
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.clear.cgColor,
            NSColor.clear.cgColor,
        ]

        for liveLayer in [
            fragment.washLayer,
            fragment.progressClipLayer,
            fragment.highlightColorLayer,
            fragment.sweepMaskLayer,
        ] {
            liveLayer.contentsScale = backingScale
        }
        return fragment
    }

    private func rasterizedGlyphImage(
        geometry: FragmentGeometry,
        layoutManager: NSLayoutManager,
        accent: NSColor
    ) -> CGImage? {
        let pointSize = geometry.containerRect.size
        let pixelWidth = max(1, Int(ceil(pointSize.width * backingScale)))
        let pixelHeight = max(1, Int(ceil(pointSize.height * backingScale)))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }

        context.scaleBy(x: backingScale, y: backingScale)
        // A CGContext bitmap is bottom-up, but TextKit lays glyphs out top-down.
        // NSGraphicsContext(flipped:) only DECLARES the orientation - it applies
        // no transform - so the flip has to be applied here. Without it the
        // container's y-axis is inverted and this per-word bitmap captures glyphs
        // from the wrong lines, compositing them into garbage.
        context.translateBy(x: 0, y: pointSize.height)
        context.scaleBy(x: 1, y: -1)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        layoutManager.drawGlyphs(
            forGlyphRange: geometry.glyphRange,
            at: NSPoint(
                x: -geometry.containerRect.minX,
                y: -geometry.containerRect.minY
            )
        )
        context.setBlendMode(.sourceIn)
        context.setFillColor(accent.cgColor)
        context.fill(CGRect(origin: .zero, size: pointSize))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private func position(_ word: WordLayers) {
        guard let textView else { return }
        let textOrigin = textView.textContainerOrigin
        let overlayRects = word.fragments.map { fragment -> NSRect in
            var textRect = fragment.geometry.containerRect
            textRect.origin.x += textOrigin.x
            textRect.origin.y += textOrigin.y
            return textView.convert(textRect, to: self)
        }
        guard var unionRect = overlayRects.first else { return }
        for rect in overlayRects.dropFirst() {
            unionRect = unionRect.union(rect)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        word.rootLayer.frame = unionRect
        for (fragment, overlayRect) in zip(word.fragments, overlayRects) {
            let localRect = overlayRect.offsetBy(
                dx: -unionRect.minX,
                dy: -unionRect.minY
            )
            fragment.washLayer.frame = localRect.insetBy(dx: -2.5, dy: -1)
            fragment.progressClipLayer.frame = localRect
            fragment.highlightColorLayer.frame = fragment.progressClipLayer.bounds
            fragment.sweepMaskLayer.frame = fragment.progressClipLayer.bounds
            if fragment.washLayer.superlayer == nil {
                word.rootLayer.addSublayer(fragment.washLayer)
                word.rootLayer.addSublayer(fragment.progressClipLayer)
            }
        }
        CATransaction.commit()
    }

    private func updateProgressLayers(in word: WordLayers) {
        let traveled = CGFloat(word.progress) * word.totalWidth
        var widthBefore: CGFloat = 0

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for fragment in word.fragments {
            let width = max(fragment.logicalWidth, 0.001)
            let localProgress = min(max((traveled - widthBefore) / width, 0), 1)
            widthBefore += width

            if word.isShortWord {
                fragment.sweepMaskLayer.colors = [
                    NSColor.black.cgColor,
                    NSColor.black.cgColor,
                    NSColor.black.cgColor,
                    NSColor.black.cgColor,
                ]
                fragment.sweepMaskLayer.locations = [0, 0, 1, 1]
                fragment.progressClipLayer.opacity = 1
            } else {
                let feather = min(fragment.geometry.lineHeight * 0.18, 5)
                // Center travels from -feather to width + feather so p=0 is
                // fully clear and p=1 fully opaque, while time remains linear.
                let edge = localProgress * (width + 2 * feather) - feather
                let opaqueStop = min(max((edge - feather) / width, 0), 1)
                let clearStop = min(max((edge + feather) / width, 0), 1)
                fragment.sweepMaskLayer.locations = [
                    0,
                    NSNumber(value: Double(opaqueStop)),
                    NSNumber(value: Double(clearStop)),
                    1,
                ]
            }
        }
        CATransaction.commit()
    }

    private func configureSecondaryProperties(for word: WordLayers, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        word.rootLayer.opacity = 1
        for fragment in word.fragments {
            fragment.washLayer.opacity = 1
        }
        CATransaction.commit()

        guard animated else { return }
        let attackDuration = min(0.050, max(word.duration, 0.001))
        let washAttack = CABasicAnimation(keyPath: "opacity")
        washAttack.fromValue = 0
        washAttack.toValue = 1
        washAttack.duration = attackDuration
        for fragment in word.fragments {
            fragment.washLayer.add(washAttack, forKey: "readerWashAttack")
        }
        // A sweep shorter than ~110ms reads as a flicker rather than motion, so
        // very short words crossfade the whole glyph instead of wiping through it.
        if word.isShortWord {
            let crossfade = CABasicAnimation(keyPath: "opacity")
            crossfade.fromValue = 0
            crossfade.toValue = 1
            crossfade.duration = attackDuration
            for fragment in word.fragments {
                fragment.progressClipLayer.add(crossfade, forKey: "readerShortWordCrossfade")
            }
        }
    }

    private func releaseCurrentWord() {
        removeReleasingWord()
        guard let word = currentWord else { return }
        currentWord = nil
        releasingWord = word
        let releaseID = UUID()
        word.releaseID = releaseID

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        word.rootLayer.opacity = 0
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = word.rootLayer.presentation()?.opacity ?? 1
        fade.toValue = 0
        fade.duration = 0.140
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        word.rootLayer.add(fade, forKey: "readerWordRelease")

        let transformRelease = CABasicAnimation(keyPath: "transform")
        transformRelease.fromValue =
            word.rootLayer.presentation()?.transform ?? word.rootLayer.transform
        transformRelease.toValue = CATransform3DIdentity
        transformRelease.duration = 0.140
        transformRelease.timingFunction = CAMediaTimingFunction(name: .easeOut)
        word.rootLayer.add(transformRelease, forKey: "readerTransformRelease")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.145) { [weak self, weak word] in
            guard let self, let word,
                  self.releasingWord === word,
                  word.releaseID == releaseID
            else { return }
            self.removeReleasingWord()
        }
    }

    private func removeReleasingWord() {
        releasingWord?.rootLayer.removeFromSuperlayer()
        releasingWord = nil
    }

    private func clipBoundsDidChange() {
        guard let clipView else { return }
        frame = clipView.bounds
        if let currentWord { position(currentWord) }
        if let releasingWord { position(releasingWord) }
    }

    private func screenDidChange() {
        let newScale = textView?.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        guard newScale != backingScale else { return }
        backingScale = newScale
        rebuildLiveWords()
    }

    private func fontSize(for range: NSRange) -> CGFloat {
        guard let storage = textView?.textStorage,
              storage.length > 0,
              range.location < storage.length,
              let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        else { return 16 }
        return font.pointSize
    }

    private func readingAccentColor() -> NSColor {
        let appearance = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let darkMode = appearance == .darkAqua
        let background = NSColor.textBackgroundColor.usingColorSpace(.sRGB)
            ?? (darkMode ? .black : .white)
        var accent = NSColor.controlAccentColor.usingColorSpace(.sRGB)
            ?? (darkMode ? .systemBlue : .systemBlue)
        let targetContrast: CGFloat =
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 7 : 4.5
        let correction = darkMode ? NSColor.white : NSColor.black

        for step in 1...12 where contrastRatio(accent, background) < targetContrast {
            let fraction = min(CGFloat(step) * 0.07, 0.84)
            accent = (NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? accent)
                .blended(withFraction: fraction, of: correction)?
                .usingColorSpace(.sRGB) ?? accent
        }
        return accent
    }

    private func contrastRatio(_ first: NSColor, _ second: NSColor) -> CGFloat {
        let light = max(relativeLuminance(first), relativeLuminance(second))
        let dark = min(relativeLuminance(first), relativeLuminance(second))
        return (light + 0.05) / (dark + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent)
            + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent)
    }
}
