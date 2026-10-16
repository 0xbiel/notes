import XCTest
@testable import LectureCore
import simd

/// Places each text by the subject word it contains, so tests need no model.
private actor SubjectEmbedder: NotebookEmbedder {
    static let subjects = ["cell", "law", "matrix"]
    private(set) var texts: [String] = []
    private(set) var images = 0
    static func vector(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: NotebookEmbeddingRuntime.dimensions)
        let lowered = text.lowercased()
        for (index, subject) in subjects.enumerated() where lowered.contains(subject) { vector[index] = 1 }
        // A small part of its own keeps texts of one subject apart from each other.
        vector[8 + abs(lowered.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 9973 }) % 200] = 0.3
        let length = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return vector.map { $0 / length }
    }
    func embed(texts: [String]) async throws -> [[Float]] { self.texts += texts; return texts.map(Self.vector) }
    func embed(image: Data) async throws -> [Float] { images += 1; return Self.vector("cell picture") }
}

final class NotebookMapTests: XCTestCase {
    private func fixture() throws -> SafeWorkspace {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/NotebookMap-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
    }
    private func note(_ subject: String, sections: Int) -> String {
        "# \(subject.capitalized) notes\n" + (1...sections).map { "\n## \(subject.capitalized) part \($0)\n\nA long enough paragraph about the \(subject), number \($0), for the map.\n" }.joined()
    }
    private func index(_ workspace: SafeWorkspace, paths: [String], previous: NotebookMapIndex? = nil, embedder: SubjectEmbedder) async throws -> (index: NotebookMapIndex, changed: Bool) {
        let scan = try NotebookMapScanner.scan(paths: paths, workspace: workspace, previous: previous)
        return try await NotebookMapIndexer.update(scan: scan, previous: previous, workspace: workspace, embedder: embedder)
    }

    func testNoteIsCutAtHeadingsAndKeepsCodeAndDeepHeadingsInside() {
        let sections = NotebookMapScanner.sections("Opening words.\n# One\ntext\n## Two\n```\n# not a heading\n```\n#### Deep\nmore\n# Three\n")
        XCTAssertEqual(sections.map(\.heading), [nil, "One", "Two", "Three"])
        XCTAssertEqual(sections[2].trail, ["One"])
        XCTAssertTrue(sections[2].body.contains("# not a heading") && sections[2].body.contains("#### Deep"))
        XCTAssertEqual(sections[3].trail, [])
    }

    func testPicturesResolveRelativeToTheNoteAndStayInside() {
        let found = NotebookMapScanner.pictures("![a](.palladium-images/one.png) ![b](../shared/two%20b.jpg \"t\") ![c](https://example.org/x.png) ![d](../../../out.png) ![e](doc.pdf)", note: "Book/Unit/Note.md")
        XCTAssertEqual(found, ["Book/Unit/.palladium-images/one.png", "Book/shared/two b.jpg"])
    }

    func testUnchangedPartsKeepTheirVectors() async throws {
        let workspace = try fixture(), embedder = SubjectEmbedder()
        try workspace.createNote("Cell.md", text: note("cell", sections: 3))
        try workspace.createNote("Law.md", text: note("law", sections: 2))
        let first = try await index(workspace, paths: ["Cell.md", "Law.md"], embedder: embedder)
        XCTAssertTrue(first.changed)
        XCTAssertEqual(first.index.entries.map(\.item.id), ["Cell.md#Cell part 1", "Cell.md#Cell part 2", "Cell.md#Cell part 3", "Law.md#Law part 1", "Law.md#Law part 2"])
        XCTAssertEqual(first.index.entries.first?.item.heading, "Cell part 1")
        let sectionsEmbedded = await embedder.texts.filter { $0.contains("paragraph") }.count
        XCTAssertEqual(sectionsEmbedded, 5)

        // Nothing changed: no file is read again and nothing is embedded.
        let before = await embedder.texts.count
        let same = try await index(workspace, paths: ["Cell.md", "Law.md"], previous: first.index, embedder: embedder)
        XCTAssertFalse(same.changed)
        let afterSame = await embedder.texts.count
        XCTAssertEqual(afterSame, before)

        // One section edited: only that one is embedded, and the others keep the vectors they had.
        let old = try workspace.readNote("Cell.md")
        try workspace.writeNote("Cell.md", expected: old, replacement: old.replacingOccurrences(of: "number 2, for the map.", with: "number 2, rewritten at greater length."))
        let edited = try await index(workspace, paths: ["Cell.md", "Law.md"], previous: first.index, embedder: embedder)
        XCTAssertTrue(edited.changed)
        let afterEdit = await embedder.texts
        XCTAssertEqual(afterEdit.count, before + 1)
        XCTAssertTrue(afterEdit.last?.contains("rewritten") == true && afterEdit.last?.hasPrefix(NotebookMapIndexer.prefix) == true)
        XCTAssertEqual(edited.index.entries[0].vector, first.index.entries[0].vector)
        XCTAssertNotEqual(edited.index.entries[1].item.digest, first.index.entries[1].item.digest)

        // A deleted note leaves the index.
        let gone = try await index(workspace, paths: ["Law.md"], previous: edited.index, embedder: embedder)
        XCTAssertEqual(gone.index.entries.map(\.item.path), ["Law.md", "Law.md"])
        XCTAssertNil(gone.index.titles["Cell part 1"])
    }

