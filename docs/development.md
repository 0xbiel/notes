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

Web access starts enabled and is saved separately in each notebook’s Profile settings. Web actions are not rationed per request; a run ends when the assistant answers or the user stops it. The `downloadFile` action saves a document such as a PDF (any size; no audio, video or programs) into a notebook folder through the file library, after which the assistant reads it with `readFiles`. A source longer than 180,000 bytes of text arrives with its beginning and its page count; the assistant reads the rest by adding `#pages=A-B` or `#find=words` to the path. Web and mail links in notes open in the default app. Each submitted or queued request keeps the setting it was sent with. Codex and Claude can use native web search; all adapters, including Antigravity and OpenRouter, can request app-managed searches, public HTTPS page reads, and image downloads through the notebook JSON protocol. The search service receives the query. Disabling web access in the notebook profile disables both native search and app-managed web actions.

Web results return as untrusted source data for the assistant to cite. Requested pictures are validated and saved under the notebook's hidden `.palladium-images/` folder before the assistant references them in Markdown. PNG, JPEG, GIF, and WebP downloads have byte, dimension, and animation limits; local Markdown images render without fetching remote embeds. In Edit mode, pasting image data or dropping image files copies them into the notebook and inserts a visual object at the cursor/drop position. Select an image for corner resizing, crop-area selection, reset, copy, or removal. Size and crop are stored in a hidden Markdown comment; the original image and animated GIF bytes remain intact. Each object operation has its own undo step, and image copies within Palladium preserve their size and crop. Other Markdown viewers show the original image and ignore the presentation comment. Deleting the last reference removes the live image file. Private recovery bytes preserve undo and checkpoint restoration; images referenced by another note or draft remain available. Generated images from the previous assets folder migrate when their note opens. Provider-side image input capabilities are separate from downloading pictures into notes.

Configure AI providers and models in Preferences. Each provider has its own installation, account, environment-variable and model settings there. Provider capabilities differ: Codex and Claude support native image inputs, Antigravity requires image support in its ACP handshake, and the OpenCode adapter accepts text attachments while rejecting image/PDF inputs. Provider transports currently show execution progress rather than token-by-token answer streaming.

The OpenCode adapter uses a restricted zero-price OpenRouter route with no-training and zero-retention requirements for real content. It verifies effective configuration and refuses incompatible results; endpoint availability is not guaranteed and there is no automatic paid fallback. Other providers use their configured harness and account settings.

Preferences → Dictation manages local Whisper models, runtime installation, language, and an optional OpenAI API key stored in macOS Keychain. Runtime installation also requires CMake and downloads whisper.cpp; model downloads are separate from the app build. Local inference uses the GPU through Metal by default (four threads); turning Use the GPU off returns to two CPU threads. A failed GPU run repeats on the CPU. Model downloads show a progress bar with bytes received. Audio chunks receive bounded level normalization.

Dictation writes recognized text into the originating chat draft one phrase at a time. `VoiceSegmenter` cuts the microphone stream at the speaker's pauses, so recognition clips never overlap and silence is never transcribed; a word or two waits to join the next phrase, and unbroken speech is cut at 28 seconds. With Stop when you stop speaking on, capture ends after 2.5 seconds of silence following speech, or after 10 seconds if nothing was said. Manual draft edits are preserved. Stopping drains pending audio before Send becomes available; switching notebooks or chats stops capture while results remain bound to the original draft. Dictation does not send chat requests or create notes. The backend retains local capture/checkpoint files for recovery.

## Atlas

`NotebookMapScanner` cuts a notebook into places: a note at its headings of the first three levels, a PDF into pages (a page with little text is read as a picture), and library pictures. `NotebookMapIndexer` embeds them with EmbeddingGemma 2 and keeps the vectors, cut to 256 dimensions, in `session-storage/maps/<notebook>/index.plist`. A file whose size and date are unchanged is not read again, and inside a changed note only the sections whose text changed are embedded, so an unchanged notebook never starts the model. `NotebookMapBuilder` then finds subjects with Ward's hierarchical clustering, which is deterministic and leaves the rest of the tree alone when one corner of the notebook changes. A topic is named by the folder it holds most of, by its file, by both files when it joins two, or otherwise by the file name or heading whose own vector lies nearest the topic. Pictures shown in a note stay beside their section without a vector of their own; loose pictures and scanned pages join the topic nearest to them. For the atlas a notebook may split into as few as two subjects when it is small (under 24 places). No language model names the topics yet.

`NotebookAtlasBuilder` lays every notebook out on a plane: each notebook is a region (a single notebook is split into regions by its subjects instead), each subject a disc of points inside it. Regions and subjects are first placed along the two principal directions of their mean vectors, then drawn together and pushed apart until none overlaps; a subject's points take their direction from its own principal components and their distance from the middle by rank, so the disc is evenly full. The layout is deterministic, and a rebuilt atlas is mirrored or turned by quarter turns to face the way the saved one did, for each region and for the whole. Each place is linked to its two most alike places, and the closest pairs across regions are linked too, compared after removing the mean vector of the library. The atlas is saved at `session-storage/maps/atlas.json` and made again only when an index changed or a notebook was added, removed or renamed. `NotebookAtlasGraphView` draws it as a flat graph with Core Graphics, like Obsidian's graph view: dragging the background pans, dragging a point pulls it and its neighbours, the wheel or a pinch zooms, and names fade in as you zoom. A small force simulation (links, short-range pushing through a grid, a weak pull back to the atlas position) runs on a display link only while points move, so a still graph does no work.

