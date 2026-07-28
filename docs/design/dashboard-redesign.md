# Orator Dashboard — Visual Redesign Spec

**Status:** Build-ready direction for implementation.
**Target file:** `Sources/Orator/DashboardView.swift` (AppKit, `NSView` + `NSStackView` + Auto Layout, custom `draw(_:)` chart/ring/bars).
**Data source (no changes required):** `Sources/Orator/ReadingStats.swift` → `ReadingStatsSnapshot`.
**Audience:** a Codex implementation agent. Every value below is concrete. Do not guess; if a value is missing, ask.

This document is self-contained. It supersedes any earlier summary.

---

## 0. Aesthetic north star & non-negotiables

**North star for polish level:** `jamiepine/voicebox` (a Tauri voice-AI app) — deep, premium, confident dark surfaces, a single glowing accent used sparingly, generous negative space, and crisp typographic hierarchy. Match that *level of finish*, not its exact palette or its web stack. Everything here must be implementable in native AppKit.

**What we keep from voicebox:** depth (surfaces that clearly sit at different elevations), restraint (one accent, used only for data-ink and one live delta), a premium dark mode with a subtle accent glow, and disciplined spacing.

**What we do NOT copy:** its exact colors, CSS blur stacks, or web components. Orator is a native Mac app and must read like Things / Reeder / Apple Fitness, not a ported web dashboard.

**Product framing:** Orator remembers your reading *privately, on this Mac*. The mood is a warm, quiet "reading room" — ink-dark text on warm paper (light) or warm near-black (dark), lit by a single **Ember** amber accent. Calm, literary, a little warm.

**Hard requirements:**
- Theme-aware: every color has an explicit light AND dark value; custom-drawn views must re-render on appearance change.
- Native HIG: SF Pro / SF Pro Rounded, SF Symbols, standard focus rings on controls, respects Reduce Motion.
- No new data model fields required. Two currently-unused fields are now used: `wordsToday` and `DayPoint.date`.

---

## 1. Design tokens (single source of truth)

Implement these once as a small `DashboardTheme` (or asset-catalog color set) and reference everywhere. Do not inline raw hex in views.

### 1.1 Color palette — "Reading Room"

All colors are **dynamic** (resolve per appearance). Hex is `#RRGGBB`; alpha given separately where used.

| Token | Light | Dark | Purpose |
|---|---|---|---|
| `WindowBG` | `#F6F4F0` | `#1B1A18` | Recessed page behind cards (the scroll content background) |
| `CardBG` | `#FFFDFB` | `#2A2824` | Raised card surface (elevation 1) |
| `CardBG_Hero` | `#FFFFFF` | `#302D28` | Hero card only — one notch brighter to lead the eye (elevation 2) |
| `Hairline` | `#E7E3DC` | `#3A3833` | Card borders, dividers, chart baseline |
| `Track` | `#ECE8E1` | `#34322D` | Unfilled bar/ring tracks, empty-day stubs, neutral pills |
| `BarNeutral` | `#C9C2B6` | `#4A4741` | Non-today chart bars (must be clearly visible, NOT faint) |
| `TextPrimary` | `#1F1D1A` | `#F2EFE9` | Hero numbers, card titles |
| `TextSecondary` | `#6B665E` | `#A7A199` | Captions, body, labels |
| `TextTertiary` | `#9A948B` | `#736E66` | Word counts, footnotes, axis labels |
| `Ember` | `#BE6E2A` | `#E7A45C` | Accent for graphics only: ring progress, today bar, flame, breakdown fills |
| `EmberText` | `#A85D22` | `#EDB06A` | Accent for small text (the "+today" delta) — darker in light for AA contrast |
| `EmberSoft` | `Ember @ 12% alpha` | `Ember @ 16% alpha` | Hover highlights, metadata chip fills |
| `EmberGlow` | `Ember @ 22% alpha` | `Ember @ 34% alpha` | Optional soft glow behind today bar / ring progress (dark-mode-forward) |

**Accent policy:** `Ember` is for graphics and large numerals (≥ 20pt) only. For any accent text below 20pt use `EmberText`. Never use Ember for borders, backgrounds of large areas, or chrome.

**Alternative accent (only if warm is rejected — do not mix):** `Ink-Teal` `#2E6B6B` (light) / `#5FA8A8` (dark), with `Ink-TealText` `#265C5C` / `#6FB4B4`. Swap the four Ember tokens 1:1; nothing else changes.

