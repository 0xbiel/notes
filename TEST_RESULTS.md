# Notebook workspace validation — October 8, 2026

- Current offline suite: 126 discovered tests, 116 passed, 10 opt-in hardware/external-service tests skipped, zero failures.
- Signed native app build and `git diff --check` pass.
- New coverage includes notebook/chat/profile isolation, multi-file transactions, draft preservation, conflicts, rollback, interrupted-write recovery, historical restores and stale proposal invalidation; BOE exact/historical article fixtures; duplicate-context recovery; chat Markdown and localized saved errors; checkbox source preservation, undo, View-mode callbacks and accent round trips; recoverable file/folder/notebook deletion, restart recovery, preserved empty folders and collision refusal.
- Native checks in a separate local demo workspace verified notebook home selection, persisted profile edits, live Codex multi-file creation/editing, exact BOE Art. 13 insertion, checkpoint restoration, checkbox rendering, unified bottom composer, hide/show in View/Edit, accessible View-mode checkbox toggling and immediate save, localized saved activity, and the single-color accent field, neutral chat/voice controls with a custom-colored Send button, and an idle-hidden status indicator. The original Art. 1 request was retried successfully after fixing redundant source retrieval, creating Unit 1 with a verified BOE citation. Light/dark wide/narrow offscreen renders pass visual inspection.
- Live microphone capture and live Antigravity/OpenCode editing were not run for this feature. Provider transports currently emit execution stages, not token-by-token reply text. Earlier evidence below refers to earlier snapshots.

Local logs: `/tmp/notes-final-tests.log`, `/tmp/notes-final-build.log`. Render output remains ignored under `qa/notebook-workspaces/`.

# Merge validation — October 8, 2026

The prepared UI and provider work are committed with both branch histories retained. The merge resolves overlapping settings files to the tested combined implementation; its source tree matches the pre-merge tested source.

- Offline suite: 73 passed, 7 opt-in tests skipped, zero failures.
- Integration suite: 79 passed, one OpenCode live-generation canary skipped, zero failures (80 discovered, 47.917 seconds).
- Enabled integrations: real WAV/MP4 Whisper extraction/transcription and checkpoint resume; all three installed provider diagnostics; model catalogs; invented Codex `gpt-6-sol` and Antigravity generation, reviewed correction application, and undo.
- `gpt-6.1-sol` remains available in settings with low, medium, high, xhigh, max, and ultra. Its live canary fails because the installed Codex service explicitly rejects this model with the current ChatGPT account (HTTP 400). This is not a successful generation result; `gpt-6-sol` passes with the same transport.
- Native app packaging and code-signature verification pass. `git diff --check` passes.
- No new native interactive UI or physical microphone pass was performed during this merge. OpenCode live generation remains unverified; prior failures are recorded below.

Logs are local: `/tmp/notes-final-integration.log` and `/tmp/notes-final-build.log`. The following sections preserve earlier evidence and describe earlier snapshots, not the current integration state.

# Historical testing continuation — October 8, 2026

## Branch and scope

- Branch: `testing/audio-video-notebooks`, based on `5dcd757`.
- Worktree: `/Users/biel/Documents/notes-testing`.
- The UI worker's `zen-ui` checkout and its uncommitted source changes remain untouched.
- All media content used here is invented Spanish speech synthesized locally with macOS Mónica. No microphone capture or real lecture upload occurred.

## Automated results

Before removing the imported UI snapshot from the deliverable patch, installed Whisper integration and all three read-only provider probes passed: **73 passed, one live-generation test skipped, zero failures** (74 discovered tests, 17.262 seconds).

After isolating the patch from UI work, the backend branch's default suite passes: **67 passed, four opt-in tests skipped, zero failures** (71 discovered tests, 6.442 seconds). The count differs because the UI worker's three added tests are no longer included in this branch. Skipped checks are the two real Whisper integrations, installed-provider diagnostics and live generation.

The new tests cover:

- Actual WAV import and MP4 audio extraction with the installed large-v3-turbo model.
- Two recognition windows, interruption after the first persisted chunk, explicit recovery and completion without losing transcript identities.
- Completed-job resume without duplicated transcript segments.
- Preservation of the source files; retention of the correction “dos pasos, no tres” and the final spoken sentence.
- Notebook/folder/note creation; Unicode Markdown editing, note switching, saving, duplicate-name protection and reload.
- Deterministic proposal parsing and review, dirty-draft protection, correction application, undo and reload. This is **not** evidence of a live model generating those proposals.

