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

> **Apple Silicon only.** Orator's default voice engine, Phonon, runs on the Neural Engine through Core ML, and the optional Kokoro voices run on the GPU through Apple's [MLX](https://github.com/ml-explore/mlx) framework; both are built for M-series chips. It will not run on Intel Macs. Anything M1 or newer (every Mac Apple has sold since late 2020) is supported.

**Highlight any text, anywhere on your Mac. Press a key. Hear it read aloud in a beautiful AI voice.**

Orator is a free, open-source menu bar app that reads selected text out loud using [Phonon](https://github.com/gradium-ai/xn-ptts), a fast, natural neural text-to-speech model - running **entirely on your Mac**. No cloud. No subscription. No account. Nothing leaves your computer, ever.

macOS's built-in "Speak Selection" is functional but robotic. Orator gives you dozens of natural AI voices at the same one-keystroke convenience.

## How it works

### 1. Highlight text in **any** app - Safari, Mail, Notes, PDFs, anywhere
### 2. Press **Option + '** (or Option + Return)
### 3. Orator reads it aloud - press the hotkey again to stop

Long articles start speaking in about a second: text is split at sentence boundaries and synthesized in a pipeline while earlier chunks play.

## Features

- **25 Phonon voices + 12 character voices** - US & UK English, male & female; star your favorites gold, silver or bronze
- **More voices on demand** - optional Kokoro, Piper and KittenTTS voice packs, downloaded from inside the app
- **Speed control** - 0.8x to 1.5x
- **Script mode** - table reads with a voice per character, and a timeline editor
- **100% local & private** - on-device inference; your text never leaves your Mac
- **Menu bar fallbacks** - "Speak Clipboard" and "Stop Speaking" for hotkey-free use
- **Start at Login** - set it once, forget it
- **Free & MIT licensed**

## Requirements

- **Apple Silicon Mac (M1 or newer)** - required; the model runs on the GPU via MLX, which has no Intel support
- macOS 15 (Sequoia) or newer
- ~270 MB disk space (the Phonon model is bundled; Kokoro is an optional 312 MB download)

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

The build fetches two checksum-pinned downloads into the gitignored `Vendor/`
folder: the Phonon 31M Core ML bundle (`scripts/vendor-phonon.sh`) and the
sherpa-onnx framework (`scripts/vendor-sherpa.sh`). Kokoro is not needed to
build; users download it from General settings.

Kokoro voice embeddings ship in `Resources/voices.npz`, converted from the
`.pt` files in the `prince-canuma/Kokoro-82M` HuggingFace repo.

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
              OratorEngine — Phonon (Core ML) by default; Kokoro (MLX),
                    │        Piper/Kitten (sherpa-onnx) optional; pipelined
                    │        chunk-by-chunk into an AVAudioPlayerNode queue
                    ▼
                 🔊 24 kHz audio
```

Built on [Phonon / xn-ptts](https://github.com/gradium-ai/xn-ptts),
[kokoro-ios](https://github.com/mlalma/kokoro-ios) (KokoroSwift),
[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx),
[mlx-swift](https://github.com/ml-explore/mlx-swift), and
[MisakiSwift](https://github.com/mlalma/MisakiSwift) G2P.

## Sibling project

[orator-chrome-extension](https://github.com/MyronKoch/orator-chrome-extension) - the browser-extension version of Orator (reads web pages with Kokoro & Supertonic engines inside Chrome).

## License

MIT © 2026 Myron Koch