**Purist fallback (if the team wants 100% stock semantic colors):** `WindowBG→underPageBackgroundColor`, `CardBG→controlBackgroundColor`, `Hairline→separatorColor`, `Track→quaternaryLabelColor`, `BarNeutral→tertiaryLabelColor`, keep only `Ember`/`EmberText` custom. You lose the warmth and some depth but keep the hierarchy. **Recommended: use the full custom palette.**

### 1.2 Spacing scale (base unit = 4)

Use the 4pt scale for component details: `4, 8, 12, 16, 20, 24, 32, 40`.
The dashboard column uses a deliberate **10pt** density step for card gaps.

- Card interior padding: **16 horizontal / 8 vertical** for dense content cards.
- Gap between cards and groups in the dashboard column: **10**.
- Gap between the two breakdown cards: **12**.
- Content column side gutters: **32** (min **24** when window is narrow).
- Header → first card: **10**.

### 1.3 Corner-radius scale

| Element | Radius |
|---|---|
| Card | **14** |
| Metadata chip / pill | **8** |
| Button | **6** |
| Bar (breakdown & chart) | **3** (or top-corners `min(6, barWidth/2)` for chart, see §5) |
| Progress ring cap | round |
| Hover row highlight | **8** |

### 1.4 Type ramp

SF Pro for text; **SF Pro Rounded** for all numerals that represent a stat. Rounded + tabular figures is the single biggest "premium Apple" tell. See §10 for the exact AppKit font recipe.

| Role | Family | Size / Weight | Extra |
|---|---|---|---|
| Page title | SF Pro Display | 28 / Bold | `TextPrimary` |
| Page subtitle | SF Pro Text | 13 / Regular | `TextSecondary` |
| Hero number | SF Pro Rounded | 40 / Bold | tabular, `TextPrimary` |
| Stat large | SF Pro Rounded | 24 / Semibold | tabular (hours, streak number) |
| Stat medium | SF Pro Rounded | 20 / Semibold | tabular (footer strip) |
| Unit suffix | SF Pro Text | 13 / Medium | `TextSecondary`, baseline-aligned to a large numeral |
| Card title | SF Pro Text | 15 / Semibold | `TextPrimary`, with a leading SF Symbol |
| Eyebrow | SF Pro Text | 11 / Semibold | UPPERCASE, tracking **+0.5**, `TextTertiary` |
| Body | SF Pro Text | 13 / Regular | `TextSecondary` |
| Caption | SF Pro Text | 11–12 / Medium | `TextSecondary` |
| Ranking name | SF Pro Text | 12 / Medium | `TextPrimary` (top row Semibold) |
| Inline numeric | SF Pro Rounded | 12 / Semibold | tabular (percentages) |
| Accent delta | SF Pro Rounded | 13 / Semibold | tabular, `EmberText` |

### 1.5 Elevation & shadow

Cards lift subtly, never pop (voicebox-level restraint).

| Elevation | Fill | Border | Shadow |
|---|---|---|---|
| Card (default) | `CardBG` | 1px `Hairline` | color black, opacity **0.05** (light) / **0.30** (dark); radius **10**; offset (0, **-1**) in AppKit y-up coords (visually downward) |
| Card (hero) | `CardBG_Hero` | 1px `Hairline` | opacity **0.07** (light) / **0.36** (dark); radius **14**; offset (0, **-2**) |

Optional dark-mode glow (voicebox flourish): behind the today chart bar and the ring's progress arc, draw a soft `EmberGlow` shadow (radius 8, no offset). Only in dark mode; skip if Reduce Transparency is on.

---

## 2. Layout & hierarchy

### 2.1 Content column

- Wrap the vertical content `NSStackView` in the existing scroll view, but **constrain it to `max-width 780pt`, centered** in the document view, with the §1.2 gutters. Full-width cards on a wide window read "web dashboard"; a composed 780pt column reads "Mac app."
- The scroll content background is `WindowBG` (recessed). Cards are `CardBG` (raised). **This contrast is the #1 fix** — today the cards ≈ background, so nothing reads as a card.

### 2.2 Top-to-bottom order (new)

1. **Header band** — "Dashboard" title (Page title) + subtitle "Your reading, remembered privately on this Mac." (Page subtitle), with a right-aligned **privacy pill** (`lock.fill` + "On this Mac"). 10pt gap below.
2. **Hero card** (full column width, 112pt tall) — one wide card, not three tiles. See §3.
3. **"This week" card** — merged goal + chart in one card. See §4.
4. **Breakdowns row** — "Where you read" / "Voices you pick", 2-up, equal width. See §6.
5. **Longest read** — editorial feature card. See §7.
6. **Footer stat strip** — reads / avg words per read / cast reads, one slim divided strip. See §8.

