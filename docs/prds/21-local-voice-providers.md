# PRD 21: Local voice expansion via a TTSProvider abstraction

**Decision (2026-07-19):** Orator stays **100% on-device**. NO cloud/BYOK TTS — the "nothing leaves your Mac" identity is the point. Grow the voice selection with additional **local** engines, all funneling into the existing playback/timeline/Reader path.

## Why this is a clean fit

Everything downstream of synthesis — `AVAudioPlayerNode`, pause/resume, the queue, and the Reader follow-along — operates on **`[Float]` PCM samples**, not on Kokoro specifically (`OratorEngine.play(_:)` / `schedule(samples:)`). So a new engine just has to **produce `[Float]` PCM at the engine's sample rate**; everything else works unchanged.

## The enabling refactor: `TTSProvider`

```swift
struct VoiceInfo { let id: String; let displayName: String; let provider: String; let language: String; let supportsWordTimings: Bool }

protocol TTSProvider {
    var id: String { get }                 // "kokoro", "apple", "piper"
    func voices() -> [VoiceInfo]
    /// Produce PCM (engine sample rate, mono Float) + optional word timings.
    func synthesize(text: String, voiceID: String, speed: Float) throws -> (samples: [Float], words: [WordTiming]?)
}
```

- **Kokoro becomes `KokoroProvider`** conforming to this — extract the existing `tts.generateAudio` call behind the protocol. The **guarded concurrency core (`generation`/`lock`/`scheduledBuffers`/`synthesisDone`/`speaking`, `play(_:)`) stays exactly as-is** — the provider only *supplies* samples; the core still schedules them. This is the one guarded, maintainer-authored change.
- **Voice identity gains a namespace.** Today `currentVoice: String` is a bare Kokoro name. Namespace it: `"kokoro:af_heart"`, `"apple:com.apple.voice.premium.en-US.Ava"`. `SpeechTimeline` routes by the prefix to the right provider. Keep a migration for existing saved `voice` prefs (bare name → `kokoro:` prefix).
- `speak(segments:)` (auto-casting) v1 rule: **all segments use the same provider** (don't mix providers within one cast).

## Phase 1 — TTSProvider + Apple system voices (DO FIRST)

Apple's `AVSpeechSynthesizer` exposes **every voice installed on the Mac** (dozens, many languages; user adds Premium/Enhanced neural voices free in System Settings › Accessibility › Spoken Content). Native, zero bundling, 100% on-device, and — critically — **it can keep the Reader karaoke** (it fires word-boundary events).

`AppleProvider` implementation notes (maintainer, engine-adjacent):
- Enumerate voices: `AVSpeechSynthesisVoice.speechVoices()` → `VoiceInfo` (mark `supportsWordTimings = true`).
- Synthesize to PCM **offline**: `AVSpeechSynthesizer.write(_ utterance) { buffer in ... }` yields `AVAudioPCMBuffer` chunks. **They arrive in Apple's format** (often 22.05kHz) — run them through `AVAudioConverter` to the engine's format (24kHz mono Float) before returning `[Float]`. This is the main gotcha.
- Word timings for the Reader: the `AVSpeechSynthesizerDelegate.speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)` callback gives **exact character ranges** in the original string as it speaks. The Reader already does tolerant char-range alignment, and Apple's ranges are *exact*, so this is even easier than Kokoro's token alignment. (For the offline `write` path, timing capture is trickier — if word-time capture from `write` proves unreliable, fall back to: Apple voices play but the Reader shows no per-word highlight for them, still fine.)
- Speed: map `engine.speed` → `AVSpeechUtterance.rate`.

UI (Codex): the Voices-tab picker groups voices **by provider** ("Kokoro" / "System (Apple)"), Apple section lists installed voices with a one-line hint: "Add more in System Settings › Spoken Content." Selecting persists the namespaced id; per-app voices + auto-cast voice-assignment already read the voice list, so they extend for free.

## Phase 2 — Expand Kokoro voices + languages (cheap follow-on)

- **More English Kokoro voices:** bundle a bigger `Resources/voices.npz` with additional embeddings — the engine already handles it.
- **Other languages** (Japanese, Chinese, Spanish, French, Hindi, Italian, Portuguese…): Kokoro-82M is multilingual, but the bundled G2P (`MisakiSwift`) is **English-only**. The KokoroSwift package **already ships `eSpeakNGG2PProcessor`** — wire it up and select G2P by the voice's language, detected from the voice prefix (jf_/jm_ = Japanese, zf_/zm_ = Chinese, etc.). Makes the "40+ languages" promise real **on-device**. Moderate effort; verify espeak-ng data ships in the bundle.

## Phase 3 — Piper (optional, large)

Largest open local-voice library (100+ voices, many languages, high quality, ONNX). Needs ONNX Runtime integration + a voice-download manager (Piper voices are downloadable `.onnx` + `.json`). A separate project; do only when a massive catalog is wanted. (Supertonic — already self-hosted for the Chrome extension — likely not worth a native port.)

## Landmines
- Do NOT touch the OratorEngine concurrency state machine — the provider supplies samples, the core schedules. Build + functional-test (hotkey fires + audio) after the KokoroProvider extraction.
- Preserve the Reader, pause/resume (⌥P), queue, per-app voices, and auto-casting behavior — you're adding a synthesis source, not re-plumbing playback.
- `AVSpeechSynthesizer` format conversion is mandatory (don't schedule Apple's buffers at the wrong sample rate → chipmunk/garbled audio).
- Migrate saved `voice` pref (bare Kokoro name → `kokoro:` namespace) so existing users' selection survives.
- Stay 100% local: no network, no keys, no Keychain. (This PRD exists because cloud was explicitly rejected.)

## Who builds what
- **Maintainer (guarded):** `TTSProvider` protocol + refactor Kokoro into `KokoroProvider` (core untouched); `AppleProvider` (PCM tap + `AVAudioConverter` + word-timing capture); voice-id namespacing + pref migration. Build-verify each.
- **Codex:** Voices-tab provider-grouped picker UI; later, the Piper voice-download manager.

## Recommended sequence
1. Phase 1 (protocol + Apple voices) — biggest voice-count jump for least work, native, private, keeps karaoke.
2. Phase 2 (Kokoro multilingual) — cheap, unlocks languages on-device.
3. Phase 3 (Piper) — only when a huge catalog is wanted.
