<img width="1344" height="768" alt="bust-v1-transparent" src="https://github.com/user-attachments/assets/f13ff9e7-bcb6-4a0a-8331-423aa1a69ba4" />

[Orator for Mac](https://github.com/MyronKoch/orator-macos/releases/download/v1.0.0/Orator-1.0.0.dmg)

# Orator

**Highlight any text, anywhere on your Mac. Press a key. Hear it read aloud in a beautiful AI voice.**

Orator is a free, open-source menu bar app that reads selected text out loud using the [Kokoro-82M](https://huggingface.co/prince-canuma/Kokoro-82M) neural text-to-speech model - running **entirely on your Mac**. No cloud. No subscription. No account. Nothing leaves your computer, ever.

macOS's built-in "Speak Selection" is functional but robotic. Orator gives you 26 natural AI voices at the same one-keystroke convenience.

## How it works

1. Highlight text in **any** app - Safari, Mail, Notes, PDFs, anywhere
2. Press **Option + '** (or Option + Return)
3. Orator reads it aloud - press the hotkey again to stop

Long articles start speaking in about a second: text is split at sentence boundaries and synthesized in a pipeline while earlier chunks play.

## Features

- **26 voices** - US & UK English, male & female, pick in the menu bar
- **Speed control** - 0.8x to 1.5x
- **100% local & private** - on-device inference via Apple's MLX framework on the Neural-friendly GPU
- **Menu bar fallbacks** - "Speak Clipboard" and "Stop Speaking" for hotkey-free use
- **Start at Login** - set it once, forget it
- **Free & MIT licensed**

## Requirements

- Apple Silicon Mac (M1 or newer) - the model runs on the GPU via MLX
- macOS 15 (Sequoia) or newer
- ~400 MB disk space (the voice model is bundled in the app)

## Install

1. Download the latest `Orator-x.y.z.dmg` from [Releases](../../releases)
2. Open it and drag **Orator** into **Applications**
3. Launch Orator - a welcome window walks you through the one required
   permission (Accessibility, which lets Orator read your text selection)
4. Highlight text anywhere, press **Option + '**

## Build from source

Requires Xcode 26+ with the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`).

```bash
git clone https://github.com/MyronKoch/orator-macos.git
cd orator-macos
./scripts/build-app.sh                    # ad-hoc signed dev build
./scripts/build-app.sh --sign "Developer ID Application: You (TEAM)"
./scripts/make-dmg.sh                     # package build/Orator.app into a DMG
```

The build downloads the Kokoro model from the HuggingFace cache
(`prince-canuma/Kokoro-82M`); fetch it once with any HuggingFace client, or
place `kokoro-v1_0.safetensors` in the cache manually.

Voice embeddings ship in `Resources/voices.npz`, converted from the
`.pt` files in the same HuggingFace repo.

## Architecture

```
Option+'  ──►  HotkeyManager (Carbon + NSEvent + CGEventTap, deduped)
                    │
                    ▼
              AppDelegate — simulates ⌘C, captures selection,
                    │        restores your clipboard
                    ▼
              TextChunker — sentence-aware splits ≤350 chars
                    │
                    ▼
              OratorEngine — KokoroSwift (MLX) synthesis, pipelined
                    │        chunk-by-chunk into an AVAudioPlayerNode queue
                    ▼
                 🔊 24 kHz audio
```

Built on [kokoro-ios](https://github.com/mlalma/kokoro-ios) (KokoroSwift),
[mlx-swift](https://github.com/ml-explore/mlx-swift), and
[MisakiSwift](https://github.com/mlalma/MisakiSwift) G2P.


## License

MIT © 2026 Myron Koch