Grouping (controls vertical gaps): Header · [Hero] · [This week] · [Breakdowns] · [Longest + Footer]. Use a compact 10pt gap throughout.

**Net change:** from 6 big tiles + 4 cards (10 heavy blocks, all near-equal weight) to 1 hero + 1 merged card + 2 breakdowns + 1 feature + 1 slim strip. Fewer, ranked, calmer.

---

## 3. Hero card

Replaces the current three equal `metricCard`s in `makeHeroRow()`.

**Container:** one full-width card, `CardBG_Hero`, hero elevation, radius 14, height **112**. Interior padding 20 horizontal / 10 vertical. Horizontal `NSStackView`, `alignment = .centerY`, with a left block, a flexible spacer, a 1px `Hairline` vertical divider (70pt tall), and a right block.

**Left block (the hero moment):**
- Line 1: lifetime words — Hero number (SF Rounded **40 / Bold**, tabular, `TextPrimary`).
- Line 2: caption "words read aloud" — Caption (12 / Medium, `TextSecondary`, tracking +0.2).
- Line 3 (conditional): `＋{wordsToday} today` — Accent delta (SF Rounded 13 / Semibold, `EmberText`). **Render only when `wordsToday > 0`.** Uses the previously-unused `wordsToday`. Format the number with the existing decimal formatter.

**Right block (two stacked satellites, divided by a 1px `Hairline` horizontal rule):**
- **Hours listened:** `headphones` SF Symbol (13pt, `TextSecondary`) + number Stat large (SF Rounded 24 / Semibold, `TextPrimary`) with unit "hrs" as Unit suffix (13 / Medium, `TextSecondary`) baseline-aligned. Caption "hours listened" (11 / Medium, `TextSecondary`). Value = `lifetimeSeconds / 3600`, one decimal.
- **Current streak:** `flame.fill` SF Symbol (14pt, `Ember`) + number Stat large (SF Rounded 24 / Semibold, `EmberText`). Caption "day streak". Sub-caption "Best {bestStreakDays}" (11 / Medium, `TextTertiary`).
  - Streak = 0 state: flame in `Track` gray, number in `TextTertiary`, caption "Start today".

Right block width: give both satellites equal height; the block occupies ~ 42% of the card width. Numbers left-aligned within their satellite.

---

## 4. "This week" card (merged goal + chart)

**Rationale:** the current "Weekly goal" card and "This week" chart card both describe the same seven days. Merging removes the redundancy that makes the page feel padded, and creates one strong focal card.

**Container:** full-width card, `CardBG`, default elevation, radius 14, padding 16/8. Vertical `NSStackView`, `alignment = .leading`, spacing 6.

**Header row** (horizontal, `alignment = .centerY`, fills width):
- Left: `chart.bar.fill` (13pt, `TextSecondary`) + title "This week" (Card title 15 / Semibold).
- Right: goal readout `{wordsThisWeek} / {weeklyGoalWords}` (SF Rounded 13 / Semibold tabular; the numerator `TextPrimary`, the "/ goal" part `TextSecondary`) + the **progress ring** (see §9) at **40×40** to its right.

**Body:** the weekly bar chart (see §5), height **56**, full card width.

**Footer row** (de-emphasized, separated from body by a 1px `Hairline` inset divider, with 6pt stack spacing):
- `target` SF Symbol (12pt, `TextTertiary`) + "Weekly goal" (Caption 11 / Medium, `TextSecondary`) + `goalField` (NSTextField, right-aligned, 92pt wide, SF Rounded 12 / Medium tabular) + `goalStepper`.
- **Cut** the helper sentence "Set a motivating target. Your goal stays on this Mac." The privacy pill in the header already carries that message.

Ring and bars are not redundant here: the ring = goal completion at a glance; the bars = daily distribution. Keep the ring small (40pt) so bars remain the focus.

---

## 5. Weekly bar chart (`WeeklyBarChartView`)

Custom `draw(_:)`. Fix the three current defects: pill-shaped bars, all-seven value labels, and near-invisible non-today bars.