    func testIndexSurvivesStorageAndRejectsAnotherModel() async throws {
        let workspace = try fixture(), embedder = SubjectEmbedder()
        try workspace.createNote("Cell.md", text: note("cell", sections: 2))
        var made = try await index(workspace, paths: ["Cell.md"], embedder: embedder).index
        try made.save(notebookID: "a/b", workspace: workspace)
        let loaded = try XCTUnwrap(NotebookMapIndex.load(notebookID: "a/b", workspace: workspace))
        XCTAssertEqual(loaded.entries.map(\.vector), made.entries.map(\.vector))
        XCTAssertEqual(NotebookMapIndex.unpack(loaded.entries[0].vector).count, NotebookEmbeddingRuntime.dimensions)
        var atlas = NotebookAtlasBuilder.build([.init(id: "a/b", name: "Book", index: made)])
        try atlas.save(workspace: workspace)
        XCTAssertEqual(NotebookAtlas.load(workspace: workspace), atlas)
        made.model = "another"
        try made.save(notebookID: "a/b", workspace: workspace)
        XCTAssertNil(NotebookMapIndex.load(notebookID: "a/b", workspace: workspace))
        // An atlas laid out by other rules is made again instead of being shown.
        atlas.version += 1
        try atlas.save(workspace: workspace)
        XCTAssertNil(NotebookAtlas.load(workspace: workspace))
    }

