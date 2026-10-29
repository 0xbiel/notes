# Palladium

Palladium is a native macOS notebook app for Markdown notes, AI-assisted editing, and chat dictation. It brings your documents and conversations into a calm workspace, whether you’re studying, collecting ideas, or working through a project.

![Palladium showing a study-guide table, notebook navigation, and an assistant chat with its activity log](docs/images/palladium.png)

- **Notebooks and Markdown.** Organize notes into notebooks and folders. Write and read formatted Markdown with tables, checklists, math, and images. Paste or drag pictures into notes and resize or crop them visually, with autosave and undo.
- **Notebook chats.** Work with an assistant that can use your notebook’s context, search the web, and help edit documents. Press Enter to send, or Shift+Enter to insert a new line. While a reply is running, entering a message replaces Stop with Queue. Enable “Always steer instead of queueing” in Preferences → General → Chats to interrupt with new instructions instead; both the button and Enter follow this setting. Web access starts enabled; switch it off in each notebook’s Profile settings. Attach images, PDFs, or text files when a conversation needs them.
- **Atlas.** Your whole library as a graph, like Obsidian's graph view: each notebook is a region of one colour, its subjects are clusters inside it, and every note section, PDF page and picture is a point near the places that say similar things, with lines between related places in different notebooks. Open it from the notebook home or with ⇧⌘M; drag to move around or to pull a point, scroll or pinch to zoom, pick a region to fly to it, and click any point to open that heading or document. It follows your notes as you write. It uses Google's EmbeddingGemma 2 running on your Mac (Apple silicon, a one-time download of about 880 MB); nothing is sent to a service to make it.
- **Local or API dictation.** Speak into the chat composer using a local Whisper model or the OpenAI API. Review and edit the resulting text before sending. Manage models and your API key in Preferences.
- **Your own appearance.** Choose light, dark, or system appearance, adjust the theme and accent colors, and use compact mode when you want more room for your notes.

## Download

