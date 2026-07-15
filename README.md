<img width="1344" height="768" alt="bust-v1-transparent" src="https://github.com/user-attachments/assets/f13ff9e7-bcb6-4a0a-8331-423aa1a69ba4" />

# [>> Click to download the installer DMG - Orator for Mac](https://github.com/MyronKoch/orator-macos/releases/download/v1.0.1/Orator-1.1.1.dmg)


# Orator

<p align="center">
  <a href="https://github.com/MyronKoch/orator-macos/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/MyronKoch/orator-macos?color=coral&label=release"></a>
  <a href="https://github.com/MyronKoch/orator-macos/releases"><img alt="Total downloads" src="https://img.shields.io/github/downloads/MyronKoch/orator-macos/total?color=coral&label=downloads"></a>
  <img alt="Platform: macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-1a2a4f?logo=apple&logoColor=white">
  <img alt="Apple Silicon only" src="https://img.shields.io/badge/Apple%20Silicon-required-1a2a4f?logo=apple&logoColor=white">
  <img alt="Swift 6.2" src="https://img.shields.io/badge/Swift-6.2-f05138?logo=swift&logoColor=white">
  <img alt="Built with MLX" src="https://img.shields.io/badge/inference-MLX-1a2a4f">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-coral"></a>
</p>

> **Apple Silicon only.** Orator runs the Kokoro model on the GPU through Apple's [MLX](https://github.com/ml-explore/mlx) framework, which is built exclusively for M-series chips. It will not run on Intel Macs. Anything M1 or newer (every Mac Apple has sold since late 2020) is supported.

**Highlight any text, anywhere on your Mac. Press a key. Hear it read aloud in a beautiful AI voice.**

Orator is a free, open-source menu bar app that reads selected text out loud using the [Kokoro-82M](https://huggingface.co/prince-canuma/Kokoro-82M) neural text-to-speech model - running **entirely on your Mac**. No cloud. No subscription. No account. Nothing leaves your computer, ever.

macOS's built-in "Speak Selection" is functional but robotic. Orator gives you 26 natural AI voices at the same one-keystroke convenience.

## How it works

### 1. Highlight text in **any** app - Safari, Mail, Notes, PDFs, anywhere
### 2. Press **Option + '** (or Option + Return)
### 3. Orator reads it aloud - press the hotkey again to stop

Long articles start speaking in about a second: text is split at sentence boundaries and synthesized in a pipeline while earlier chunks play.

## Features

- **26 voices** - US & UK English, male & female, pick in the menu bar
- **Speed control** - 0.8x to 1.5x
- **100% local & private** - on-device inference via Apple's MLX framework on the Neural-friendly GPU
- **Menu bar fallbacks** - "Speak Clipboard" and "Stop Speaking" for hotkey-free use
- **Start at Login** - set it once, forget it
- **Free & MIT licensed**

## Requirements

- **Apple Silicon Mac (M1 or newer)** - required; the model runs on the GPU via MLX, which has no Intel support
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

## Sibling project

[orator-chrome-extension](https://github.com/MyronKoch/orator-chrome-extension) - the browser-extension version of Orator (reads web pages with Kokoro & Supertonic engines inside Chrome).

## License

MIT © 2026 Myron Koch
