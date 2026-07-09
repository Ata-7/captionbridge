# Changelog

## 0.2.1 — 2026-07-09

Fixes from an independent post-release review (OpenAI Codex reviewing the 0.2.0 changes):

- **Privacy:** the microphone can no longer be reopened by a device change (e.g. AirPods connecting) after subtitles are stopped, or started at all during a system-audio session.
- **Reliability:** a watchdog now monitors the Whisper helper after any timeout, so a genuinely hung helper is restarted within seconds instead of blocking captions until the next long request; the audio queue is also bounded.
- **Cancel now really cancels** model downloads — previously the transfer continued (and could install) in the background.
- **Bilingual accuracy:** finals for utterances longer than the draft window use the dual pass again, so the French and English lines always describe the same audio.
- The English draft line clears immediately when a new French draft arrives instead of briefly showing the previous sentence's translation.
- Pausing now invalidates captions still in flight, and the input-source picker is locked during a session (like the model picker).
- Turning "Instant English drafts" off also prevents the Apple language-pack preparation, not just translation.
- Model validation cache entries are bound to the expected checksum, so a future catalog update re-verifies files.
- Packaging applies hardened runtime + secure timestamp automatically when a real signing identity is provided (notarization-ready with a Developer ID).
- Added THIRD-PARTY-NOTICES.md covering bundled whisper.cpp/ggml and the Whisper models.

## 0.2.0 — 2026-07-09

Deep revision pass with Claude Code: a 10-angle automated code review, micro-benchmarks of the Whisper helper, and fixes for every confirmed finding.

### Faster captions
- **Final captions ~2× faster**: when the live French draft already exists, the final runs a single translation pass instead of transcribing + translating the same audio twice.
- **Flash attention enabled** in the Metal Whisper helper (~12% faster across the board, identical output).
- **No more mid-meeting model reloads**: timeouts no longer kill the loaded Whisper helper. A slow sentence can delay one caption; it can never force a multi-second cold model reload (the old design could spiral into repeated reloads on slower Macs).
- The model now **pre-loads when you press Start**, so the first sentence of the meeting isn't slow.
- Model integrity is verified once and cached — starting a session no longer re-hashes a 1.5 GB file every time.
- New **Medium compact (q5_0)** model option: near-Medium quality at a third of the memory — recommended for MacBook Air.

### Better caption flow
- The first French draft of each sentence appears **one inference earlier** (~0.6–1 s faster).
- Drafts continue after a long sentence is split mid-way (lowercase continuations were previously suppressed).
- Draft pacing adapts to the machine's real inference speed instead of a fixed timer.
- **Instant English drafts** (macOS 15+): the French draft line is translated on-device with Apple Translation while the speaker is still talking.
- Wider draft window (4.8 s) so the live French line covers nearly the whole sentence.
- A sentence repeated later ("Merci." … "Merci.") is no longer silently swallowed.

### Stability & correctness
- Fixed a crash path where the app could be killed by SIGPIPE if the Whisper helper died mid-request.
- Fixed a hard crash when selecting Microphone on a Mac with no input device.
- Audio chunks and caption events now flow through strictly ordered pipelines (out-of-order audio could garble transcription under load).
- Audio capture **auto-reconnects** once if macOS interrupts it, and reports a clear error otherwise (previously the app stayed "Live" with frozen captions).
- Microphone capture survives input-device changes (e.g. AirPods connecting mid-meeting).
- Pause/Resume no longer emits a stale caption from audio buffered before the pause.
- A corrupt model download can no longer end up installed; failed files are removed and re-downloaded.
- Silence no longer produces hallucinated captions ("Thanks for watching!").
- Overlay is draggable anywhere, remembers its position across launches, and keeps its position when you change its size.
- App icon added; version bumped to 0.2.0.

### Internals
- Whisper helper responses are matched by request ID and stale responses are drained, so the pipe protocol stays aligned through timeouts.
- Circular audio ring buffer (no more O(n) memmoves per chunk) and vDSP-accelerated RMS.
- Dead code removed (~150 lines of unreachable draft-presentation machinery), shared text utilities extracted, duplicated smoke-test target removed.
- New tests: model integrity/caching, ring-buffer wrap behavior, time-bounded duplicate suppression, first-draft and continuation flow. 40 tests total.

## 0.1.0 — 2026-07-03

Initial public version, built with OpenAI Codex: ScreenCaptureKit system-audio capture, whisper.cpp Metal helper, floating bilingual subtitle overlay, local-only design.
