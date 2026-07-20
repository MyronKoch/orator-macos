# PRD 25: Chatterbox expressive provider — evaluation SPIKE (not a commitment)

**This is a time-boxed trial with explicit kill-criteria, not a build order.** The goal is to
decide, with measurements, whether Chatterbox earns a place as an **optional** expressive/multilingual
provider in Orator. If it fails a kill-criterion, we stop and write down why.

## Scope decision (the framing that makes this worth doing)
- Chatterbox is a **500M** model (~**1.3 GB** on MLX fp16) — 6× Kokoro-82M, and slower per utterance.
  That latency kills it for the **live** paths (hotkey read, Reader karaoke), where Kokoro's speed is
  the whole point. **Kokoro stays the default and the ONLY engine for live synthesis.**
- **But the user's insight: script mode is batch — it pre-synthesizes, so it doesn't need to be
  instantaneous, only "fairly fast."** So Chatterbox is scoped to the **non-live, pre-rendered paths**:
  **script-mode table reads (PRD 24) and audio export (backlog R1)**, where a generous latency budget
  is fine. That scoping is what defuses the speed objection.
- **What Chatterbox adds that Kokoro lacks (the reason to trial):** emotion/**exaggeration** control,
  **paralinguistic tags** (`[laugh]`, `[sigh]`, `[cough]`), and **23 languages**. For expressive
  dialogue in a table read, that's a real draw.

## HARD boundaries (do not cross in this trial)
- **NO voice cloning.** The trial uses Chatterbox's **default/predefined voices** + its expressive
  controls only. Cloning stays off — it remains Orator's hard "no cloning" line.
- **Accents-via-cloning is EXPLICITLY OUT OF SCOPE.** Chatterbox's accented-English capability comes
  *from* cross-lingual cloning (the friend's ask). Unlocking that is a **separate, deliberate principle
  reversal** — an ethics + product decision the user must make explicitly, WITH the watermark/abuse
  surface on the table. It is NOT part of this spike and must not be smuggled in.
- **100% local.** Chatterbox runs on-device; no network synthesis, no keys. Compatible.
- **Optional, not bundled.** ~1.3 GB must NOT inflate the base app. Ship it as an **on-demand download**
  (a model-manager fetch on first use), keeping the base install light. Base stays Kokoro-only.
- **Engine core untouched.** Chatterbox is a new `TTSProvider` (PRD 21) that only *supplies* `[Float]`
  PCM (resampled to the engine's 24 kHz mono). The `OratorEngine` concurrency state machine does not change.
- **Watermark disclosure.** Every Chatterbox output carries Resemble's imperceptible Perth watermark.
  Acceptable for a personal reader, but note it in the UI where Chatterbox voices are chosen.
- **License:** Chatterbox is **MIT** (commercial OK). Verify any *port's* license separately.

## Integration paths (prefer native; server is measurement-only)
- **Path A — native MLX-Swift / CoreML provider (the real target).** Wrap a Chatterbox Apple-Silicon
  port behind `TTSProvider`. Candidates to evaluate for production-viability: the Chatterbox **MLX fp16**
  build, **Chatterbox Flash CoreML**, and Swift toolkits **mlx-audio-swift** / **speech-swift**
  (soniqo, MLX Swift + CoreML). Architecturally coherent with KokoroSwift. Risk: these ports are
  **early/community** — maturity + `[Float]` PCM output + sample rate + port license must be verified.
- **Path B — local Python server (measurement ONLY, never shipped).** Stand up `chatterbox-tts` (or the
  mlx-audio server) locally purely to measure quality/latency. **Do NOT ship a bundled Python+PyTorch
  runtime** — macOS notarization of that is a nightmare and multi-GB. Server path is a throwaway probe,
  not a product.

## Spike steps (time-boxed)
1. **Measure quality (Path B is fine here):** synthesize representative script-mode dialogue with
   Chatterbox default voices — English + **Spanish** (the film use case) — and A/B against Kokoro.
   Judge: is it meaningfully more **expressive/natural**? Does the exaggeration knob + paralinguistic
   tags add real value for dialogue?
2. **Measure latency** on the user's M-series Mac for a typical table-read chunk. Record cold-start,
   per-utterance, and throughput. Compare against a "fairly fast for batch" bar (define: e.g. must
   render a scene faster than it plays, ideally ≥1× realtime for pre-render).
3. **Assess the native ports (Path A):** is any of mlx-audio-swift / speech-swift / Chatterbox-CoreML
   production-viable — outputs PCM, correct sample rate, stable, acceptably licensed?
4. If viable: prototype `ChatterboxProvider: TTSProvider` (default voices only), gated behind an
   optional model download, wired into **script mode / export only** (never the live path). Measure
   download size, memory, and end-to-end.
5. **Decide** against the kill-criteria below.

## Kill-criteria (abandon if ANY holds)
- No production-viable native Swift/MLX/CoreML port, and the only route is bundling Python/PyTorch.
- Default-voice quality/expressiveness is not clearly better than Kokoro for table reads (if it's not
  better *without* cloning, it isn't worth 1.3 GB + latency).
- Latency too slow even for **batch** script-mode on the user's Mac (below the pre-render bar in step 2).
- The Perth watermark or a port's license proves problematic.
- Footprint unacceptable even as an optional download.

## Graduation criteria (spike → feature, only if it survives)
Chatterbox becomes an **optional, download-on-demand, non-default** provider offered specifically in
**script mode / export**, selectable per-character in the cast (PRD 24), default voices only, watermark
disclosed. Kokoro remains default everywhere and the sole live-path engine.

## Who runs it
Maintainer runs the spike — it's ML + performance measurement + engine-adjacent provider work (needs
real builds and latency testing on-device; not a Codex task). If it graduates, Codex can do the
provider-picker UI.

## Sources
- resemble-ai/chatterbox (MIT), HF `ResembleAI/chatterbox`, Chatterbox Multilingual v3 (23 langs, Perth
  watermark), mlx-audio (Blaizzy), speech-swift (soniqo, MLX Swift + CoreML), Chatterbox Apple-Silicon
  builds. See docs/competitive-landscape.md for the surrounding market context.
