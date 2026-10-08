# Testing continuation — October 8, 2026

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