The model runs through a prebuilt llama.cpp server (`NotebookEmbeddingServer`), started on demand on a free local port with a per-launch key and stopped after 90 seconds without requests; the picture encoders are loaded only when a picture has to be embedded. The runtime archive and both GGUF files are pinned by URL revision and SHA-256 in `NotebookEmbeddingRuntime` and installed under the workspace's `embedding/` folder; moving to a newer build means updating those values together. Once the atlas has been opened, the library is read again 20 seconds after any notebook's notes or files change, unless "Update when notes change" is off in the atlas menu.

`NotebookMapTests` and `NotebookAtlasViewTests` use an embedder that needs no model. Set `PALLADIUM_EMBEDDING_ROOT` and `PALLADIUM_MAP_WORKSPACE` to map a real workspace with an installed model, `NOTES_MAP_SCREENSHOT` to render its atlas, and `PALLADIUM_EMBEDDING_INSTALL` to exercise the download.

## Interface and branding

### Assistant conversation context

Saved chats retain their full messages, activities and checkpoints. Stateless prompts and native-session bootstrap use a separate projection: only message content, file references and attachments, with a 32,000-byte JSON history budget. The current user request (including an internal continuation's original request) is always intact, even when it exceeds that budget. The latest assistant reply and first user request are prioritized, followed by recent intact messages. This is budgeted history selection, not an LLM-generated summary; it adds no summarization request or provider cost. Source documents, images and protocol instructions are separate from the history budget.

The assistant can recover omitted messages using `readFiles: ["@conversation#INDEX:OFFSET"]`. Indices are zero-based and offsets count Unicode characters. Each page supplies up to 4,000 characters and a next cursor; retrieved pages have a separate 32,000-byte budget, evicting oldest pages first (the newest page is always kept). History is read-only and deletion authorization still checks the original full conversation. Tests cover the prompt budget, oversized current requests, Unicode pagination, invalid cursors, unchanged saved history and controller retrieval.

Reference: [T3 Code on GitHub](https://github.com/pingdotgg/t3code/tree/7ac952c630ef8a60d14ca8f6a0c7adce33db4bae), especially `ContextWindowMeter.tsx`, `MessagesTimeline.tsx`, `ClaudeAdapterV2.ts`, and `CodexAdapterV2.ts`.

Claude and Codex notebook chats retain native provider sessions across helper launches. Sessions are isolated by workspace, notebook, chat, provider configuration, language and web policy. Claude uses `--session-id` followed by `--resume`; its compact launch omits `--disable-slash-commands` (which also blocks the built-in command) while retaining safe mode; Codex uses non-ephemeral `thread/start` followed by `thread/resume`. New turns send new messages and changed sources instead of replaying full history. Provider tools remain restricted; document edits still require app validation and checkpoints. Other generation tasks remain ephemeral.

The context ring displays provider-reported current tokens and a context limit when available. Compact invokes Claude's built-in `/compact` or Codex `thread/compact/start` and requires a confirmed compaction event. Missing post-compaction usage is shown as unknown. Native automatic compaction remains provider-owned. The UI shows compaction separately from chat replies. `/compact` and `/context` are local shortcuts, never appended as messages; button actions preserve drafts and attachments. Messages queue behind compaction, and failed compaction holds the queue for explicit recovery.

Providers without native session support retain the bounded local history selector: 32,000 serialized bytes normally and 8,000 after manual compaction. This selects intact messages, with archive recovery through `@conversation#INDEX:OFFSET`; it is not a semantic summary or a provider token count. Legacy command receipts are hidden and excluded from instructions and deletion authorization.


Appearance settings persist locally. The app uses native materials, with Liquid Glass on supported systems and accessibility/older-system fallbacks. Reading width is configurable independently of chat and PDF layouts.

Branding assets are in `Resources/Branding`. The generated artwork’s prompt is recorded in `generation.json`. Regenerate the native tile and wordmark with `swift scripts/compose-branding.swift`, then regenerate the icon with `zsh scripts/build-icon.sh`.

The README screenshot is a capture of the running native app with invented demo notes. Its source workspace is private QA data and is not part of the repository.

## Third-party notices

The following notices apply to the included third-party components:

- SwiftMath: [MIT license](../Vendor/SwiftMath/LICENSE), copyright Computer Inspirations.
- Math font resources: [MIT notice](../Vendor/SwiftMath/Sources/SwiftMath/mathFonts.bundle/LICENSE), copyright MathChat, and [GUST Font License](../Vendor/SwiftMath/Sources/SwiftMath/mathFonts.bundle/GUST-FONT-LICENSE.txt).
- Provider artwork: [MIT notice](../Resources/ProviderIcons/NOTICE.txt), copyright T3 Tools Inc.

Select sidebar documents and folders with Command-click or Shift-click; a group only selects and leaves the open document as it is. Dragging from the space beside a name (or from the empty area below the rows) sweeps a marquee that selects every row it crosses; dragging from a name or icon moves. Drag them onto a folder or notebook, or onto any document inside one, or use Move to from the context menu. The destination is outlined while dragging, a collapsed folder opens when the pointer rests on it, and Escape cancels. One pointer controller on the sidebar outline (`NotebookLibraryDragDrop.swift`) owns row clicks and drags; `LibraryPointerTests` drives it against the real sidebar view. Batch moves preserve drafts, avoid overwrites, reject descendant destinations, and rebase image references; cross-notebook moves copy referenced pictures into the destination’s hidden image folder.
