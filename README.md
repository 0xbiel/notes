# Notes

Native macOS notebooks with a source-preserving Markdown editor, local Spanish transcription, and reviewable AI note proposals. This repository contains app source and invented test fixtures only.

## Zen interface branch

The `zen-ui` branch carries the compact interface and the editor/transcription refinements from the local prototype. The library occupies the left outer frame, with native macOS window buttons in its header. Quick-open uses Command-T or Command-P; the sidebar keeps one glass search field with an icon-only text/audio/video filter. Preferences open from the gear beside + or Command-comma, with persistent system/light/dark appearance, frame palette and intensity. Compact hover uses a 12-point inset. The note and inspector sit inside an inset rounded content surface. Command-Backslash toggles the library; Option-Command-C (or Command-Option-Backslash) toggles compact mode (avoiding the macOS tab-overview shortcut). In compact mode, the library and its window controls reveal from the left edge and can be pinned. Reveals stay open during menus, editing, dragging and modal interactions, with reduced-motion and reduced-transparency accommodations.

This is an independently authored Swift/AppKit implementation of Zen Browser’s left sidebar and inset content layout. Reference: zen-browser/desktop commit `3585fef4f6a76723c00ab6571419c920eda65f4e`, especially `zen-browser-ui.css`, `zen-browser-container.css`, `compact-mode/sidebar.inc.css`, `ZenMouseTrackerCocoa.mm`, and `widget/cocoa/nsCocoaWindow-mm.patch`. The theme also references `zen-theme.css` and `zenThemeModifier.js`: accent-derived frame colors layered over native material, adapted to SwiftUI with local preferences. The custom selector adapts Zen’s `theme-picker.inc`, `ZenGradientGenerator.mjs`, and `zen-gradient-generator.css` into a native dotted canvas with up to three draggable colors, exact macOS color picking, brightness, and intensity. Preferences use the same themed sidebar, compact-mode behavior and rounded opaque content surface as notes, with General and Theme sections and a bottom-left Back to notes button. Preferences are also searchable in Command-P / Command-T quick-open. Theme changes persist locally and immediately tint the sidebar and outer frame. The top bar stays inside the note’s rounded content surface. Window controls follow Zen’s monochrome treatment in `zen-browser-ui.css`, revealing the original AppKit controls on hover. The left sidebar, inset content, inspector and edit/compact keyboard transitions were checked in the running native app. The native suite also renders light/dark layouts at 940 and 1280 points. Live resize, fullscreen transitions and VoiceOver coverage remain pending.

Use the repository checkout as the ongoing development folder. Keep `models/`, `runtime/`, `copied-course/`, `session-storage/` and the workspace manifest local and ignored by Git. With an existing workspace at the checkout root, run `zsh scripts/build-app.sh` and `zsh scripts/run.sh`; for a fresh invented workspace, use the demo instructions below.

## Editing

Choose **Editar** for inline Markdown formatting with syntax revealed around the cursor; choose **Ver** to read. Each note retains its selection, scroll position and undo history. Create notebooks, folders and notes from the sidebar; use Command-P to open a note and Command-S to save. The editor supports a Markdown subset: headings, emphasis, code, links and wiki aliases. Unsupported constructs retain their exact source. No remote embeds load.

Notes saves only inside its independent workspace. Existing drafts and concurrent edits are checked before proposal application or undo. Source Markdown is preserved; the editor changes presentation attributes rather than rewriting text. External links require the existing explicit link flow; tests never operate a browser.

## Local audio and video

Import playable audio or MP4/MOV; the source is copied and checked without modification. The app stores audio, transcript checkpoints, class date, unit/exam tags and review history locally. Playback and transcript timestamps support reviewing a passage before using it in notes.

The **Grabar** button is the only path that requests microphone permission and starts capture. Whisper recognizes Spanish locally during capture using sealed 30-second clips with two-second overlap. A continuous PCM WAV preserves the complete recording independently of recognition. Stopping capture drains the converter and processes remaining clips; explicit resume restores interrupted local work. Inputs are bounded to eight hours/8 GiB and recognition has one worker with a bounded pending window. New imports use independent 30-second windows with two-second overlap; resumed legacy imports retain their saved checkpoint layout. Decoder history is disabled by default, and each recording persists its model and decoding configuration. No microphone is started by tests or app startup.

Conflicting overlap hypotheses remain visible for review. Repeated decoder output is preserved and pauses automatic AI batching. Recognition is not a correctness guarantee: the tested real lecture was fast to process but had extensive repetition and garbled speech. Names, numbers, negations and corrections need human review. Physical microphone behavior and large-file editor performance have not been exhaustively tested.

## AI proposals and privacy

Manual sending includes selected transcript spans and at most 2,000 relevant characters from the target local note. Audio, full-note snapshots and source paths stay local. Optional automatic sending starts disabled, applies only to that recording, aims for roughly five minutes at a sentence boundary (up to 30 seconds of grace), waits up to 7.5 minutes for sparse speech, and sends dense passages earlier at bounded text/segment limits, with at most two prior spans of context, and stops on errors or suspicious ASR repetition. General preferences defaults to reviewing all changes, with optional automatic additions or edits to the linked note. Uncertain/overlapping text, unsaved drafts and conflicting edits still require review; automatic edits retain undo history.

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

For ASR, provide a compatible locally built whisper.cpp v1.8.2 executable at the workspace's `runtime/whisper-build/bin/whisper-cli` and the official multilingual Whisper small weights at `models/ggml-small.bin`. An already installed `models/ggml-large-v3-turbo.bin` is preferred for new recordings; existing recordings retain their saved configuration. Verified small-model size: 487,601,967 bytes; SHA-256: `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b`. Runtime and weights are excluded from this repository. The adapter currently validates OpenCode 1.3.13; it rejects incompatible/effectively overridden configurations. No account setup is performed by building or testing.

