# Orator Roadmap

Orator does one thing well: highlight text anywhere, press a key, hear it in a natural voice - fully local, fully private, on Apple Silicon. That core is shipped and stable.

**Positioning (unchanged):** Orator helps you *consume text as audio* - reading, listening, accessibility, focus. It is deliberately **not** a voice-production tool: no dictation, no voice cloning (those are a different craft with their own tools). Orator turns text into listening, not voice into text.

**Design rule for everything below:** additive and isolated. The working highlight → hotkey → Kokoro path is never touched. Every capability is a feature-flagged stage or a separate window, built around the core, never through it.

---

## Shipped (v1.0.0 → v1.1.1)

- System-wide highlight-to-speak (global hotkey, triple-path capture) with 26 Kokoro voices, speed control
- **Custom hotkey recorder** (record any combo; default is Option+' only)
- **Pronunciation dictionary** (user respellings before synthesis)
- **Clean / structure-aware reading** (strips Markdown/formatting noise, reads links & structure naturally)
- **Audio export** (any selection → `.m4a` audiobook)
- **Read a File** (`.txt/.md/.rtf/.pdf` → speak or export)
- **Per-app voices** (voice+speed per app, in-window app picker, per-row voice **preview**)
- **Reading queue** + **continuous-listening** toggle
- **Reading history** (local, capped, clearable, off-switch)
- Grouped menu, first-run Accessibility onboarding, notarized DMG, public GitHub releases

---

## v2 — Toward a world-class showpiece

A showpiece is a flagship demo moment + design polish + distribution + engineering credibility, not just more features.

### Tier 0 — The Flagship
- **Reader window with karaoke follow-along highlighting** — a clean reading view where the word lights up as it's spoken, auto-scroll, click-any-word-to-jump, pause/resume, sentence skip. *The* demo feature. Requires surfacing word/sentence timing out of the Kokoro/MLX engine (maintainer core work) + a beautiful window (Codex).

### Tier 1 — Design & UX polish
- **Real Preferences window** (SwiftUI, tabbed: General / Voices / Pronunciations / Shortcuts / Advanced) instead of menu-bar-only settings.
- **Unified visual redesign** of all windows (onboarding, pronunciation, per-app voices, recorder) into one design system.
- **Polished onboarding** with live voice previews and a "try it now" moment.
- App-icon refinement + animated menu-bar states.

### Tier 2 — Intelligence (reuses the MLX runtime)
- **Local-LLM preprocessing**: summarize-then-read, "TL;DR first," strip web cruft, expand abbreviations in context.
- **Reading modes**: verbatim / cleaned / summarized.
- **Smart extraction**: Readability-style web parsing, column-aware PDF, robust abbreviation/sentence handling.

### Tier 3 — Distribution & discoverability (what makes it a showpiece)
- **Homebrew cask** (`brew install --cask orator`).
- **Landing page** with a demo video, features, one download button.
- **Demo GIF/video in the README** (current #1 README gap).
- **Sparkle auto-updates** (1.1.1 → 1.1.2 in place).
- Launch kit (Product Hunt / Show HN) when ready.

### Tier 4 — Engineering credibility
- **Unit test suite** over the pure logic (pronunciation matching, text chunking, clean-reading, hotkey matching) + **GitHub Actions CI** + green badge. (Currently zero tests.)
- **CONTRIBUTING.md**, issue/PR templates, Discussions.

### Tier 5 — Reach & integrations
- **macOS Services menu** ("Speak with Orator" on right-click) for non-hotkey users.
- Bookmarks / resume-position for long reads.
- Possible **second sandboxed Mac App Store channel** (Services-based; the sandbox precludes the global hotkey — a strategic fork to discuss).

### Explicitly out (unless the maintainer reverses)
- **Voice cloning** — Voicebox's lane; Kokoro can't do it anyway (its voices are model-specific embeddings, not portable). Reopen only on an explicit decision.
- **Intel Mac support** — MLX is Apple-Silicon-only; a universal ONNX-CPU engine is a large lift, likely not worth it.

---

## How this gets built

Isolated features are specified as PRDs in [`docs/prds/`](docs/prds/) and implemented one bounded module at a time. The proven workflow: Claude writes a tight PRD (with an explicit "Landmines — DO NOT TOUCH" section) → Codex implements → Claude reviews the diff, build-verifies, Developer-ID-signs, installs → the maintainer tests. Anything touching the hotkey, capture, or synthesis core is guarded by the maintainer. Packaging/release delegates cleanly to a Sonnet subagent.

Contributions welcome. Open an issue to discuss a tier item before starting.
