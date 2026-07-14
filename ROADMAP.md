# Orator Roadmap

Orator today does one thing well: highlight text anywhere, press a key, hear it in a natural voice - fully local, fully private. That core is done and shipped.

This roadmap is about what local, on-device AI *unlocks* beyond that. Cloud text-to-speech is a metered pipe: you pay per character, so the product stays thin. When inference is free and never leaves your machine, the economics invert - you can afford to reprocess text with a language model before speaking it, run always-on, personalize per app, clone voices, and batch a whole reading list into an audiobook overnight. Orator already ships an MLX runtime; the same runtime that speaks can also think.

The design rule for everything below: **additive and isolated.** The working highlight → hotkey → Kokoro path is never touched. Every capability is a feature-flagged stage or a separate window, built around the core, never through it.

---

## Tier 1 — Craft

Polish the thing that works.

- **Pronunciation dictionary** *(in progress)* — a user-editable map of respellings (`Koch → Coke`, `MLX → em ell ex`) applied before synthesis. Fixes names, acronyms, and the handful of words the model mispronounces. No model changes.
- **Structure awareness** — read headings, lists, tables, code, and math *differently*: pause at a heading, announce or skip a code block, speak math as math.
- **Per-app / per-language voice profiles** — remember the voice you want for a given app or language.
- **Sentence navigation & resume** — skip back/forward a sentence, replay, and resume a long read where you left off.

## Tier 2 — Intelligence

The expertise layer. Reuses the MLX runtime already in the app.

- **Local-LLM text normalization** — an optional pre-speech stage: expand abbreviations in context, strip navigation/citation/footnote cruft, voice image alt-text.
- **Reading modes** — verbatim, cleaned, summarized, or "TL;DR first, then read it."
- **Smart extraction** — Readability-style article extraction for web selections; column-aware PDF handling.

## Tier 3 — Interaction

- **Reader window** — a clean reading view with karaoke-style follow-along highlighting (the word lights up as it's spoken).
- **Reading queue** — stack up articles and let Orator work through them.

## Tier 4 — Reach

Turns a utility into a daily habit.

- **Audiobook / podcast export** — any article or PDF becomes a natural-voice `.m4a`, or a personal podcast feed you sync to your phone.
- **Shortcuts & MCP server** — let other apps and AI agents speak through Orator.
- **Background reading** — unread email, an RSS feed, on demand.

## Tier 5 — Moonshots

- **Local voice cloning** — sample a voice, read anything in it. Private, because it's local.
- **Multilingual auto-switch** — detect the language, pick the matching voice.
- **Conversational** — select text, ask a question about it, hear the answer (local LLM + TTS in one loop).

---

## How this gets built

Isolated features are specified as PRDs (see [`docs/prds/`](docs/prds/)) and implemented one bounded module at a time. The working core is guarded: anything touching the hotkey, capture, or synthesis pipeline is reviewed against the concurrency invariants in `OratorEngine` before it merges.

Contributions welcome. Open an issue to discuss a tier item before starting.
