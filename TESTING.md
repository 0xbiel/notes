# Transcription and notebook workflow checks

Run `zsh scripts/test.sh` for the offline suite. It creates independent invented workspaces and does not start the microphone or contact inference providers. Installed-model and live-generation checks skip unless explicitly enabled.

## Installed Whisper integration

Supply an invented Spanish lecture longer than 30 seconds as both `lecture.wav` and `lecture.mp4` in a dedicated fixture directory. The speech should include “dos pasos”, “no tres” and “última frase” so the tests can check corrections, negations and the final recording tail. These are fixture-specific checks, not an accuracy benchmark for real lectures.

```sh
zsh scripts/make-transcription-fixtures.sh qa/fixtures
NOTES_ASR_FIXTURES="$PWD/qa/fixtures" \
NOTES_ASR_RUNTIME="/absolute/path/to/existing/notes-runtime-workspace" \
zsh scripts/test.sh
```

The runtime workspace must already contain `runtime/whisper-build/bin/whisper-cli` and compatible model weights in `models/`. Nothing is installed or downloaded. The tests prefer an installed large-v3-turbo model, otherwise small. Each test copies its source, extracts playable audio, runs real Whisper, interrupts after one saved chunk, resumes the remaining chunks and verifies persisted transcript identities. Completed-job resume must not duplicate segments. Source bytes remain unchanged. `transcription-wav.json` and `transcription-mp4.json` are written into the fixture directory for local review; they contain only the supplied invented content.

## Live generation canary

The fixture helper requires the existing macOS Spanish Mónica voice and `ffmpeg`. It performs no download, refuses an existing destination and includes a video tail longer than the speech to exercise container-versus-audio duration handling.

```sh
NOTES_AI_DEMO=1 zsh scripts/test.sh
```

This explicitly enables an external request using only `SyntheticAIFixture`'s exact public invented text. The demo permits provider retention, denies training and requires zero prices. It never sends audio, course notes or arbitrary test transcripts. The canary verifies generation, no mutation before review, correction application and undo. Adapter/version/configuration/provider errors fail the canary rather than being reported as successful generation. The ordinary suite separately verifies proposal parsing, dirty-draft protection, apply/undo and reload without contacting a provider.

## Installed-provider diagnostics

Run `NOTES_PROVIDER_PROBES=1 zsh scripts/test.sh` to check the existing OpenCode, Codex CLI, and Antigravity ACP installations without prompts or login. No installation occurs. All three must be present and compatible; missing or incompatible runtimes fail rather than count as passes. Ordinary tests use mock ACP processes and synthetic Codex events. See `PROVIDERS.md` for the settings contract and UI-worker handoff.

## Isolation from UI work

This testing work lives on `testing/audio-video-notebooks` in a separate Git worktree. Its patch excludes UI-worker files and shared README edits; only the nonvisual AI controller connects the new core transports to the app. Latest uncommitted UI sources are snapshotted and tested together with this patch in an ignored disposable directory, never written back to the other checkout. See `PROVIDERS.md` for the compatibility-check layout. The focused importer fix in `LocalMedia.swift` uses extracted audio duration rather than a potentially longer video duration. Native interaction observations must identify the app build used; compile/offline tests do not establish a new native interactive UI pass.
