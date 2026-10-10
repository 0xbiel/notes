import Foundation
import LectureCore
@testable import Notes

// Synthetic creation belongs to test fixtures, not app actions.
@MainActor
extension Workbench {
    func createAIDemo() {
        guard let workspace, let media else { return }
        do {
            let notebook: Notebook
            if let existing = notebooks.first(where: { $0.id == "synthetic" }) { notebook = existing }
            else {
                notebook = Notebook(id: "synthetic", name: "Demo IA inventada", rootPrefix: "Cuadernos/Demo IA " + String(UUID().uuidString.prefix(8)))
                try workspace.createFolder(notebook.rootPrefix)
                var next = notebooks; next.append(notebook)
                try workspace.writeStorage("notebooks.json", data: JSONEncoder().encode(next)); notebooks = next
            }
            let note = notebook.rootPrefix + "/Ejemplo " + String(UUID().uuidString.prefix(8)) + ".md"
            try workspace.createNote(note, text: SyntheticAIFixture.note)
            var job = MediaJob(notebookID: "synthetic", subject: notebook.name, note: note, sourceName: "Demo IA · texto inventado")
            job.syntheticFixture = true; job.stage = .transcribed; job.transcript = SyntheticAIFixture.segments
            try media.addAIDemo(job)
            notes = try workspace.noteNames(); folders = try workspace.folderNames(); openNote(note)
            statusText = "Demo inventada · selecciona los cuatro fragmentos antes de enviar; permite retención, no entrenamiento"
        } catch { errorText = error.localizedDescription }
    }
}

@MainActor
extension MediaController {
    func addAIDemo(_ job: MediaJob) throws {
        guard job.syntheticFixture, job.notebookID == "synthetic", job.transcript == SyntheticAIFixture.segments, try SafeWorkspace(root: store.root, originalRoot: store.originalRoot).readNote(job.targetNote) == SyntheticAIFixture.note else { throw MediaError.invalid("Demo inventada inválida.") }
        try store.save(job); jobs.insert(job, at: 0); select(job.id)
    }
}
