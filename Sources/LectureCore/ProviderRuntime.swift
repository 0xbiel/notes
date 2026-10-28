import Foundation
import CryptoKit
import Darwin

public enum ProviderInstallStage: Equatable, Sendable {
    case checkingVersion
    case downloadingRuntime(DownloadProgress)
    case verifyingRuntime
    case installingPackage(version: String)
    case verifyingInstallation(version: String)
}

/// Palladium owns these installations; user-selected binaries are never updated.
public actor ProviderRuntime {
    public static let shared = ProviderRuntime()
    public static func root(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Palladium/Providers")
    }
    public static func name(_ provider: NotesAIProvider) -> String {
        switch provider {
        case .codexCLI: "codex"
        case .claudeCode: "claude"
        case .openCode: "opencode"
        case .antigravity: "antigravity-acp"
        }
    }
    public static func managedExecutable(_ provider: NotesAIProvider, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        root(home: home).appendingPathComponent(provider.rawValue + "/current/bin/" + name(provider)).path
    }
    public static func isManaged(_ configuration: AIProviderConfiguration, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        configuration.executablePath == managedExecutable(configuration.provider, home: home)
    }
    public static func isInstalled(_ configuration: AIProviderConfiguration) -> Bool {
        FileManager.default.isExecutableFile(atPath: configuration.executablePath)
    }
    public static func executable(_ provider: NotesAIProvider, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let managed = managedExecutable(provider, home: home)
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = [managed, home.appendingPathComponent(".local/bin/" + name(provider)).path] + (paths + ["/opt/homebrew/bin", "/usr/local/bin"]).filter { !$0.contains("/.t3/") }.map { $0 + "/" + name(provider) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? (supportsInstallation(provider) ? managed : home.appendingPathComponent(".local/bin/" + name(provider)).path)
    }
    /// Resolve an existing installation, including an explicitly configured ACP
    /// bundle. Never scan another app's tool or account directories.
    public static func detectedExecutable(for configuration: AIProviderConfiguration) -> String? {
        if isInstalled(configuration) { return configuration.executablePath }
        if configuration.provider == .antigravity, !configuration.harnessPath.isEmpty {
            let bundle = URL(fileURLWithPath: configuration.harnessPath).deletingLastPathComponent()
            for name in ["agy_acp_server.par", "antigravity-acp"] {
                let candidate = bundle.appendingPathComponent(name).path
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        let candidate = executable(configuration.provider)
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    public static func installedVersion(_ provider: NotesAIProvider, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard let raw = try? String(contentsOf: root(home: home).appendingPathComponent(provider.rawValue + "/current/version"), encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    public static func supportsInstallation(_ provider: NotesAIProvider) -> Bool { provider != .antigravity }
    private func package(_ provider: NotesAIProvider) throws -> String {
        switch provider {
        case .codexCLI: return "@openai/codex"
        case .claudeCode: return "@anthropic-ai/claude-code"
        case .openCode: return "opencode-ai"
        case .antigravity: throw MediaError.invalid("Select an existing Antigravity ACP installation and profile.")
        }
    }
    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw MediaError.invalid("Provider download failed. Try again later.") }
        try Task.checkCancellation()
        return data
    }
    public func latestVersion(_ provider: NotesAIProvider) async throws -> String {
        let package = try package(provider)
        let data = try await fetch(URL(string: "https://registry.npmjs.org/\(package)/latest")!)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let version = object["version"] as? String,
              version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+([-.][a-zA-Z0-9.-]+)?$", options: .regularExpression) != nil else { throw MediaError.invalid("Invalid provider version.") }
        return version
    }
    private func run(_ executable: String, _ arguments: [String], nodeBin: URL? = nil) async throws {
        try Task.checkCancellation()
        let command = NotesProcess(timeoutInterval: 300)
        command.process.executableURL = URL(fileURLWithPath: executable)
        command.process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if let nodeBin { environment["PATH"] = nodeBin.path + ":/usr/bin:/bin:/usr/sbin:/sbin" }
        command.process.environment = environment
        _ = try await withTaskCancellationHandler { try await Task.detached { try command.run() }.value } onCancel: { command.cancel() }
    }
    public func prepare(_ configuration: AIProviderConfiguration) async throws {
        guard !FileManager.default.isExecutableFile(atPath: configuration.executablePath),
              configuration.executablePath == Self.managedExecutable(configuration.provider),
              Self.supportsInstallation(configuration.provider) else { return }
        _ = try await install(configuration.provider)
    }
    private var installing = false
    public func install(_ provider: NotesAIProvider, progress: @escaping @Sendable (ProviderInstallStage) -> Void = { _ in }) async throws -> String {
        guard !installing else { throw MediaError.invalid("A provider installation is already running.") }
        installing = true
        defer { installing = false }
        let package = try package(provider)
        progress(.checkingVersion)
        let version = try await latestVersion(provider)
        let root = Self.root()
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let node = root.appendingPathComponent("node")
        if !fm.isExecutableFile(atPath: node.appendingPathComponent("bin/node").path) {
            struct Release: Decodable { let version: String; let lts: LTS
                enum LTS: Decodable { case no, yes
                    init(from decoder: Decoder) throws { let value = try decoder.singleValueContainer(); self = (try? value.decode(String.self)) != nil ? .yes : .no }
                }
            }
            progress(.downloadingRuntime(.init(received: 0, total: 0)))
            let releases = try JSONDecoder().decode([Release].self, from: await fetch(URL(string: "https://nodejs.org/dist/index.json")!))
            guard let release = releases.first(where: { if case .yes = $0.lts { return true }; return false }), release.version.range(of: "^v[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else { throw MediaError.invalid("No Node LTS release available.") }
            #if arch(arm64)
            let architecture = "arm64"
            #else
            let architecture = "x64"
            #endif
            let filename = "node-\(release.version)-darwin-\(architecture).tar.gz"
            let base = "https://nodejs.org/dist/\(release.version)/"
            let (downloadedFile, downloadResponse) = try await ProgressDownload.run(URL(string: base + filename)!, expected: 45_000_000) { progress(.downloadingRuntime($0)) }
            defer { try? fm.removeItem(at: downloadedFile) }
            guard (downloadResponse as? HTTPURLResponse)?.statusCode == 200 else { throw MediaError.invalid("Provider download failed. Try again later.") }
            progress(.verifyingRuntime)
            let archive = try Data(contentsOf: downloadedFile)
            let checksums = String(decoding: try await fetch(URL(string: base + "SHASUMS256.txt")!), as: UTF8.self)
            let hash = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
            guard checksums.split(separator: "\n").contains(where: { $0.split(whereSeparator: \.isWhitespace).map(String.init) == [hash, filename] }) else { throw MediaError.invalid("Node download checksum mismatch.") }
            let staging = root.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            let file = staging.appendingPathComponent(filename)
            try archive.write(to: file)
            try await run("/usr/bin/tar", ["-xzf", file.path, "-C", staging.path])
            try Task.checkCancellation()
            try fm.moveItem(at: staging.appendingPathComponent(String(filename.dropLast(7))), to: node)
        }
        try Task.checkCancellation()
        progress(.installingPackage(version: version))
        let destination = root.appendingPathComponent(provider.rawValue)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let staging = destination.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: staging) }
        let nodeBin = node.appendingPathComponent("bin")
        try await run(nodeBin.appendingPathComponent("node").path, [node.appendingPathComponent("lib/node_modules/npm/bin/npm-cli.js").path, "install", "--prefix", staging.path, "--no-audit", "--no-fund", package + "@" + version], nodeBin: nodeBin)
        try Data(version.utf8).write(to: staging.appendingPathComponent("version"))
        let bin = staging.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let target = bin.appendingPathComponent(Self.name(provider))
        // A launcher supplies the private Node runtime even in GUI environments.
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let releasePath = destination.appendingPathComponent("release-" + UUID().uuidString)
        let script = "#!/bin/sh\nexport PATH=\(quote(nodeBin.path)):/usr/bin:/bin:/usr/sbin:/sbin\nexec \(quote(releasePath.appendingPathComponent("node_modules/.bin/" + Self.name(provider)).path)) \"$@\"\n"
        try Data(script.utf8).write(to: target)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        progress(.verifyingInstallation(version: version))
        try await run(staging.appendingPathComponent("node_modules/.bin/" + Self.name(provider)).path, ["--version"], nodeBin: nodeBin)
        try Task.checkCancellation()
        try fm.moveItem(at: staging, to: releasePath)
        let link = destination.appendingPathComponent("next-" + UUID().uuidString)
        try fm.createSymbolicLink(at: link, withDestinationURL: releasePath)
        let current = destination.appendingPathComponent("current")
        // POSIX rename atomically replaces the old symlink; active processes retain their release.
        guard rename(link.path, current.path) == 0 else { try? fm.removeItem(at: link); throw MediaError.invalid("Could not activate provider installation.") }
        return Self.managedExecutable(provider)
    }
}