## Reproduced and fixed importer defect

The MP4 container lasts **43.9 seconds**, but its extracted playable audio lasts **39.18525 seconds**. Before the fix, `prepareAudio` returned the container duration, causing the recording UI to show a longer total than the audio player could reach.

The new integration assertion failed against the original implementation (`43.9 != 39.18525`). `LocalMedia.swift` now returns the validated extracted audio duration. Both real transcription integration tests pass with the fix. Existing saved jobs are not migrated by this change.

## Native interaction observations

A separate QA app built from the initial shared-checkout snapshot was used with an independent invented workspace. The native interactions verified notebook creation, Unicode Markdown paste/save, the rendered reading view, MP4 selection/import, real Whisper transcription, correction timestamp seeking to **17.12 seconds**, playback advancement and pause. The saved Markdown source retained the exact supplied syntax despite accessibility rendering adding formatting markers.

These observations precede the isolated importer fix and do not validate the UI worker's subsequent changes. The fix itself is verified by the automated extraction/transcription regression test. Physical microphone behavior and a new-build native UI pass remain unverified.

## Provider integration and live generation limits

The original canary failed before sending because the adapter accepted only OpenCode 1.3.13. After verifying the new CLI's effective configuration and maintaining all policy/tool guards, the adapter now accepts 1.18.35 too. Two exact-invented-only canaries reached sending but failed: one with incomplete output, another at the 90-second timeout. The note remained unchanged. These failures are not successful generation evidence.

Read-only installed-runtime checks pass for OpenCode 1.18.35, Codex CLI 0.156.1 and Antigravity ACP `agy_acp_server_1.1.1`. They do not establish login, quota, model availability or generation. No Codex or Antigravity account prompt was sent. Mock transport tests cover strict response parsing, denied tool requests, unresponsive-helper cancellation, settings persistence and consent before enqueue. A reload regression also verifies that queued batches retain their original provider/model after preferences change.

An initial ACP test run exposed blocking pipe reads and a later full run exposed Foundation cross-thread exit waiting. Bounded POSIX pipe reads and termination-handler synchronization fix both; the final combined suite passes. Private helper directories are removed and invented notes remain unchanged until explicit proposal review.

The earlier zen snapshot was removed from the deliverable patch to avoid conflicts with the user's newer UI updates. A fresh read-only snapshot includes the new custom theme picker and resources. Combined-source compatibility is checked separately under `qa/latest-ui-provider-merge-check/`; this branch no longer edits visual files, UI-worker tests, build scripts or the shared README. No T3 top bar or interface is imported, and the other checkout is untouched. See `PROVIDERS.md` for the backend contract the UI worker can use.

The latest UI snapshot combined with this backend passes **70 tests, four opt-in checks skipped, zero failures** (74 discovered tests, 6.012 seconds). The complete backend-only patch passes `git apply --check` against the live dirty `zen-ui` checkout. Its UI source hashes still match the tested snapshot at the final check. This proves compatibility with that snapshot, not future concurrent edits or interactive rendering.

## Local evidence

Ignored artifacts live under `qa/continuation-2026-10-08/`: invented source fixtures, `transcription-wav.json`, `transcription-mp4.json` and copied test logs. `scripts/make-transcription-fixtures.sh` recreates the invented fixtures without replacing an existing directory. See `TESTING.md` for opt-in commands and privacy boundaries.

Provider research and final logs live under ignored `qa/provider-research/`. The final original-file check verifies all 13 original course files unchanged, with no added files or symlinks. `git diff --check` passes. No commit or installation was made.

## Real recording / GPT-6 Luna fast-mode check — 2026-10-08

An explicitly supplied 35m36s M4A was imported and fully transcribed through the existing local large-v3-turbo path: 72 checkpoints and 245 timestamped segments. The source and copied-source digest checks passed; resuming the completed job preserved the transcript. Private evidence remains under `.private-tests/recording-33/` and is not part of this repository.

Six live Codex CLI requests used `gpt-6-luna`, low reasoning, and explicit `service_tier="fast"`. The first three beginning/middle/end samples returned only asides or uncertain proposals, so the edit assertion correctly failed. A second run reused the completed transcript and sampled substantive groups across the lecture: three requests generated four eligible additions. Generation left the file untouched, applying proposals changed the isolated note, history reloaded exactly, and undo restored the initial note. The live retry passed in 34.55 seconds. The completion stream does not prove which service tier was served.

