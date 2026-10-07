# Notes

Native macOS notebooks with a source-preserving Markdown editor, local Spanish transcription, and reviewable AI note proposals. This repository contains app source and invented test fixtures only.

## Editing

Choose **Editar** for inline Markdown formatting with syntax revealed around the cursor; choose **Ver** to read. Each note retains its selection, scroll position and undo history. Create notebooks, folders and notes from the sidebar; use Command-P to open a note and Command-S to save. The editor supports a Markdown subset: headings, emphasis, code, links and wiki aliases. Unsupported constructs retain their exact source. No remote embeds load.

Notes saves only inside its independent workspace. Existing drafts and concurrent edits are checked before proposal application or undo. Source Markdown is preserved; the editor changes presentation attributes rather than rewriting text. External links require the existing explicit link flow; tests never operate a browser.

## Local audio and video

Import playable audio or MP4/MOV; the source is copied and checked without modification. The app stores audio, transcript checkpoints, class date, unit/exam tags and review history locally. Playback and transcript timestamps support reviewing a passage before using it in notes.

The **Grabar** button is the only path that requests microphone permission and starts capture. Whisper recognizes Spanish locally during capture using sealed 30-second clips with two-second overlap. A continuous PCM WAV preserves the complete recording independently of recognition. Stopping capture drains the converter and processes remaining clips; explicit resume restores interrupted local work. Inputs are bounded to eight hours/8 GiB and recognition has one worker with a bounded pending window. Imported media uses five-minute checkpoints. No microphone is started by tests or app startup.

Conflicting overlap hypotheses remain visible for review. Repeated decoder output is preserved and pauses automatic AI batching. Recognition is not a correctness guarantee: the tested real lecture was fast to process but had extensive repetition and garbled speech. Names, numbers, negations and corrections need human review. Physical microphone behavior and large-file editor performance have not been exhaustively tested.

## AI proposals and privacy

Manual sending includes selected transcript spans and at most 2,000 relevant characters from the target local note. Audio, full-note snapshots and source paths stay local. Optional automatic sending starts disabled, applies only to that recording, groups roughly 45 seconds/120 words with at most two prior spans of context, and stops on errors or suspicious ASR repetition. All note changes still require review.

The OpenCode adapter pins OpenRouter's free router as the main and small model, disables auxiliary agents and all tools/MCP/sharing, verifies the final effective configuration, and rejects API errors, tool calls, nonzero/missing costs and malformed decisions. Existing OpenCode authorization is used in place; Notes does not create or read out credentials. Router-selected downstream models can vary.

Real content requires `data_collection: deny`, `zdr: true`, no provider fallback and zero-price limits. The saved private-profile test found no eligible endpoint under those requirements; real external AI is therefore not established as available. There is no automatic paid or alternate-provider fallback.

**Crear demo IA inventada** creates exact fabricated text and a separate note. Only that fixed fixture may use the retention-permitted demo profile (`zdr: false`), while still requesting no training and zero prices. That demo completed a validated zero-cost request. Renaming a real recording or calling it a demo does not grant this exception. Notes does not alter account privacy settings.

Proposals distinguish additions, corrections, retractions, omissions, asides, priority and ambiguity. Review the source and diff before applying. Corrections require a unique exact target quote; drafts and stale snapshots block changes. Undo is available through the edit history. Lecturer directives remain fallible interpretation and must not be treated as permission to execute commands.

## Build a separate demo workspace

Requires macOS 14 or later, installed Xcode/Swift 6 and Python 3. Liquid Glass is used on macOS 26+ with an opaque accessibility/older-system fallback. No dependencies or models are downloaded by these scripts.

```sh
python3 scripts/init-demo-workspace.py .local-demo
NOTES_WORKSPACE="$PWD/.local-demo" zsh scripts/build-app.sh
python3 scripts/package-app.py
zsh scripts/test.sh
```

The initializer refuses to replace existing workspace files. `build/Notes.app` and `build/Notes-local.zip` are local ad-hoc signed builds, not notarized distributions. The generated bundle embeds its workspace path; the ZIP requires that workspace and is not a standalone portable data bundle. To launch your local build, use `zsh scripts/run.sh`. Do not run an investigative test against a real workspace unless you intend that local operation.

For ASR, provide a compatible locally built whisper.cpp v1.8.2 executable at the workspace's `runtime/whisper-build/bin/whisper-cli` and the official multilingual Whisper small weights at `models/ggml-small.bin`. Verified small-model size: 487,601,967 bytes; SHA-256: `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b`. Runtime and weights are excluded from this repository. The adapter currently validates OpenCode 1.3.13; it rejects incompatible/effectively overridden configurations. No account setup is performed by building or testing.

## Verification and repository boundaries

The combined native suite covers Markdown preservation, Unicode/composition, selection, undo/redo, list continuation, document switching, guarded proposal application, imports, cancellation, overlap handling, continuous audio, crash recovery, duration limits and resampler finalization. UI tests use invented workspaces and offscreen renders; no microphone or external inference occurs. Standard macOS AVFoundation services are required for export tests.

The source release excludes all original/copied course notes, recordings, transcripts, session data, model weights, runtime downloads, builds, QA output, logs, credentials and private local paths. Those remain in the user's workspace. Do not add personal workspace content to Git.
