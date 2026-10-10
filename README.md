# Palladium

Palladium is a native macOS notebook app for Markdown notes, AI-assisted editing, and chat dictation. It brings your documents and conversations into a calm workspace, whether you’re studying, collecting ideas, or working through a project.

![Palladium showing a study-guide table, notebook navigation, and an assistant chat with its activity log](docs/images/palladium.png)

- **Notebooks and Markdown.** Organize notes into notebooks and folders. Write and read formatted Markdown with tables, checklists, and math, backed by autosave and undo.
- **Notebook chats.** Work with an assistant that can use your notebook’s context, suggest changes, and help edit documents. Attach images, PDFs, or text files when a conversation needs them.
- **Local or API dictation.** Speak into the chat composer using a local Whisper model or the OpenAI API. Review and edit the resulting text before sending. Manage models and your API key in Preferences.
- **Your own appearance.** Choose light, dark, or system appearance, adjust the theme and accent colors, and use compact mode when you want more room for your notes.

## Run locally

Requires **macOS 14 or later**, Xcode with **Swift 6**, and **Python 3**. From the repository root:

```sh
python3 scripts/init-demo-workspace.py .local-demo
zsh scripts/build-app.sh "$PWD/.local-demo"
zsh scripts/run.sh
```

The first command creates an independent workspace with invented content; run it once on a new or empty directory. The build produces `build/Palladium.app`. Local builds use ad-hoc signing and are not notarized releases. Dictation models and the local runtime are installed separately through Preferences; API dictation requires your own key. AI chat also requires a configured provider.

## Your data

Notes and chats are stored locally. When you use an external AI provider, the content needed for that request is sent to the selected service. API dictation sends audio to OpenAI; local dictation runs on your Mac.

See the [developer guide](docs/development.md) for architecture, testing, and workspace details.

## License

Palladium is available under the [MIT license](LICENSE). Third-party components retain their [license and copyright notices](docs/development.md#third-party-notices).
