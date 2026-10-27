import Foundation

public struct Notebook: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var rootPrefix: String
    public var archivedAt: Date? = nil
    /// Named preset from `NotebookColor`; nil follows the neutral default.
    public var color: String? = nil
    public init(id: String = UUID().uuidString, name: String, rootPrefix: String) {
        self.id = id; self.name = name; self.rootPrefix = rootPrefix
    }
    public static let copiedCourse = Notebook(id: "derecho", name: "Derecho del Trabajo", rootPrefix: "")
}

public struct NotebookNode: Identifiable, Sendable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var children: [NotebookNode]?

    public static func tree(notes: [String], folderNames: [String] = [], prefix: String = "") -> [NotebookNode] {
        var files: [NotebookNode] = []
        var folders: [String: [String]] = [:]
        var nestedFolders: [String: [String]] = [:]
        for folder in folderNames {
            let parts = folder.components(separatedBy: "/")
            if folders[parts[0]] == nil { folders[parts[0]] = [] }
            if parts.count > 1 { nestedFolders[parts[0], default: []].append(parts.dropFirst().joined(separator: "/")) }
        }
        for note in notes {
            let components = note.components(separatedBy: "/")
            if components.count == 1 {
                // Notes and practice tests are shown by title; their icon already says what they are.
                let name = note.hasSuffix(".md") ? String(note.dropLast(3)) : note.hasSuffix(".quiz.json") ? String(note.dropLast(10)) : note
                files.append(NotebookNode(name: name, path: prefix + note, children: nil))
            } else { folders[components[0], default: []].append(components.dropFirst().joined(separator: "/")) }
        }
        return folders.keys.sorted().map { name in
            NotebookNode(name: name, path: prefix + name,
                         children: tree(notes: folders[name]!, folderNames: nestedFolders[name] ?? [], prefix: prefix + name + "/"))
        } + files.sorted { $0.name < $1.name }
    }
}

public struct EditorChange: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var filename: String
    public var before: String
    public var after: String
    public var undone: Bool
    public var savedAt: Date? = nil
    public var superseded: Bool? = nil
}

public struct DraftArchive: Codable, Sendable {
    public var drafts: [String: String]
    public var bases: [String: String]
    public init(drafts: [String: String], bases: [String: String]) { self.drafts = drafts; self.bases = bases }
}

public final class NotebookEditor {
    public let workspace: SafeWorkspace
    public private(set) var history: [EditorChange]

    public init(workspace: SafeWorkspace) throws {
        self.workspace = workspace
        let path = workspace.storageRoot.appendingPathComponent("editor-history.json")
        if FileManager.default.fileExists(atPath: path.path) {
            history = try JSONDecoder().decode([EditorChange].self, from: workspace.readStorage("editor-history.json"))
        } else { history = [] }
    }

    @discardableResult
    public func save(filename: String, expected: String, replacement: String) throws -> EditorChange {
        let change = EditorChange(id: UUID().uuidString, filename: filename, before: expected, after: replacement, undone: false, savedAt: Date())
        try workspace.writeNote(filename, expected: expected, replacement: replacement)
        var next = history; next.append(change)
        do { try persist(next) }
        catch { try workspace.writeNote(filename, expected: replacement, replacement: expected); throw error }
        history = next
        return change
    }

    @discardableResult
    public func undo() throws -> EditorChange {
        guard let i = history.lastIndex(where: { !$0.undone && $0.superseded != true }) else { throw ReplayError.noUndo }
        let change = history[i]
        try workspace.writeNote(change.filename, expected: change.after, replacement: change.before)
        var next = history; next[i].undone = true
        do { try persist(next) }
        catch { try workspace.writeNote(change.filename, expected: change.before, replacement: change.after); throw error }
        history = next
        return change
    }

    public func invalidateUndo(paths: Set<String>, before date: Date) throws {
        var next = history
        for i in next.indices where paths.contains(next[i].filename) && (next[i].savedAt ?? .distantPast) <= date { next[i].superseded = true }
        if next != history { try persist(next); history = next }
    }

    private func persist(_ changes: [EditorChange]) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try workspace.writeStorage("editor-history.json", data: encoder.encode(changes))
    }
}

public enum MarkdownBlockKind: Sendable { case heading(Int), paragraph, quote, code }
public struct MarkdownBlock: Identifiable, Sendable {
    public var id: Int
    public var text: String
    public var kind: MarkdownBlockKind
}

public enum NotebookMarkdown {
    public static func blocks(_ markdown: String) -> [MarkdownBlock] {
        var result: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false
        func add(_ text: String, _ kind: MarkdownBlockKind) { result.append(MarkdownBlock(id: result.count, text: text, kind: kind)) }
        func flush() {
            if !paragraph.isEmpty { add(paragraph.joined(separator: "\n"), .paragraph); paragraph = [] }
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("```") { flush(); if inCode { add(code.joined(separator: "\n"), .code); code = [] }; inCode.toggle(); continue }
            if inCode { code.append(line); continue }
            if line.hasPrefix("<!--") && line.hasSuffix("-->") { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            let hashes = line.prefix { $0 == "#" }.count
            if hashes > 0 && hashes <= 6 && line.dropFirst(hashes).hasPrefix(" ") {
                flush(); add(String(line.dropFirst(hashes + 1)), .heading(hashes)); continue
            }
            if line.hasPrefix(">") { flush(); add(String(line.dropFirst()).trimmingCharacters(in: .whitespaces), .quote); continue }
            paragraph.append(line)
        }
        flush()
        if inCode { add(code.joined(separator: "\n"), .code) }
        return result
    }

    public static func inline(_ text: String) -> AttributedString {
        var converted = text
        if let regex = try? NSRegularExpression(pattern: "\\[\\[([^\\]]+)\\]\\]") {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                guard let full = Range(match.range, in: converted), let contentRange = Range(match.range(at: 1), in: text) else { continue }
                let content = String(text[contentRange])
                let parts = content.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let target = parts[0]
                let label = parts.count > 1 ? parts[1] : target
                var url = URLComponents(); url.scheme = "derecho-note"; url.host = "open"
                url.queryItems = [URLQueryItem(name: "target", value: target)]
                if let value = url.url?.absoluteString {
                    let safeLabel = label.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                    converted.replaceSubrange(full, with: "[\(safeLabel)](\(value))")
                }
            }
        }
        return (try? AttributedString(markdown: converted, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }

    public static func target(_ url: URL) -> (note: String, heading: String?)? {
        guard url.scheme == "derecho-note", let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "target" })?.value else { return nil }
        let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }
}
