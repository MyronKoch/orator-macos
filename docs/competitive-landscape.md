# Competitive landscape — screenplay / table-read TTS (scanned 2026-07-20)

Context: evaluating whether Orator's **script mode** (PRD 24) can "compete at a high level for
professionals." Short answer: the space is **crowded**, the quality leaders run on **cloud** voices
(which Orator rejected by design), and the incumbent ships a free local version. Orator's only
defensible wedge is **privacy + local + free + a better reading UX** — not raw voice fidelity.

## Layer 1 — the incumbent (already ships this, free)
**Final Draft** (industry-standard screenwriting app) has built-in character-voice reading:
- **Tools → Assign Voices**: assign voices to Man 1/2, Woman 1/2, set a **narrator** for non-dialogue,
  adjust pitch/speed. Uses Apple (Mac) / Microsoft (Win) **system TTS** — local.
- **Tools → Speech Control**: plays the script aloud with those voices.
- Source: https://kb.finaldraft.com/hc/en-us/articles/27778802776596-How-do-I-use-Speech-Control
- Implication: "voice per character + narrator, read aloud, locally" is **not novel**. But Speech Control
  is clunky robotic system-TTS with **no karaoke follow-along**, and it's locked inside Final Draft.

## Layer 2 — the AI table-read startups (a named category with a "best of 2026" listicle)
Mostly **premium cloud AI voices** (ElevenLabs-grade), per-line emotion, voice cloning, exec-sharing,
actor rehearsal modes:
- **ScriptRead.ai** — upload → auto-detect characters → assign AI voices → table read in seconds; PDF/FD/Fountain. https://scriptread.ai/
- **Pagecast** — distinct AI voice per character, audition pairings, parentheticals as performance cues. https://pagecast.io/
- **Screenplayer** — per-character voices with accents + emotional tones. https://www.screenplayer.ai/
- **AIScriptReader** — multi-voice "audio dramas," consistent per-character AI voice. https://aiscriptreader.com/script-reader
- **tableread** — 90+ character voices + actor rehearsal (app as scene partner). https://www.tablereadpro.com/
- **Table Read Studio** — table reads for rewriting/dev/sharing audio with execs. https://www.tablereadstudio.app/
- Category roundup: "11 Best Apps for Listening to Scripts in 2026" — https://scriptation.com/blog/best_apps_for_listening_to_scripts_tv-and-film/

## Strategic read (blunt)
- **Orator cannot out-voice the cloud startups while staying 100% local.** 26 Kokoro voices, no cloning,
  no per-line emotion vs ElevenLabs-grade catalogs. On raw voice wow, that's a designed-in loss.
- **Orator can't claim novelty over Final Draft** for "local character reading + narrator."
- **The one wedge nobody in Layer 2 can match:** *script confidentiality*. Leaks/NDAs are a real,
  high-anxiety pain; every cloud tool asks a writer to upload an unreleased script to a server. Orator:
  **"Your unreleased screenplay never leaves your Mac. No account, no upload, no subscription, no
  per-read cost — a private table read, offline, forever."** Structurally impossible for the cloud crowd.
- **vs Final Draft:** be the *better local reader* — nicer voices (Kokoro > system TTS), the Reader
  karaoke follow-along, and it works on scripts from **any** source, not just inside Final Draft.

## Recommendation
Build script mode (PRD 24) for the real user pull + the privacy/cost-conscious writer, positioned as
**"the private, free, local table read"** — NOT as a challenger to the funded AI-voice startups. Do not
spend to beat them on voice fidelity (unwinnable while local). The one lever that narrows the gap is
**PRD 21 (more/better local voices)**; even so, local will always trail cloud on pure fidelity — an
acceptable trade when privacy is the entire point.