**Geometry:**
- Plot inset: 8 horizontal, 4 vertical.
- Baseline Y: `plot.minY + 22` (leaves room for weekday initials below).
- Chart top: `plot.maxY - 20`.
- `columnWidth = plot.width / 7`; `barWidth = min(22, columnWidth * 0.42)`, centered per column.
- **Headroom:** compute `niceMax` = the data max rounded UP to a "nice" number (e.g. next multiple of a power-of-ten step) so the tallest bar leaves ~18% headroom and is never flush to the top. Scale bar heights to `niceMax`.

**Bar shape:** flat bottom on the baseline, **only the top two corners rounded**, radius `min(6, barWidth/2)`. Build the path explicitly (bottom-left → up → top-left arc → top-right arc → down → close). NOT a fully-rounded rect (today's `xRadius = barWidth/2` makes lozenges/dots).

**Bar fills:**
- Today: `Ember`. In dark mode, draw an `EmberGlow` soft shadow behind it (radius 8) unless Reduce Transparency is on.
- Other days: `BarNeutral` (clearly visible — NOT `tertiaryLabelColor`).
- Empty day (words == 0): draw a **2pt stub** in `Track` so the day reads as "empty," not "missing."

**Today marker:** a 3pt-diameter `Ember` dot centered ~6pt above the today bar's cap.

**Labels:**
- Value label: show **only on the today bar** (SF Rounded 10 / Semibold, `Ember`, centered above the cap). Remove the other six numbers. All exact daily values move to hover (below).
- Weekday initials: along the bottom at `plot.minY + 4`, 10 / Regular, `TextTertiary`. Today's initial: 10 / Semibold, `Ember`, with a 3pt `Ember` dot 3pt beneath it.
- Baseline: 1px `Hairline`, full plot width. No gridlines (Apple Health style).

**Hover (NSTrackingArea, one region per column):** on hover over a column, show a small tooltip bubble anchored above that bar: `CardBG` fill, `Hairline` 1px border, radius 8, shadow (default card shadow), padding 8/6. Content: weekday + date on line 1 (format `DayPoint.date` as "Tue, Jul 22", `TextSecondary` 11), exact words on line 2 (SF Rounded 13 / Semibold tabular, `TextPrimary`). This is where all seven numbers live now.

**Empty state (no reads any day this week):** seven 6pt ghost bars in `Track`, plus a centered caption "No reading yet this week" (Body, `TextSecondary`).

**Optional motion (respect Reduce Motion):** on first appearance, animate each bar's height from baseline to target, 0.4s ease-out, 20ms stagger per column (CABasicAnimation on a shape/replicator layer, or animate a fraction driving `draw`).

---

## 6. Breakdown rows (`RankingListView` for "Where you read" / "Voices you pick")

Two cards, 2-up, equal width, `distribution = .fillEqually`, gap 12. Align card tops and let each card use its intrinsic content height; do not equalize their heights or impose a minimum height. Each card: `CardBG`, default elevation, padding 16/8, vertical stack spacing 6. Ranking-list row spacing is 4.

**Card header:** SF Symbol + title (Card title 15 / Semibold). Sources card symbol `macwindow`; Voices card symbol `waveform`.

**Each row (two lines, down from three):**
- **Line 1:** `[identity symbol] Name … {percent}` — identity symbol (14pt, `TextSecondary`); name (Ranking name 12 / Medium, `TextPrimary`, truncate tail); flexible spacer; percent (Inline numeric SF Rounded 12 / Semibold tabular, `TextPrimary` — promote from secondary for emphasis), right-aligned, min 36pt wide. Tuck the raw count "· 1,240 words" after the name in 10 / Regular `TextTertiary` (truncates first).
- **Line 2:** the bar — height **4**, `Track` background, `Ember` fill, radius 2, full row width. `fraction` from `Ranked.fraction`.

**Rank emphasis:** row #1 name is Semibold and its bar is full `Ember`; rows 2+ use Ember at **75% alpha** for a gentle falloff so the eye lands on the leader.

**Identity symbol mapping (with fallback):**
- Sources by app name (case-insensitive contains): Safari→`safari`, Chrome→`globe`, Mail→`envelope.fill`, Books→`book.closed.fill`, News→`newspaper.fill`, Notes→`note.text`, Messages→`message.fill`, Slack→`number`, Preview/PDF→`doc.fill`, Kindle→`book.fill`, default→`app.dashed`.
- Voices: `waveform` for all (or `person.wave.2.fill`).

**Empty state:** centered "No reading data yet" (Body, `TextSecondary`) — keep current behavior.

**Optional:** to visually distinguish the two cards, Voices bars may use `Ink-Teal` while Sources use `Ember`. Default is single-accent (both Ember) for coherence; only split if the team wants it.

---

## 7. Longest read card (editorial feature)

Turn the flat card into a "trophy" moment.

**Container:** full-width card, `CardBG`, default elevation, padding 16/8. Vertical stack, spacing 4.

- **Header:** `crown.fill` SF Symbol (13pt, `Ember`) + title "Longest read" (Card title 15 / Semibold).
- **Title of the read:** `longest.title` — SF Pro Text **17 / Semibold**, `TextPrimary`, up to 2 lines, wrapping.
- **Metadata chips row** (horizontal, spacing 8): three pills, each `EmberSoft` fill, radius 8, padding 8 horizontal / 4 vertical, each = small SF Symbol (10pt) + label (Caption 11 / Medium, `TextSecondary`):
  - `textformat.size` + "{words} words"
  - `clock` + "{minutes} min" (`longest.seconds / 60`, one decimal)
  - `waveform` + voice display name (`voiceDisplayName(longest.voice)`)
- **Empty state:** title "No reads yet" + one line "Your longest read will appear here." (Body, `TextSecondary`). No chips, no crown tint (crown in `TextTertiary`).

---

## 8. Footer stat strip (demoted summary)

Replaces the current three big summary tiles (`makeSummaryRow`). These are tertiary facts and must not compete with the hero.

**Container:** one full-width card, `CardBG`, default elevation, height **52**, padding 0 (cells manage their own). Horizontal `NSStackView`, `distribution = .fillEqually`, three cells divided by 1px `Hairline` vertical rules (34pt tall).

**Each cell** (vertical, centered): number (Stat medium, SF Rounded 20 / Semibold tabular, `TextPrimary`) over caption (Caption 11 / Medium, `TextSecondary`), with a small leading SF Symbol on the caption:
- `book.pages` + "reads" → `totalReads`
- `text.word.spacing` + "avg words / read" → `averageWordsPerRead`
- `airplayaudio` + "cast reads" → `castReads`

---

## 9. Progress ring (`WeeklyGoalRingView`)

- Diameter **40** (inside the This-week header). Track and progress stroke **6pt** (down from 8), round caps.
- Track color `Track`; progress color `Ember`. Progress arc starts at 12 o'clock, sweeps clockwise by `fraction` (`weeklyGoalFraction`).
- Center label: `{percent}%`, SF Rounded **15 / Semibold**, `TextPrimary`, tabular.
- **100% state:** fill the full ring in `Ember` and replace the "%" text with a `checkmark` SF Symbol (11pt, `Ember`), OR tint the number `EmberText` — pick the checkmark.
- **Dark-mode glow (optional):** soft `EmberGlow` shadow (radius 6) behind the progress arc, skipped under Reduce Transparency.
- Animate `fraction` changes 0.35s ease-out (respect Reduce Motion).

---

## 10. Implementation notes for AppKit

Mapping design concepts → concrete AppKit constructs. Follow these so nothing is ambiguous.

**Dynamic colors (theme-aware).** Build each token as a dynamic `NSColor`. Two accepted approaches:
- Asset-catalog color sets (Any/Dark appearances) referenced by name, or
- `NSColor(name:) { appearance in appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkNSColor : lightNSColor }`.
Expose them as `static` members on a `DashboardTheme` enum. `EmberSoft`/`EmberGlow` are `Ember.withAlphaComponent(...)` per appearance.

**Custom-drawn views must re-render on theme change.** In `WeeklyBarChartView`, `WeeklyGoalRingView`, `FractionBarView`, and the card view, override:
```
override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true            // layer-backed views: also refresh layer colors
}
```
Resolve `NSColor` → `CGColor` **inside** `draw(_:)`/`updateLayer()` (wrap layer-color assignments in `effectiveAppearance.performAsCurrentDrawingAppearance { ... }` on the layer-backed card), never cache CGColors across appearance changes. This is the classic "colors don't update on theme switch" bug — avoid it.

**Cards → layer-backed, not bezier `draw`.** Replace `DashboardCardView.draw(_:)` with a layer-backed view: `wantsLayer = true`; in `updateLayer()` set `layer.cornerRadius = 14`, `layer.backgroundColor = CardBG.cgColor`, `layer.borderWidth = 1`, `layer.borderColor = Hairline.cgColor`, `layer.masksToBounds = true`. **Shadow cannot coexist with `masksToBounds = true` on the same layer** — put the fill+border+corner+mask on the content layer, and apply the shadow via the NSView's `shadow` property (an `NSShadow`) or a separate unmasked wrapper layer beneath. Set `layerContentsRedrawPolicy = .onSetNeedsDisplay`. Add a `isHero` flag to switch fill/shadow to the hero elevation.

**Rounded tabular numerals (`NSFont`).** There is no `monospacedRoundedSystemFont` convenience, so compose it:
```
let base = NSFont.systemFont(ofSize: size, weight: weight)
let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
let tabular = rounded.addingAttributes([
    .featureSettings: [[
        NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
        NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
    ]]
])
let font = NSFont(descriptor: tabular, size: size) ?? base
```
Wrap this in one helper `Font.roundedTabular(_ size: CGFloat, _ weight: NSFont.Weight)` and use it for every stat numeral (hero, stat large/medium, percentages, deltas, tooltip values). Keep SF Pro Text (non-rounded) for words/labels.

**Layout.** Keep `NSStackView` + Auto Layout throughout. Content column max-width: pin the content stack `centerX` to the document view and add `widthAnchor ≤ 780` plus leading/trailing `≥ gutter` at lower priority so it shrinks gracefully on narrow windows. Cards fill the column width. Existing per-card `widthAnchor == content.widthAnchor` constraints stay.

The default window content size is **720×720pt**. The dashboard content uses
10pt top and bottom insets; its scroll view remains as a fallback for
restored smaller windows and accessibility-driven size changes.

**SF Symbols.** `NSImage(systemSymbolName:accessibilityDescription:)` with `withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:weight:))`; tint by wrapping in an `NSImageView` with `contentTintColor = token`, or use `.applying(.init(paletteColors:))`. Place symbols in a horizontal `NSStackView` with their label, `alignment = .firstBaseline` (or `.centerY` for pills). Provide fallbacks for older symbol names if the deployment target predates them.

**Hover (chart + breakdown rows).** Use `NSTrackingArea` (`.mouseEnteredAndExited`, `.activeInActiveApp`, `.inVisibleRect`). Chart: one region per column → drive the tooltip bubble (a small layer-backed overlay view added above the chart, or draw in `draw(_:)` keyed off a `hoveredIndex`). Breakdown rows: on enter, draw/reveal an 8-radius `EmberSoft` highlight inset 6pt behind the row.

**Controls.** `goalField` (NSTextField) and `goalStepper` keep the system focus ring and standard control styling — do not restyle them. Just resize/reposition per §4 and apply the rounded tabular font to the field.

**Accessibility.** Preserve the existing `setAccessibilityLabel` calls; add labels for the new hero satellites, ring ("Weekly goal N percent complete"), and chart columns ("Tuesday, 1,240 words"). Respect `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` (skip animations) and `...ReduceTransparency` (skip glows).

**Contrast note.** `Ember #BE6E2A` on white is ~3.7:1 — fine for graphics and large numerals but under AA for small text, which is why small accent text uses `EmberText #A85D22` (~4.6:1). Keep that split.

---

## 11. What to cut / defer

**Cut now:**
- The goal helper sentence "Set a motivating target. Your goal stays on this Mac."
- Six of the seven bar value labels (today-only + hover replaces them).
- The three standalone summary tiles as big cards → collapsed into the footer strip.

**Merge now:**
- Weekly-goal card + weekly chart card → one "This week" card.

**Defer (nice later, not this pass):**
- Lifetime-words sparkline / trend over time.
- Month / all-time toggle on the chart.
- Real per-app icons (from `NSWorkspace`/bundle) instead of mapped SF Symbols.
- Ink-Teal secondary accent for the Voices card (only if the team wants the two breakdown cards visually differentiated).

---

## 12. Build order (suggested)

1. `DashboardTheme` color tokens + `Font.roundedTabular` helper. (Unblocks everything.)
2. Layer-backed `DashboardCardView` with elevation + hero flag; apply `WindowBG`/`CardBG` two-level surfaces; add the 780pt centered column.
3. Header band + privacy pill.
4. Hero card (§3) — including the `wordsToday` delta.
5. Merged "This week" card (§4) + ring (§9).
6. Weekly chart rework (§5) + hover tooltips.
7. Breakdown rows (§6).
8. Longest read (§7) + footer strip (§8).
9. Verify light AND dark after each step; verify theme-switch live (Appearance change) re-renders every custom view; verify Reduce Motion / Reduce Transparency.

Verify at each step in the running app (light + dark) — do not assume a value looks right until it's on screen.