    private func vector(_ values: [Float]) -> SIMD3<Float> { SIMD3(values[0], values[1], values[2]) }
    func testAtlasMakesARegionOfEachNotebookWithItsSubjectsInside() async throws {
        let workspace = try fixture(), embedder = SubjectEmbedder()
        for subject in SubjectEmbedder.subjects { try workspace.createNote(subject.capitalized + ".md", text: note(subject, sections: 6)) }
        // Laws about cells are what the two notebooks share.
        try workspace.createNote("More law.md", text: note("cell law", sections: 3))
        let biology = try await index(workspace, paths: ["Cell.md", "Matrix.md"], embedder: embedder).index
        let rights = try await index(workspace, paths: ["Law.md", "More law.md"], embedder: embedder).index
        let sources: [NotebookAtlasBuilder.Source] = [.init(id: "bio", name: "Biology", index: biology), .init(id: "law", name: "Rights", index: rights)]
        let now = Date(timeIntervalSince1970: 0)
        let atlas = NotebookAtlasBuilder.build(sources, now: now)
        XCTAssertEqual(atlas.regions.map(\.title), ["Biology", "Rights"])
        XCTAssertEqual(atlas.regions.map(\.count), [12, 9])
        XCTAssertEqual(Set(atlas.points.map(\.id)).count, 21)
        XCTAssertEqual(atlas.notebooks, ["bio": "Biology", "law": "Rights"])
        // Biology holds two subjects, each its own cluster.
        XCTAssertEqual(Set(atlas.topics.filter { $0.region == 0 }.map(\.title)), ["Cell", "Matrix"])
        for point in atlas.points {
            let region = atlas.regions[point.region]
            XCTAssertLessThanOrEqual(simd_distance(vector(point.position), vector(region.centre)), region.radius * 1.001)
            XCTAssertEqual(atlas.topics[point.topic].region, point.region)
            XCTAssertTrue(atlas.topics[point.topic].title.lowercased().contains(point.item.file.lowercased().prefix(4)) || atlas.topics[point.topic].region == 1)
        }
        let apart = simd_distance(vector(atlas.regions[0].centre), vector(atlas.regions[1].centre))
        XCTAssertGreaterThanOrEqual(apart, atlas.regions[0].radius + atlas.regions[1].radius)
        // Every place is linked to the places most like it; links across notebooks join what they share.
        XCTAssertTrue(atlas.points.indices.allSatisfy { index in atlas.links.contains { $0.from == index || $0.to == index } })
        let across = atlas.links.filter { atlas.points[$0.from].region != atlas.points[$0.to].region }
        XCTAssertFalse(across.isEmpty)
        for link in across { XCTAssertEqual(Set([atlas.points[link.from].item.file, atlas.points[link.to].item.file]), ["Cell", "More law"]) }
        XCTAssertEqual(NotebookAtlasBuilder.build(sources, now: now), atlas)
    }
    func testOneNotebookIsDividedIntoRegionsByItsSubjects() async throws {
        let workspace = try fixture(), embedder = SubjectEmbedder()
        for subject in SubjectEmbedder.subjects { try workspace.createNote(subject.capitalized + ".md", text: note(subject, sections: 6)) }
        let made = try await index(workspace, paths: SubjectEmbedder.subjects.map { $0.capitalized + ".md" }, embedder: embedder).index
        let atlas = NotebookAtlasBuilder.build([.init(id: "book", name: "Book", index: made)])
        XCTAssertEqual(atlas.regions.map(\.title), ["Cell", "Law", "Matrix"])
        XCTAssertEqual(atlas.regions.map(\.count), [6, 6, 6])
        XCTAssertTrue(atlas.points.allSatisfy { $0.item.file.lowercased() == atlas.regions[$0.region].title.lowercased() })
    }
    func testAtlasMadeAgainFacesTheWayTheLastOneDid() async throws {
        let workspace = try fixture(), embedder = SubjectEmbedder()
        for subject in SubjectEmbedder.subjects { try workspace.createNote(subject.capitalized + ".md", text: note(subject, sections: 6)) }
        let made = try await index(workspace, paths: SubjectEmbedder.subjects.map { $0.capitalized + ".md" }, embedder: embedder).index
        let sources: [NotebookAtlasBuilder.Source] = [.init(id: "book", name: "Book", index: made)]
        var mirrored = NotebookAtlasBuilder.build(sources)
        for index in mirrored.points.indices { mirrored.points[index].position[0] *= -1; mirrored.points[index].position[2] *= -1 }
        for index in mirrored.regions.indices { mirrored.regions[index].centre[0] *= -1; mirrored.regions[index].centre[2] *= -1 }
        let again = NotebookAtlasBuilder.build(sources, previous: mirrored)
        for (point, old) in zip(again.points, mirrored.points) { XCTAssertLessThan(simd_distance(vector(point.position), vector(old.position)), 1e-3) }
    }

    func testSmallNotebookIsShownByFile() async throws {
        let workspace = try fixture(), embedder = SubjectEmbedder()
        try workspace.createNote("Cell.md", text: note("cell", sections: 2))
        try workspace.createNote("Law.md", text: "A single paragraph about the law, without any heading.")
        let made = try await index(workspace, paths: ["Cell.md", "Law.md"], embedder: embedder).index
        let map = NotebookMapBuilder.build(name: "Book", index: made)
        XCTAssertEqual(map.root.children.map(\.title), ["Cell", "Law"])
        XCTAssertEqual(map.root.children[0].children.map(\.title), ["Cell part 1", "Cell part 2"])
        XCTAssertEqual(map.root.children[1].item?.path, "Law.md")
        XCTAssertNil(map.root.children[1].item?.heading)
        XCTAssertEqual(map.root.places, 3)
    }

