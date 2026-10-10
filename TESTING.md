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

Run `NOTES_PROVIDER_PROBES=1 zsh scripts/test.sh` to check the existing OpenCode, Codex CLI, Claude Code, and Antigravity ACP installations without prompts or login. No installation occurs. All four must be present and compatible; missing or incompatible runtimes fail rather than count as passes. Ordinary tests use mock ACP and Claude CLI processes and synthetic Codex events. See `PROVIDERS.md` for the settings contract and UI-worker handoff.

## Account generation and model catalogs

`NOTES_MODEL_PROBES=1 zsh scripts/test.sh` queries installed provider catalogs. `NOTES_ACCOUNT_AI_DEMO=codexCLI,claudeCode,antigravity zsh scripts/test.sh` sends only invented fixture text through existing accounts and checks generation, review/apply, and undo. `NOTES_LIVE_CLAUDE_TEST=1` with `--filter ClaudeProviderTests/testLiveClaude` sends the connection probe and one invented notebook prompt through the installed Claude Code account, using Haiku 5.5 unless `NOTES_CLAUDE_TEST_MODEL` names another model. Set `NOTES_CODEX_DEMO_MODEL=gpt-6.1-sol` to check that model explicitly.

## Integration scope

The prepared zen-ui interface and provider settings are integrated in the same source tree. Tests use isolated invented workspaces. The importer uses extracted audio duration rather than a potentially longer video duration. Compile and automated checks do not establish physical microphone or native interactive UI coverage.

## Opt-in real recording check

`RealRecordingIntegrationTests` requires all four environment variables: `NOTES_REAL_AUDIO` (absolute source path), `NOTES_ASR_RUNTIME` (existing Whisper workspace), `NOTES_REAL_OUTPUT` (new isolated output directory), and `NOTES_REAL_CODEX_SEND=1` (explicit authorization to send real transcript excerpts through the existing Codex account). Run with `swift test --build-system native --disable-sandbox --scratch-path .build-native --filter RealRecordingIntegrationTests`.

It transcribes the complete recording locally, persists resumable checkpoints, verifies the source copy and completed-job resume, then sends beginning/middle/end transcript groups to `gpt-6-luna` with low reasoning and fast mode requested. It verifies no note writes during generation, applies eligible proposals to a separate test note, reloads history and undoes the edits. Local `transcript.txt`, `edited-note.md`, outbox records and `result.txt` remain in the output directory. Use `.private-tests/` to keep real content out of Git. This checks the core integration; it is not an audio accuracy benchmark or interactive UI test. Fast mode is requested explicitly; the completion stream does not confirm the actual served tier.

## Adaptive automatic batches

Automatic generation targets five minutes of transcript, with up to 30 seconds to reach a sentence ending. Fewer than 100 words can accumulate for up to 450 seconds. Dense speech flushes earlier at 1,800 words, 10,000 transcript characters, or 128 segments; enqueue retains a hard 12,000-character cap. Each segment remains intact, and completion flushes the final partial batch. These are transcript-time thresholds, not wall-clock timers while recording is silent or paused. Existing review/apply behavior is unchanged.

`AdaptiveBatchingTests` covers incremental delivery, sentence grace, sparse speech, dense text, segment limits and lossless final flushing. Optionally set `NOTES_BATCHING_JOB` to an existing local media-job JSON to inspect actual batch sizes without invoking a provider.

`NOTES_CONNECTION_PROBE=1 swift test --build-system native --disable-sandbox --scratch-path .build-native --filter GenerationIntegrationTests/testLiveConnectionProbeWithSelectedModel` checks the same disposable connection probe used by General preferences with GPT-6 Luna, low reasoning and fast mode. Only a fixed 46-byte acknowledgement prompt is sent, through the existing Codex account. Offline preferences tests cover failed probes, unchanged outbox and hiding stale results after a model change.

## Notebook media and imported-source previews

Audio and video filters keep the notebook outline and nested imported-file folders, and list transcription jobs under their owning notebook. `RefinementTests` checks imported formats, original-video classification, notebook ownership and tag search. Native QA uses invented WAV/MP4 files in two separate notebooks.

`NotebookAssistantTests` checks preview composer visibility, selected-source retrieval through a mocked provider, and PDF/DOCX render snapshots in `qa/imported-previews`. Imported previews share the floating composer and chat toggle with Markdown; only the rounded composer has a background. Native QA also checks hiding/restoring the PDF composer and opening DOCX chat history. These checks do not send documents to an external provider.

Provider generation permits up to ten minutes per helper invocation; CLI metadata/configuration diagnostics keep their 90-second limit. `ProviderTests` exercises an accelerated real process deadline and verifies timeout termination separately from explicit cancellation. A multi-step notebook request can make several provider invocations. This is a local deadline test, not a ten-minute live-provider generation test.

## New-note destination and section hover labels

New-note and new-folder sheets use the notebook input styling. Choose a notebook, then browse the folder picker: click a folder to enter it, use Back to visit its parent, and confirm with Use this folder. The picker supports empty folders and arbitrarily nested existing folders; changing notebooks resets the destination to that notebook's root. `NotebookWorkflowTests/testNewNoteDestinationIsExplicitAndConfinedToChosenNotebook` checks cross-notebook creation, nested and root destinations, collisions and invalid destinations. Native QA checks folder entry, Back, destination confirmation and creation in an invented nested folder. Profile Save uses the same accent action style as Create.

Section hover labels render outside the overview scroll area and clamp their vertical position to the rail edges. `MarkdownSectionTests` checks top/bottom placement and saves rendered first/last long-heading labels to `qa/section-hover`. These snapshots verify label layout without relying on synthetic mouse hover delivery.

### Demo removal

- The app no longer offers fictional AI demos, synthetic-session creation, or replay controls in menus or inspectors, and opening a workspace no longer generates a synthetic session.
- Fictional AI creation helpers live in `Tests/NotesUITests/DemoTestFixtures.swift`; existing stored data is preserved. Real recordings, transcript review, and editor history work without a replay session.
- `NotebookWorkflowTests.testOpeningWorkspaceDoesNotCreateSyntheticSession` checks startup leaves session storage empty and note edits still save into version history.

### Notebook order

- The sidebar offers manual, alphabetical and latest-modified sorting, persisted per workspace in `notebook-order.json`.
- Notebook reordering uses a local pointer monitor with a five-point drag threshold. It consumes the header press, motion and release; only release updates the saved order. There is no notebook pasteboard payload, DropDelegate, native drag session, or replacement outline delegate/data source.
- A single accent insertion line uses native row geometry and places a notebook after the target's entire expanded subtree. Escape, leaving the sidebar, and window deactivation cancel. Disclosure arrows, contextual menus, file imports and keyboard navigation retain their normal handlers.
- `NotebookPointerReorderTests` checks click/drag separation, repeated release transactions, upward/downward movement, expanded boundaries, cancellation and one commit per gesture. `NotebookWorkflowTests.testNotebookOrderingPersistenceAndModificationDates` checks saved order, sort modes and unchanged file contents. `RefinementTests.testSidebarSelectionSurvivesResizeAndRowReuse` checks stable selection and eight-point side margins.
- Live pointer QA on the rebuilt app moved IPC from third position to immediately below Derecho; all notebook rows remained collapsed. Further reverse-drag automation was blocked by the computer-use service reporting `noWindowsAvailable`, despite accessibility reads still returning the window. Repeated live pointer and autoscroll QA remain unverified.
