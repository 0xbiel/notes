# Developing Palladium

Palladium is a SwiftUI/AppKit macOS application. The executable target is `Notes`; shared workspace, transcription, and provider logic lives in `LectureCore`. Internal target names, preference keys, and workspace identifiers retain their original names for compatibility.

## Build and test

Use Xcode with Swift 6, Python 3, and macOS 14 or later. Start with a separate workspace containing invented content:

```sh
python3 scripts/init-demo-workspace.py .local-demo
zsh scripts/build-app.sh "$PWD/.local-demo"
zsh scripts/run.sh
zsh scripts/test.sh
```

The initializer refuses to replace a nonempty directory. Reuse the existing workspace for subsequent builds. The build script accepts a workspace argument, then `NOTES_WORKSPACE`, then the checkout root; a workspace must contain `original-hashes.json`.

The generated app embeds its workspace path and is ad-hoc signed. It is not a portable data bundle or notarized distribution. `python3 scripts/package-app.py` packages the local app into `build/Palladium-local.zip`; its workspace is still required.

Tests use invented fixtures and cover Markdown preservation, editor state, guarded document changes, notebook transactions, attachments, dictation routing, and the audio pipeline. Standard tests do not activate the physical microphone or invoke external inference. Native UI changes also need inspection in the running app: a build or offscreen render alone does not establish interaction behavior.

## Workspace and editing

Markdown files live under the workspace’s `copied-course/` directory. Notebook definitions and local state live under `session-storage/`. Notebook chats, profiles, attachments, checkpoints, and transaction journals are stored in `session-storage/projects/`.

The editor changes presentation without rewriting unsupported Markdown. Autosave runs after a pause and when switching documents or leaving the app; Command-S saves immediately. Concurrent disk changes preserve recoverable drafts and report conflicts.

Assistant requests use the selected notebook’s context. Validated document changes are applied as a transaction, with draft checkpointing and guards against changes made while a request is running. Restores create a new checkpoint and preserve current work first. Requests interrupted at shutdown are not automatically resubmitted.

Library imports support documents and other supported files; audio/video imports are excluded. PDFs use the native viewer, while other supported files use Quick Look. Deleted library items have local recovery storage. Keep personal notes, recordings, transcripts, credentials, downloaded runtimes/models, build output, and QA workspaces out of Git.

## Providers and dictation

Web access starts enabled and is saved separately in each notebook’s Profile settings. Each submitted or queued request keeps the setting it was sent with. Codex can use native web search; all adapters, including Antigravity and OpenRouter, can request app-managed searches, public HTTPS page reads, and image downloads through the notebook JSON protocol. The search service receives the query. Disabling web access in the notebook profile disables both native search and app-managed web actions.

Web results return as untrusted source data for the assistant to cite. Requested pictures are validated and saved under the notebook's hidden `.palladium-images/` folder before the assistant references them in Markdown. PNG, JPEG, GIF, and WebP downloads have byte, dimension, and animation limits; local Markdown images render without fetching remote embeds. In Edit mode, pasting image data or dropping image files copies them into the notebook and inserts a visual object at the cursor/drop position. Select an image for corner resizing, crop-area selection, reset, copy, or removal. Size and crop are stored in a hidden Markdown comment; the original image and animated GIF bytes remain intact. Each object operation has its own undo step, and image copies within Palladium preserve their size and crop. Other Markdown viewers show the original image and ignore the presentation comment. Deleting the last reference removes the live image file. Private recovery bytes preserve undo and checkpoint restoration; images referenced by another note or draft remain available. Generated images from the previous assets folder migrate when their note opens. Provider-side image input capabilities are separate from downloading pictures into notes.

Configure AI providers and models in Preferences. Provider capabilities differ: Codex supports native image inputs, Antigravity requires image support in its ACP handshake, and the OpenCode adapter accepts text attachments while rejecting image/PDF inputs. Provider transports currently show execution progress rather than token-by-token answer streaming.

The OpenCode adapter uses a restricted zero-price OpenRouter route with no-training and zero-retention requirements for real content. It verifies effective configuration and refuses incompatible results; endpoint availability is not guaranteed and there is no automatic paid fallback. Other providers use their configured harness and account settings.

Preferences → Dictation manages local Whisper models, runtime installation, language, and an optional OpenAI API key stored in macOS Keychain. Runtime installation also requires CMake and downloads whisper.cpp; model downloads are separate from the app build. Local inference uses two CPU threads with GPU inference disabled. Audio chunks receive bounded level normalization.

Dictation writes recognized text into the originating chat draft in five-second chunks plus processing time. Manual draft edits are preserved. Stopping drains pending audio before Send becomes available; switching notebooks or chats stops capture while results remain bound to the original draft. Dictation does not send chat requests or create notes. The backend retains local capture/checkpoint files for recovery.

## Interface and branding

Appearance settings persist locally. The app uses native materials, with Liquid Glass on supported systems and accessibility/older-system fallbacks. Reading width is configurable independently of chat and PDF layouts.

Branding assets are in `Resources/Branding`. The generated artwork’s prompt is recorded in `generation.json`. Regenerate the native tile and wordmark with `swift scripts/compose-branding.swift`, then regenerate the icon with `zsh scripts/build-icon.sh`.

The README screenshot is a capture of the running native app with invented demo notes. Its source workspace is private QA data and is not part of the repository.

## Third-party notices

The following notices apply to the included third-party components:

- SwiftMath: [MIT license](../Vendor/SwiftMath/LICENSE), copyright Computer Inspirations.
- Math font resources: [MIT notice](../Vendor/SwiftMath/Sources/SwiftMath/mathFonts.bundle/LICENSE), copyright MathChat, and [GUST Font License](../Vendor/SwiftMath/Sources/SwiftMath/mathFonts.bundle/GUST-FONT-LICENSE.txt).
- Provider artwork: [MIT notice](../Resources/ProviderIcons/NOTICE.txt), copyright T3 Tools Inc.

Select sidebar documents and folders with Command-click or Shift-click. Drag them onto a folder or notebook, or use Move to from the context menu. Batch moves preserve drafts, avoid overwrites, reject descendant destinations, and rebase image references; cross-notebook moves copy referenced pictures into the destination’s hidden image folder.
