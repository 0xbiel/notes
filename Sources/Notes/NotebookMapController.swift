import SwiftUI
import LectureCore

/// Keeps the atlas of the library up to date. The model runs on this Mac; reading the notebooks again only
/// embeds what changed, and an unchanged library does not start the model at all.
@MainActor
final class NotebookMapController: ObservableObject {
    struct Progress: Equatable { var notebook: String; var done: Int; var total: Int }
    @Published private(set) var atlas: NotebookAtlas?
    @Published private(set) var working: Progress?
    @Published private(set) var reading = false
    @Published private(set) var error: String?
    @Published private(set) var installed: Bool
    @Published private(set) var download: DownloadProgress?
    @Published var installError: String?
    /// Asked to read the library again some time after its content changed.
    var stale: (() -> Void)?

    let runtime: NotebookEmbeddingRuntime
    private let server: NotebookEmbeddingServer
    private let root: URL, originalRoot: URL
    private var loaded = false
    private var task: Task<Void, Never>?
    private var queued: [(Notebook, [String])]?
    private var waiting: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    static var automatic: Bool { UserDefaults.standard.object(forKey: "notes.mapAutoUpdate") as? Bool ?? true }

    init(workspace: SafeWorkspace) {
        root = workspace.root; originalRoot = workspace.originalRoot
        runtime = NotebookEmbeddingRuntime(root: workspace.root)
        server = NotebookEmbeddingServer(runtime: runtime)
        installed = runtime.available
        // A server left behind by a crash would hold a gigabyte of memory for nothing.
        NotebookEmbeddingServer.terminate(runtime)
    }
    func shutdown() {
        task?.cancel(); installTask?.cancel(); waiting?.cancel()
        NotebookEmbeddingServer.terminate(runtime)
    }

    /// Shows the atlas saved by an earlier session while the library is read again.
    func load() {
        guard !loaded, atlas == nil, let workspace = try? SafeWorkspace(root: root, originalRoot: originalRoot) else { return }
        loaded = true
        atlas = NotebookAtlas.load(workspace: workspace)
    }

    func install() {
        guard installTask == nil else { return }
        installError = nil; download = .init(received: 0, total: NotebookEmbeddingRuntime.downloadSize)
        let runtime = runtime
        installTask = Task { [weak self] in
            do { try await runtime.install { progress in Task { @MainActor in if self?.installTask != nil { self?.download = progress } } } }
            catch is CancellationError {}
            catch { self?.installError = error.localizedDescription }
            self?.installTask = nil; self?.download = nil; self?.installed = runtime.available
        }
    }
    func cancelInstall() { installTask?.cancel() }
    /// The atlas already made stays; it only stops following the notebooks.
    func removeModel() {
        task?.cancel()
        let server = server, runtime = runtime
        Task { [weak self] in
            await server.stop()
            do { try runtime.uninstall() } catch { self?.installError = error.localizedDescription }
            self?.installed = runtime.available
        }
    }

    /// `notebooks` pairs every notebook with all of its notes and library files.
    func refresh(_ notebooks: [(Notebook, [String])]) {
        waiting?.cancel(); waiting = nil
        guard installed else { return }
        if task != nil { queued = notebooks; return }
        load()
        error = nil; reading = true
        let before = atlas, root = root, originalRoot = originalRoot, server = server
        task = Task { [weak self] in
            do {
                let atlas = try await Self.make(notebooks, before: before, root: root, originalRoot: originalRoot, embedder: server) { name, done, total in
                    Task { @MainActor in if self?.task != nil, total > 0 { self?.working = .init(notebook: name, done: done, total: total) } }
                }
                if let atlas { self?.atlas = atlas }
            } catch is CancellationError {} catch { self?.error = error.localizedDescription }
            guard let self else { return }
            self.task = nil; self.working = nil; self.reading = false
            if let next = self.queued, !Task.isCancelled { self.queued = nil; self.refresh(next) }
        }
    }

    /// Runs away from the main thread. Returns nil when the library is as the saved atlas shows it.
    private nonisolated static func make(_ notebooks: [(Notebook, [String])], before: NotebookAtlas?, root: URL, originalRoot: URL, embedder: NotebookEmbedder,
                                         progress: @escaping @Sendable (String, Int, Int) -> Void) async throws -> NotebookAtlas? {
        let workspace = try SafeWorkspace(root: root, originalRoot: originalRoot)
        var sources: [NotebookAtlasBuilder.Source] = [], changed = false
        for (notebook, paths) in notebooks {
            try Task.checkCancellation()
            let previous = NotebookMapIndex.load(notebookID: notebook.id, workspace: workspace)
            let scan = try NotebookMapScanner.scan(paths: paths, root: notebook.rootPrefix, workspace: workspace, previous: previous)
            let name = notebook.name
            let (index, different) = try await NotebookMapIndexer.update(scan: scan, previous: previous, workspace: workspace, embedder: embedder) { progress(name, $0, $1) }
            if different { try index.save(notebookID: notebook.id, workspace: workspace); changed = true }
            sources.append(.init(id: notebook.id, name: notebook.name, index: index))
        }
        let names = Dictionary(sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        guard changed || before == nil || before?.notebooks != names else { return nil }
        try Task.checkCancellation()
        let atlas = NotebookAtlasBuilder.build(sources, previous: before)
        try atlas.save(workspace: workspace)
        return atlas
    }

    /// Once the atlas has been seen it follows the notes: a while after the last change, the library is read again.
    func contentChanged() {
        guard installed, Self.automatic, atlas != nil else { return }
        waiting?.cancel()
        waiting = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.waiting = nil
            self?.stale?()
        }
    }
}

@MainActor
extension Workbench {
    var mapVisible: Bool { showMap && selectedLibraryPath == nil && maps != nil && !activeNotebooks.isEmpty }
    func toggleMap() {
        if mapVisible { showMap = false; return }
        openNotebook(currentNotebook.id)
        showMap = true
    }
    func refreshMap() {
        // Pictures kept for notes are left out here: each appears with the note that shows it.
        maps?.refresh(activeNotebooks.map { ($0, fileNames(in: $0)) })
    }
    func mapContentChanged(_ paths: [String]) {
        if paths.contains(where: { projects?.owner(of: $0) != nil }) { maps?.contentChanged() }
    }
    func openMapItem(_ item: NotebookMapItem) {
        if item.path.hasSuffix(".md") { openNote(item.path, heading: item.heading) } else { openLibraryFile(item.path) }
    }
}
