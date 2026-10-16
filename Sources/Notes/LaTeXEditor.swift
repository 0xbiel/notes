import SwiftUI
import PDFKit
import CryptoKit
import LectureCore

enum LaTeXDocument {
    static func isSource(_ path: String) -> Bool { URL(fileURLWithPath: path).pathExtension.lowercased() == "tex" }
    static let template = """
    \\documentclass[12pt,a4paper]{article}
    \\usepackage{amsmath,amssymb}
    \\usepackage[margin=2.5cm]{geometry}
    \\title{Homework}
    \\author{}
    \\date{}
    \\begin{document}
    \\maketitle
    \\section{Exercise 1}
    Write your solution here.
    \\[ E = mc^2 \\]
    \\end{document}
    """
    static var compiler: URL? {
        let candidates = ["/opt/homebrew/bin/tectonic", "/usr/local/bin/tectonic"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/tectonic" }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    static func compile(_ source: String, allowPackageDownloads: Bool = true) async throws -> Data {
        guard !source.isEmpty, source.utf8.count <= 1_000_000 else { throw MediaError.invalid("LaTeX source must be nonempty and at most 1 MB.") }
        guard let compiler else { throw MediaError.invalid("Install Tectonic to compile LaTeX (brew install tectonic). Source editing works without it.") }
        let compilation = Task.detached {
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent("palladium-tex-" + UUID().uuidString)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: directory) }
            let input = directory.appendingPathComponent("document.tex")
            try source.write(to: input, atomically: true, encoding: .utf8)
            let logURL = directory.appendingPathComponent("compiler.log")
            fm.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            let process = Process(); process.executableURL = compiler
            process.currentDirectoryURL = directory
            process.arguments = ["--untrusted", "--color", "never", "--outdir", directory.path, input.path] + (allowPackageDownloads ? [] : ["--only-cached"])
            process.standardOutput = log; process.standardError = log
            try process.run()
            let deadline = Date().addingTimeInterval(60)
            do {
                while process.isRunning {
                    try Task.checkCancellation()
                    guard Date() < deadline else { throw MediaError.invalid("LaTeX compilation timed out.") }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                if process.isRunning { process.terminate(); process.waitUntilExit() }
                throw error
            }
            guard process.terminationStatus == 0 else {
                let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "Compilation failed."
                throw MediaError.invalid(String(output.suffix(8000)) + (allowPackageDownloads ? "" : "\nEnable TeX package downloads or cache the missing packages outside Palladium."))
            }
            return try Data(contentsOf: directory.appendingPathComponent("document.pdf"))
        }
        return try await withTaskCancellationHandler(operation: { try await compilation.value }, onCancel: { compilation.cancel() })
    }
}

@MainActor final class LaTeXEditorController: ObservableObject {
    struct Draft: Codable { var source: String; var base: String }
    let workspace: SafeWorkspace
    let path: String
    @Published var source = ""
    @Published var error: String?
    @Published var compiling = false
    @Published var previewURL: URL?
    @Published private var base = ""
    private var compiledSource: String?
    var dirty: Bool { source != base }
    var previewStale: Bool { compiledSource != source }
    private var draftPath: String { "latex-drafts/" + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() + ".json" }
    init(workspace: SafeWorkspace, path: String) {
        self.workspace = workspace; self.path = path
        do {
            base = try String(contentsOf: workspace.fileURL(path), encoding: .utf8); source = base
            if let data = try? workspace.readStorage(draftPath), let draft = try? JSONDecoder().decode(Draft.self, from: data), draft.source != draft.base {
                source = draft.source; base = draft.base
            }
        } catch { self.error = error.localizedDescription }
    }
    func change(_ value: String) {
        source = value
        do { try workspace.writeStorage(draftPath, data: JSONEncoder().encode(Draft(source: source, base: base))) }
        catch { self.error = error.localizedDescription }
    }
    func save() throws {
        // Saved like a note, so the change gets a checkpoint that can be restored.
        try workspace.writeNote(path, expected: base, replacement: source)
        base = source
        try workspace.writeStorage(draftPath, data: JSONEncoder().encode(Draft(source: source, base: base)))
    }
    /// Takes the file as it is on disk after someone else (the assistant, a restore) changed it.
    func reload() {
        guard let disk = try? workspace.readNote(path) else { return }
        base = disk; source = disk; error = nil
        try? workspace.removeStorage(draftPath)
    }
    func compile() async throws -> Data {
        guard !compiling else { throw MediaError.invalid("LaTeX compilation is already running.") }
        compiling = true; error = nil
        defer { compiling = false }
        let snapshot = source
        do {
            let allowDownloads = UserDefaults.standard.object(forKey: "notes.latexDownloads") as? Bool ?? true
            let data = try await LaTeXDocument.compile(snapshot, allowPackageDownloads: allowDownloads)
            guard PDFDocument(data: data)?.pageCount ?? 0 > 0 else { throw MediaError.invalid("The compiler did not produce a valid PDF.") }
            let name = "latex-previews/" + UUID().uuidString + ".pdf"
            try workspace.writeStorage(name, data: data)
            if let previous = previewURL { try? FileManager.default.removeItem(at: previous) }
            previewURL = workspace.storageRoot.appendingPathComponent(name); compiledSource = snapshot
            return data
        } catch { self.error = error.localizedDescription; throw error }
    }
}