    func testSubjectsBecomeTopicsThatStayPutWhenTheNotebookGrows() async throws {
        let workspace = try fixture(), embedder = SubjectEmbedder()
        for subject in SubjectEmbedder.subjects { try workspace.createNote(subject.capitalized + ".md", text: note(subject, sections: 6)) }
        let paths = SubjectEmbedder.subjects.map { $0.capitalized + ".md" }
        let first = try await index(workspace, paths: paths, embedder: embedder).index
        let map = NotebookMapBuilder.build(name: "Book", index: first)
        XCTAssertEqual(map.root.children.count, 3)
        XCTAssertEqual(map.root.places, 18)
        for topic in map.root.children {
            var files = Set<String>()
            func collect(_ node: NotebookMap.Node) { if let item = node.item { files.insert(item.path) }; node.children.forEach(collect) }
            collect(topic)
            XCTAssertEqual(files.count, 1, "a topic mixes subjects: \(files)")
            XCTAssertTrue(topic.title.lowercased().contains(files.first!.dropLast(3).lowercased()), "\(topic.title) does not name \(files)")
        }
        XCTAssertEqual(Set(map.root.children.map(\.title)).count, 3)
        XCTAssertEqual(NotebookMapBuilder.build(name: "Book", index: first).root, map.root)

        // A new note on one subject joins its topic; every topic keeps its identity and order.
        try workspace.createNote("Cell extra.md", text: note("cell", sections: 2).replacingOccurrences(of: "Cell part", with: "Cell appendix"))
        let grown = try await index(workspace, paths: paths + ["Cell extra.md"], previous: first, embedder: embedder).index
        let next = NotebookMapBuilder.build(name: "Book", index: grown, previous: map)
        XCTAssertEqual(next.root.children.map(\.id), map.root.children.map(\.id))
        XCTAssertEqual(next.root.children.map(\.title), ["Cell · Cell extra", "Law", "Matrix"])
        XCTAssertEqual(next.root.children[0].children.map(\.title), ["Cell", "Cell extra"])
        XCTAssertEqual(next.root.places, 20)
    }

    func testPicturesInANoteFollowTheirSectionAndLoosePicturesJoinTheNearestTopic() async throws {
        let workspace = try fixture(), embedder = SubjectEmbedder()
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try workspace.createAsset(".palladium-images/figure.png", data: png)
        try workspace.createAsset("loose.png", data: png)
        for subject in SubjectEmbedder.subjects { try workspace.createNote(subject.capitalized + ".md", text: note(subject, sections: 4)) }
        let old = try workspace.readNote("Law.md")
        try workspace.writeNote("Law.md", expected: old, replacement: old + "\n![figure](.palladium-images/figure.png)\n")
        let paths = SubjectEmbedder.subjects.map { $0.capitalized + ".md" } + [".palladium-images/figure.png", "loose.png"]
        let made = try await index(workspace, paths: paths, embedder: embedder).index
        // The picture in the note is placed by its section; only the loose one needs a vector.
        let embeddedImages = await embedder.images
        XCTAssertEqual(embeddedImages, 1)
        let hosted = try XCTUnwrap(made.entries.first { $0.item.image == ".palladium-images/figure.png" })
        XCTAssertEqual(hosted.item.host, "Law.md#Law part 4")
        XCTAssertEqual(hosted.item.path, "Law.md")
        XCTAssertTrue(hosted.vector.isEmpty)

        let map = NotebookMapBuilder.build(name: "Book", index: made)
        func titles(_ node: NotebookMap.Node) -> [String] { node.item != nil ? [node.title] : node.children.flatMap(titles) }
        let law = try XCTUnwrap(map.root.children.first { titles($0).contains("Law part 4") })
        let lawTitles = titles(law)
        XCTAssertEqual(lawTitles.firstIndex(of: "figure"), lawTitles.firstIndex(of: "Law part 4")! + 1)
        let cell = try XCTUnwrap(map.root.children.first { titles($0).contains("Cell part 1") })
        XCTAssertTrue(titles(cell).contains("loose"))
        XCTAssertEqual(map.root.places, 14)
    }

    func testTitlesLoseMarkdownMarks() {
        XCTAssertEqual(NotebookMapBuilder.clean("**Bold** and `code`: "), "Bold and code")
        XCTAssertEqual(NotebookMapBuilder.clean("See [the law](https://example.org)"), "See the law")
        XCTAssertEqual(NotebookMapBuilder.clean("snake_case stays"), "snake_case stays")
        XCTAssertEqual(NotebookMapBuilder.clean(String(repeating: "a", count: 90)).count, 70)
    }

    func testVectorIsCutToItsLeadingPartAndRescaled() throws {
        var full = [Float](repeating: 0, count: 768); full[0] = 3; full[1] = 4; full[700] = 100
        let short = try NotebookEmbeddingServer.shorten(full)
        XCTAssertEqual(short.count, NotebookEmbeddingRuntime.dimensions)
        XCTAssertEqual(short[0], 0.6, accuracy: 0.0001); XCTAssertEqual(short[1], 0.8, accuracy: 0.0001)
        XCTAssertThrowsError(try NotebookEmbeddingServer.shorten([1, 2, 3]))
        XCTAssertThrowsError(try NotebookEmbeddingServer.shorten([Float](repeating: 0, count: 768)))
    }