Download an installer from [GitHub Releases](https://github.com/0xbiel/notes/releases): choose `arm64` for Apple silicon or `x86_64` for Intel, open the DMG, and drag Palladium to Applications. Requires macOS 14 or later. Installers are ad-hoc signed, not Apple notarized; macOS may require allowing the app in System Settings → Privacy & Security.

Every branch push publishes a numbered development prerelease after tests and both installer builds succeed. Stable releases use version tags. See [release instructions](docs/development.md#releases-and-versioning).

## Run locally

**Preferences → Usage** keeps a local, deduplicated usage ledger independent of chat history, so deleting chats or notebooks does not reduce recorded usage. Existing saved chats are backfilled once. When an older chat has no provider usage record, only its saved question and answer are counted as approximate tokens; its provider/model and API cost remain unknown. These estimates exclude notebook context, tool calls, retries and images. New provider-reported requests are not counted again from chat text. Usage covers Palladium only, not other sessions in provider apps, and API-price estimates are not subscription charges.

### Illustrated notes and practice tests

- Ask the notebook assistant to copy a figure from an imported PDF/image or a chat attachment into a note. PDF source reads provide visual previews alongside selectable text, including diagrams on pages that already contain text. The assistant can request a page and a normalized, top-left crop; Palladium extracts a bounded PNG locally (up to 2400 pixels), leaves the original unchanged, and inserts it using normal Markdown image references. ZIP-contained sources are supported too. External images use the existing web download flow when web access is enabled. Cropping is raster extraction, not lossless extraction of embedded vector/PDF objects. Source fingerprints reject concurrent changes. Generated assets are rolled back if output validation or applying the note edits fails.
- Ask for an **interactive practice test** based on your notes. The assistant supplies validated questions, choices, correct-answer IDs and explanations in a new `.quiz.json` file; opening it in the notebook library shows Palladium's native UI, not model-supplied HTML or styling. A Markdown study note can link to the test with an ordinary relative link.
- Choose **One at a time** (the default) for a guided question flow with **Back** and **Continue**, or **All questions** for the full sheet. Browse freely without answering first. Both views share the same answers and shuffled choices, and you can switch without restarting. The right-hand question index jumps to any question and marks answered questions; its notebook-style picker scrolls long lists and searches by question text or number. The full sheet uses one continuous scroll-progress line and renders nearby questions on demand. The last question offers **Submit answers**, enabled only after every question is answered; explanations stay hidden until submission. Reopening an unfinished test resumes at the first unanswered question in flow mode.
- The title-bar view switch matches the document Edit/View control. Quiz navigation stays at the bottom, with the floating assistant above it. Questions support reference figures via an optional `images` array of `{path, alt, caption}` objects: local paths relative to the test file, up to four per question and 24 per test. The assistant can extract/crop these figures in the same response that creates the quiz. Images must remain inside the notebook; missing or unsupported figures show a clear placeholder rather than silently disappearing.
- Answer every question, then choose **Submit answers** to see your score, the correct answers, and explanations for your selected answers. **Retake test** starts a fresh attempt with the choices reordered again. Progress and completed attempts are stored locally, separately from chat history; opening the same test resumes it. Editing a test starts a separate history keyed by the new file contents. Deleting or renaming its file does not delete old attempt storage. The answer key lives in the local test file, so this is a study tool, not a secure/proctored exam.
- Ask for **written-answer questions**, with reference images when useful, or a mix of written and multiple-choice questions. Written questions use `answerType: "text"`, empty `options`/`correctOptionID`, and a reference answer plus grading criteria in `explanation`. Drafts save as you type. **Grade answers** sends written responses, the rubric and reference figures to the selected AI model, which awards 0–10 with partial credit and explains mistakes and missing points. Feedback and the grading model are saved with the attempt; a failed request keeps answers editable for retry. Mixed quizzes average each question's score (multiple-choice answers earn 0 or 10). Illustrated grading requires an image-capable provider; OpenRouter/OpenCode currently supports text only. Existing multiple-choice quizzes continue to grade locally by stable option IDs. AI feedback is not independently verified. Question content supports the same Markdown/math presentation as chat. Common `\dfrac`, `\tfrac` and `\dots` formulas now render in notes, chat, tables and exported PDFs without changing the authored source.

Requires **macOS 14 or later**, Xcode with **Swift 6**, and **Python 3**. From the repository root:

```sh
python3 scripts/init-demo-workspace.py .local-demo
zsh scripts/build-app.sh "$PWD/.local-demo"
zsh scripts/run.sh
```

The first command creates an independent workspace with invented content; run it once on a new or empty directory. The build produces `build/Palladium.app`. Local builds use ad-hoc signing and are not notarized releases. Dictation models and the local runtime are installed separately through Preferences; API dictation requires your own key. AI chat also requires a configured provider.

## Your data

Notes and chats are stored locally. When you use an external AI provider, the content needed for that request is sent to the selected service. Web searches send the query to the search service, and page/image requests contact their source sites. API dictation sends audio to OpenAI; local dictation runs on your Mac.

See the [developer guide](docs/development.md) for architecture, testing, and workspace details.

## License

Palladium is available under the [MIT license](LICENSE). Third-party components retain their [license and copyright notices](docs/development.md#third-party-notices).
# Document output

- Markdown math uses the same native renderer in the editor and in PDF export. Use **Export PDF** in the document header, or ask the notebook assistant to export a read note into a new `output/*.pdf` file. Export includes current editor content, headings, math, tables and local images, with A4 pagination and a light print appearance.
- In a PDF preview, use **← / →** to turn pages while the PDF has focus. The toolbar’s previous/next page buttons stay visible in narrow panes; text fields keep their normal arrow-key editing.
- **Print** in the header or **⌘P** opens the macOS print dialog for Markdown, PDF, DOCX, RTF, text and supported raster images. DOCX is imported through AppKit's rich-text reader; complex Word layouts may differ from Microsoft Word. Quick Open is **⇧⌘P** (or **⌘T**).
- Choose **New LaTeX document** from the File menu or note options to create a standalone `.tex` homework document. Imported `.tex` files open in the source editor with local draft recovery, conflict-checked saving and a compiled PDF preview. Native text editing provides undo. Save the source before renaming or moving files.
- LaTeX compilation requires a local `tectonic` executable (`brew install tectonic`). Compilation runs only on explicit Compile, Export PDF or Print actions, with `--untrusted` and a 60-second timeout. Tectonic may fetch missing TeX packages; turn off **Allow missing TeX package downloads** in **Preferences → General → LaTeX** for cached-only operation. Source is compiled locally, not sent to an AI or compilation service. Multi-file projects, bibliography workflows and source-to-preview synchronization are not supported yet.
- The assistant can create `.tex` source and native Markdown PDFs in new notebook-scoped destinations, including automatic parent folders. It does not compile LaTeX or print automatically, and generated files never overwrite an existing file. Markdown edits retain the existing checkpoints; generated PDF/TeX files are library assets, not part of Markdown edit undo.