**Quality finding:** successful mechanics do not imply usable notes. Repeated “Gracias” fragments and distorted Spanish remained despite no repetition warning. Luna flagged many fragments as uncertain, but also converted an ambiguous hazardous-work fragment into an unsupported applicability statement. These outputs are test evidence, not validated study notes. The full recording was transcribed; only six small transcript groups were sent. No interactive native UI or audio-ground-truth accuracy assessment was performed.

## Adaptive five-minute batching — 2026-10-08

The same 245-segment recording now forms seven complete batches: 300, 302, 302, 302, 332, 300 and 248 seconds. Sizes range from 1,142 to 1,913 transcript characters and 29 to 41 segments. All segments were retained exactly once. Offline suite: 86 tests, 9 opt-in checks skipped, no failures; the separate real-transcript batching check also passed. The cadence follows transcript time, with sentence-boundary grace and earlier size-based flushing for denser speech.

A live larger-batch run initially rejected an incomplete model response (unclassified segment IDs). The payload now explicitly requires coverage of every ID, including asides/repetitions, and encourages grouping related IDs. The strict coverage validator remains enabled. Retesting three larger batches using GPT-6 Luna with fast mode requested passed in 55.49 seconds: 75 decisions, 14 applied edits, persisted history verified, all edits undone, source unchanged. This is a successful sample, not a guarantee that future model responses will cover every segment. Evidence: ignored `.private-tests/adaptive-33/`. Final offline suite again passed (86 tests, 9 skipped).

## General AI preferences and visual selector — 2026-10-08

General settings now combines a visual cross-provider model popover, capability-driven thinking/fast controls and editing autonomy. The native isolated Notes build was inspected with the supplied screenshot as the design reference. The popover rendered provider icons, search, cross-provider favorites, selected highlighting and model/provider labels; live catalogs populated Codex, OpenCode and Antigravity. No T3 computer-use interaction was used after the user prohibited it.

Automatic editing tests cover additions, correction permission, legacy review-only behavior, queued permission escalation protection, current permission reductions, dirty drafts, stale notes, uncertain/overlapping ASR, editor refresh, persisted history and undo. Catalog tests cover advertised fast capability and backward-compatible settings. The final suite passed 90 tests with 9 opt-in skips and no failures, including provider-order changes and cross-provider favorite/autonomy persistence checks.

## Connection button and compact option menus — 2026-10-08

The real connection probe passed with GPT-6 Luna, low reasoning and fast mode in the integration suite (91 tests, 9 skipped, no failures). Clicking **Test connection** in the isolated native Notes app also completed successfully in 10.1 seconds and displayed its green model-specific result. The fixture uses no personal notes and does not enable account sending or alter the normal outbox. Failure/stale-result behavior is covered by preferences tests. Reasoning, speed, autonomy and language share the supplied compact menu style; native inspection confirmed selection highlighting and the catalog-derived Medium default badge. A slow catalog load does not block testing the saved model configuration.

The connection test now sends a fixed 46-byte acknowledgement prompt instead of the note fixture, with minimal instructions and a tiny JSON schema. The live GPT-6 Luna low/fast probe passed in 7.647 seconds; provider startup and inference still contribute latency. The suite completed with 92 tests, 9 skipped and no failures, and the Notes app build succeeded. No notes or outbox entries are created.

Provider availability now defaults to enabled for new settings, preserves saved opt-outs, hides disabled providers from model choices and checks current provider enablement before queued sends. General exposes individual provider switches and places editing permissions to the right of the model. The offline suite passed with 92 tests, 10 skipped, zero failures after updating the opt-out regression tests.

## Chat attachments — 2026-10-08

- `scripts/test.sh`: 136 tests, 125 passed, 11 opt-in skipped, no failures. Coverage includes image/PDF preparation, exact text copies, unsupported/oversized inputs, notebook isolation, attachment-only sends, persisted drafts, pasted images/files, removal, ACP capability rejection and image payloads, and fenced JSON responses.
- Live Antigravity image test: invented red-circle PNG correctly described as a red circle, with no edits; the live-enabled suite passed (135 tests, 10 skipped at that point).
- Native app: paperclip imports an invented PNG, thumbnail opens a full image preview, and removal works. File-picker interaction exposed SwiftUI paste-command interference; replaced with a composer-focused AppKit paste handler. Clipboard data paths are regression-tested. Finder drag and drop, native PDF preview, and live Codex vision have not been separately exercised.