    /// Runs the real model when `PALLADIUM_EMBEDDING_ROOT` holds an installed `embedding` folder and
    /// `PALLADIUM_MAP_WORKSPACE` a workspace; prints the map of each of its notebooks.
    func testRealModelMapsAWorkspace() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let runtimeRoot = environment["PALLADIUM_EMBEDDING_ROOT"], let workspaceRoot = environment["PALLADIUM_MAP_WORKSPACE"] else { throw XCTSkip("No local model supplied.") }
        let runtime = NotebookEmbeddingRuntime(root: URL(fileURLWithPath: runtimeRoot))
        XCTAssertTrue(runtime.available)
        let root = URL(fileURLWithPath: workspaceRoot)
        let workspace = try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("protected-original"))
        let notebooks = try JSONDecoder().decode([Notebook].self, from: workspace.readStorage("notebooks.json"))
        let server = NotebookEmbeddingServer(runtime: runtime)
        var sources: [NotebookAtlasBuilder.Source] = []
        for notebook in notebooks {
            let paths = try workspace.fileNames().filter { $0.hasPrefix(notebook.rootPrefix + "/") }
            let started = Date()
            let scan = try NotebookMapScanner.scan(paths: paths, root: notebook.rootPrefix, workspace: workspace, previous: nil)
            let made = try await NotebookMapIndexer.update(scan: scan, previous: nil, workspace: workspace, embedder: server).index
            let map = NotebookMapBuilder.build(name: notebook.name, index: made)
            print("\(notebook.name): \(made.entries.count) places in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            func show(_ node: NotebookMap.Node, _ depth: Int) {
                print(String(repeating: "  ", count: depth) + (node.item == nil ? "● " : "- ") + node.title + (node.item == nil ? " (\(node.places))" : ""))
                node.children.forEach { show($0, depth + 1) }
            }
            show(map.root, 0)
            XCTAssertEqual(map.root.places, made.entries.count)
            sources.append(.init(id: notebook.id, name: notebook.name, index: made))
        }
        await server.stop()
        let started = Date(), atlas = NotebookAtlasBuilder.build(sources)
        print("Atlas in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        for region in atlas.regions { print("◉ \(region.title) (\(region.count)) — \(atlas.topics.filter { atlas.regions[$0.region].id == region.id }.map(\.title).joined(separator: ", "))") }
        for link in atlas.links.prefix(8) { print("  \(atlas.points[link.from].item.title) ↔ \(atlas.points[link.to].item.title) \(link.strength)") }
    }
}

extension NotebookMapTests {
    /// Set PALLADIUM_EMBEDDING_INSTALL to an empty folder to download and verify the real runtime and model
    /// (about 880 MB). Files already in that folder's `embedding` are kept, as on a second launch.
    func testInstallDownloadsVerifiesAndStartsTheRuntime() async throws {
        guard let path = ProcessInfo.processInfo.environment["PALLADIUM_EMBEDDING_INSTALL"] else { throw XCTSkip("No install folder supplied.") }
        let runtime = NotebookEmbeddingRuntime(root: URL(fileURLWithPath: path))
        let received = Received()
        try await runtime.install { progress in Task { await received.note(progress) } }
        XCTAssertTrue(runtime.available)
        let last = await received.last
        XCTAssertEqual(last?.received, NotebookEmbeddingRuntime.downloadSize)
        let server = NotebookEmbeddingServer(runtime: runtime)
        let vectors = try await server.embed(texts: ["task: clustering | query: una célula", "task: clustering | query: a cell", "task: clustering | query: el derecho laboral"])
        XCTAssertEqual(vectors.map(\.count), [256, 256, 256])
        XCTAssertGreaterThan(NotebookMapBuilder.dot(vectors[0], vectors[1]), NotebookMapBuilder.dot(vectors[0], vectors[2]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.pidFile.path))
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.pidFile.path))
        try runtime.uninstall()
        XCTAssertFalse(runtime.available)
    }
}
private actor Received {
    var last: DownloadProgress?
    func note(_ progress: DownloadProgress) { if progress.received >= (last?.received ?? 0) { last = progress } }
}