## Verification and repository boundaries

The combined native suite covers Markdown preservation, Unicode/composition, selection, undo/redo, list continuation, document switching, guarded proposal application, imports, cancellation, overlap handling, continuous audio, crash recovery, duration limits and resampler finalization. UI tests use invented workspaces and offscreen renders; no microphone or external inference occurs. Standard macOS AVFoundation services are required for export tests.

The source release excludes all original/copied course notes, recordings, transcripts, session data, model weights, runtime downloads, builds, QA output, logs, credentials and private local paths. Those remain in the user's workspace. Do not add personal workspace content to Git.

## Notebook workspaces

Select a notebook title to open its home; the disclosure arrow only expands its files. New notebooks start empty. The home has persistent notebook chats and a large text-assistant composer. Open documents share that chat through a smaller growing composer and a chat popover. Recording, transcription access, and notebook management live inside the composer. In View mode, the toolbar chat button hides the composer for studying; starting Edit shows it again. Global preferences remain in the sidebar.

Profiles specify purpose, instructions, formatting and sources. Explicit text requests use the enabled provider/model, search only that notebook's Markdown, and can request additional complete documents before returning unique-anchor replacements or new Markdown files. Notes applies validated changes as one transaction. Affected drafts are saved in a separate checkpoint first; typing or external changes during inference cause a conflict. Text requests authorize direct edits independently of the automatic transcription permission setting. Provider processes keep their existing tool restrictions and account configuration. OpenCode retains its zero-price, no-training, zero-retention route without fallback.

The Derecho profile resolves article references on submission. It asks for the law when context is ambiguous, retrieves the exact article from BOE's consolidated legislation API, and inserts the verified text and dated source citation through an app-expanded marker. It selects the effective version for today or an explicit historical date. Failed/mismatched sources cannot produce a legal insertion.

Checkpoints include manual saves, created files, recording-generated note edits, assistant transactions and restores. Restoring preserves current drafts and external edits first and adds another checkpoint, keeping later states available. Restore affects Markdown files, not chats, profiles or media. Older transcription proposals and editor undo entries for affected files become superseded; their history stays available. Notebook-home recording creates a dated target only after microphone permission and device startup succeed, and preserves the originally selected notebook.

Workspace-local data lives under ignored `session-storage/projects/`: per-notebook chat/profile JSON, a checkpoint index, content-addressed text blobs, and a recoverable transaction journal. No Git repository, branches, or remote synchronization is created for note history. Requests interrupted at shutdown are reported in their chat and are never automatically resubmitted.

Chat presentation independently adapts the compact user-message, Markdown reply, work-log, and changed-file patterns from [T3 Code](https://github.com/pingdotgg/t3code). Replies render headings, lists, tasks, quotes and copyable code blocks. Actual context reads, BOE lookups and transaction stages appear as they happen, with an elapsed timer and expandable saved activity. The current provider transports return a completed structured response, so this is execution-status streaming rather than token-by-token answer streaming. File cards open documents and expand their checkpoint diffs.

Theme settings include an independent single-color version of the theme picker for the Send button, checklist ticks and the small centered status line in the top margin of the content panel. Navigation and inactive recording controls stay neutral. A selected sidebar row uses the accent while the sidebar has focus, then returns to gray; the full notebook row includes its disclosure arrow. The line appears only during assistant work or recording, shows a brighter highlight gliding across a darker straight bar (static with Reduce Motion), and turns red during recording. Markdown task boxes work in both modes: Edit keeps ordinary draft/undo behavior, while View saves the checkbox change immediately through notebook checkpoints. The task action is also available in the note menu with Shift-Command-L. App-owned activity and error messages use the selected language, including older saved error messages.

Sidebar context menus create nested folders and delete Markdown documents, folders, or whole notebooks. The sidebar Trash menu restores deleted items. File deletion uses checkpoint content snapshots and preserves unsaved drafts first; restoration refuses to overwrite a newer file at the same path. Folder deletion preserves empty subfolders and refuses non-Markdown assets. Notebook deletion is a reversible local archive that retains notebook ownership, files, chats, profiles, audio and history; archived notebook files stay excluded from other notebooks and search. Trash has no permanent-empty action in this release.

### Chat attachments

Notebook and document composers accept file-picker selection, Finder drag-and-drop, and image/file paste while the prompt is focused. Attachment chips show thumbnails, sizes, removal controls, and image/PDF/text previews. Draft attachments persist locally without creating an empty chat in history. Sent attachments stay with their message and are available to follow-up requests in that chat.

Supported inputs: images (PNG, JPEG, HEIC and other ImageIO formats), PDFs, DOCX, RTF, and UTF-8 text/code files such as Markdown, CSV, JSON and source code. Originals are copied into ignored `session-storage/projects/attachments/<notebook>/<attachment>` storage. Text is extracted from documents; PDFs also supply every rendered page so scans and diagrams are visible. Images are normalized to PNG, at most 1600 pixels on the longest edge (animated images use their first frame). DOCX/RTF supply text, not embedded pictures; use PDF to preserve their page visuals.

Codex receives native image inputs; Antigravity receives ACP image blocks only when its handshake advertises image support. The existing OpenCode provider accepts text attachments and explicitly rejects image/PDF input. Files are never executed, and providers gain no additional filesystem or shell tools. Limits: 8 files per message, 20 MB per original, 24 total image/PDF pages in the conversation, 180 KB extracted text per attachment, and 32 MB of prepared images. Oversized/unsupported inputs produce an error rather than silent truncation. The ordinary request context limit also applies.
