import SwiftUI
import LectureCore

struct NotebookCustomizationManagement: View {
    @ObservedObject var model: Workbench
    @ObservedObject var assistant: NotebookAssistantController
    let notebook: Notebook
    var skills = false
    @State private var selectedSkill = ""
    @State private var skillName = ""
    @State private var drafts: [String: String] = [:]
    @State private var bases: [String: String] = [:]
    @State private var loaded: Set<String> = []
    @State private var request = ""
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    @AppStorage("notes.language") private var language = "es"
    private func t(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    private var path: String { skills ? selectedSkill : NotebookCustomization.agentPath(notebook) }
    private var skillPaths: [String] {
        Array(Set(model.notes.filter { NotebookCustomization.isSkill($0, notebook: notebook) })
            .union(loaded.filter { NotebookCustomization.isSkill($0, notebook: notebook) })).sorted()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(skills
                ? t("Procedimientos reutilizables solo para este cuaderno. Por ejemplo, una skill de asientos contables en Contabilidad.", "Reusable procedures for this notebook only. For example, an accounting-entry skill in Contabilidad.")
                : t("AGENTS.md define cómo trabaja el asistente en este cuaderno. Puedes editarlo o pedirle al asistente que lo actualice.", "AGENTS.md defines how the assistant works in this notebook. Edit it here or ask the assistant to update it."))
                .font(.callout).foregroundStyle(.secondary)
            if skills {
                if !skillPaths.isEmpty {
                    Picker(t("Skill", "Skill"), selection: $selectedSkill) {
                        Text(t("Selecciona una skill", "Choose a skill")).tag("")
                        ForEach(skillPaths, id: \.self) { value in Text(skillTitle(value)).tag(value) }
                    }.accessibilityIdentifier("notebook.skills.selection")
                }
                HStack {
                    TextField(t("Nombre de la skill, p. ej. asientos-contables", "Skill name, e.g. accounting-entries"), text: $skillName)
                        .textFieldStyle(.plain).padding(10).modifier(NotebookInputSurface())
                        .accessibilityIdentifier("notebook.skills.name")
                    Button(t("Añadir skill", "Add skill")) { addSkill() }
                        .disabled(skillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("notebook.skills.add")
                }
            }
            if !path.isEmpty {
                Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                TextEditor(text: Binding(get: { drafts[path] ?? "" }, set: { drafts[path] = $0 }))
                    .font(.system(size: 13, design: .monospaced)).scrollContentBackground(.hidden)
                    .padding(8).frame(minHeight: 150).modifier(NotebookInputSurface())
                    .accessibilityLabel(skills ? "SKILL.md" : "AGENTS.md")
                    .accessibilityIdentifier("notebook.customization.editor")
                HStack {
                    Text(t("Los cambios se guardan en el historial del cuaderno.", "Changes are saved in notebook history."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(t("Guardar", "Save")) { _ = save() }
                        .disabled(drafts[path] == bases[path] || (drafts[path] ?? "").isEmpty || assistant.isRunning(notebook))
                        .accessibilityIdentifier("notebook.customization.save")
                }
                Divider()
                TextField(skills ? t("Pide al asistente que cree o mejore esta skill…", "Ask the assistant to create or improve this skill…")
                          : t("¿Cómo debe trabajar el asistente aquí?", "How should the assistant work here?"), text: $request, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...4).padding(12).modifier(NotebookInputSurface())
                    .accessibilityIdentifier("notebook.customization.request")
                Button { askAssistant() } label: {
                    Label(t("Actualizar con el asistente", "Update with assistant"), systemImage: "sparkles")
                }.disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || assistant.isRunning(notebook))
                    .accessibilityIdentifier("notebook.customization.ask")
            } else {
                ContentUnavailableView(t("Skills de este cuaderno", "Notebook skills"), systemImage: "sparkles",
                    description: Text(t("Añade una skill y describe lo que debe hacer al asistente.", "Add a skill, then tell the assistant what it should do.")))
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }.onAppear { load() }.onChange(of: path) { _, _ in load() }
    }
    private func skillTitle(_ value: String) -> String { URL(fileURLWithPath: value).deletingLastPathComponent().lastPathComponent }
    private func load() {
        guard !path.isEmpty, !loaded.contains(path) else { return }
        do {
            try assistant.store.validate(path, notebookID: notebook.id)
            let exists = FileManager.default.fileExists(atPath: try assistant.store.workspace.noteURL(path).path)
            let disk = exists ? try assistant.store.workspace.readNote(path) : nil
            let current = model.hasDraft(for: path) ? model.drafts[path] : disk
            bases[path] = current
            drafts[path] = current ?? (skills ? "" : NotebookCustomization.initialInstructions(profile: assistant.state(notebook).profile))
            loaded.insert(path)
        } catch { self.error = error.localizedDescription }
    }
    private func addSkill() {
        let slug = skillName.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
        guard !slug.isEmpty else { return }
        selectedSkill = NotebookCustomization.skillsPrefix(notebook) + String(slug.prefix(80)) + "/SKILL.md"
        skillName = ""; load()
    }
    @discardableResult private func save() -> Bool {
        guard let text = drafts[path], text != bases[path] else { return true }
        do {
            // Preserve edits made in the document editor while this sheet was open.
            if model.hasDraft(for: path) {
                guard model.drafts[path] == bases[path] else { throw ReplayError.conflict }
                try model.checkpointDrafts(notebook.id, paths: [path])
            }
            _ = try assistant.store.apply(notebook.id, summary: skills ? "Update notebook skill" : "Update AGENTS.md",
                changes: [.init(path: path, before: bases[path], after: text)], invalidatesProposals: true)
            model.refreshProjectFiles([path]); bases[path] = text; error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    private func askAssistant() {
        // A new empty skill can be generated directly; existing edits are saved first.
        if !(drafts[path] ?? "").isEmpty, !save() { return }
        if model.requestNotebookCustomization(notebook: notebook, path: path, request: request) { dismiss() }
    }
}

@MainActor extension Workbench {
    @discardableResult func requestNotebookCustomization(notebook: Notebook, path: String, request: String) -> Bool {
        guard let assistant, path == NotebookCustomization.agentPath(notebook) || NotebookCustomization.isSkill(path, notebook: notebook),
              !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !assistant.isRunning(notebook), openNotebookForNewChat(notebook.id) else { return false }
        let english = UserDefaults.standard.string(forKey: "notes.language") == "en"
        let prompt = english
            ? "Update the notebook customization file \(path) for this notebook only. Read it first if it exists, preserve unrelated instructions, and create it if missing. Apply the file change. Requested behavior:\n\(request)"
            : "Actualiza el archivo de personalización \(path) solo para este cuaderno. Léelo primero si existe, conserva las instrucciones no relacionadas y créalo si falta. Aplica el cambio al archivo. Comportamiento solicitado:\n\(request)"
        assistant.setDraft(prompt, notebook: notebook)
        submitNotebookPrompt()
        return true
    }
}
