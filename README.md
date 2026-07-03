# CaptionBridge

CaptionBridge is a privacy-first macOS live subtitle translation MVP for French-to-English meeting audio.

It was built around a practical workflow need: helping a user follow French conversations in English while keeping audio processing local by default.

## What It Does

- Captures meeting audio from system audio on macOS 14+.
- Provides a microphone fallback when system audio capture is not available.
- Uses a local Whisper-based helper for transcription and translation.
- Displays captions in a floating overlay designed for fullscreen meeting apps.
- Keeps the default workflow local: no saved transcript, no analytics, no cloud inference, and no raw audio persistence by default.

## Why I Built It

I built CaptionBridge as a practical AI-enabled workflow project. My focus was not to create a commercial product, but to understand how real AI tools move from a user problem into requirements, product decisions, privacy trade-offs, testing, and a usable prototype.

## Current MVP Status

The MVP currently supports French meeting audio to English subtitles. It includes native macOS controls, a floating subtitle overlay, local model management, caption stabilisation, and test coverage for core privacy, audio, and caption-processing behaviours.

## Tech Stack

- Swift and SwiftUI
- AppKit overlay window
- ScreenCaptureKit
- AVAudioEngine
- Swift Package Manager
- Local Whisper helper based on whisper.cpp

## Local Development

```sh
swift test
swift build
```

Build a local app bundle:

```sh
Scripts/package-app.sh
```

Create a local DMG for manual testing:

```sh
Scripts/create-dmg.sh
```

## Privacy Notes

CaptionBridge is designed with local-first defaults. The app does not save transcripts, does not persist raw audio, does not include analytics, and does not use cloud inference by default.

This is an MVP, not a production-certified privacy or security product.

## Tests

The project includes tests for privacy defaults, audio processing, caption stabilisation, subtitle history, model/helper lookup, and live subtitle coordination.

## Limitations

- MVP language flow is French to English.
- macOS 14+ is required for system audio capture.
- Local model quality and latency depend on the selected model and hardware.
- Distribution is currently suitable for local/manual testing, not notarised production release.

## AI-Assisted Development

This project was built with Codex-assisted development. I owned the problem definition, requirements, product decisions, testing, and iteration, using AI assistance to accelerate implementation and deepen my practical understanding of AI-enabled software workflows.