@MainActor extension Workbench {
    func latexController(_ path: String) throws -> LaTeXEditorController {
        if let controller = latexEditors[path] { return controller }
        guard let workspace else { throw ReplayError.missingWorkspace }
        let controller = LaTeXEditorController(workspace: workspace, path: path)
        latexEditors[path] = controller
        return controller
    }
}

struct LaTeXEditor: View {
    @ObservedObject var controller: LaTeXEditorController
    var bottomInset: CGFloat = 0
    @AppStorage("notes.language") private var language = "es"
    private func text(_ english: String, _ spanish: String) -> String { language == "en" ? english : spanish }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("LaTeX", systemImage: "function").font(.callout.weight(.medium))
                Text(controller.dirty ? text("Draft saved locally", "Borrador guardado localmente") : text("Saved", "Guardado")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { do { try controller.save() } catch { controller.error = error.localizedDescription } } label: {
                    Label(text("Save source", "Guardar fuente"), systemImage: "square.and.arrow.down")
                        .font(.callout).padding(.horizontal, 10).frame(height: 34)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).modifier(ControlHoverBackground(cornerRadius: 9))
                    .disabled(!controller.dirty).keyboardShortcut("s")
                    .accessibilityIdentifier("latex.save")
                Button {
                    Task { _ = try? await controller.compile() }
                } label: {
                    HStack(spacing: 6) {
                        if controller.compiling { ProgressView().controlSize(.small) }
                        else { Image(systemName: "play") }
                        Text(controller.compiling ? text("Compiling…", "Compilando…") : text("Compile PDF", "Compilar PDF"))
                    }.font(.callout.weight(.medium)).padding(.horizontal, 12).frame(height: 34)
                        .modifier(NotebookInputSurface(radius: 9))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).modifier(ControlHoverBackground(cornerRadius: 9))
                    .disabled(controller.compiling).accessibilityIdentifier("latex.compile")
            }.padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            if let error = controller.error {
                ScrollView { Text(error).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.frame(maxHeight: 120)
            }
            HSplitView {
                TextEditor(text: Binding(get: { controller.source }, set: { controller.change($0) }))
                    .font(.system(size: 14, design: .monospaced)).padding(12)
                    .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .accessibilityIdentifier("latex.source")
                VStack(spacing: 0) {
                    if let url = controller.previewURL {
                        if controller.previewStale { Text(text("Preview needs recompiling", "La vista previa necesita recompilarse")).font(.caption).padding(8) }
                        LibraryPDFView(url: url).id(url)
                    } else {
                        ContentUnavailableView(text("LaTeX preview", "Vista previa LaTeX"), systemImage: "function", description: Text(text("Compile to preview. Uses local Tectonic with no shell escape. Standalone .tex documents only.", "Compila para previsualizar. Usa Tectonic local sin comandos de shell. Solo documentos .tex autónomos.")))
                    }
                }.frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, bottomInset)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
