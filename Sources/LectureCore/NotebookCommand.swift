import Foundation

public struct NotebookCommand: Codable, Equatable, Sendable {
    public var command: String
    public var workingDirectory: String
    public var timeoutSeconds: Int
    public init(command: String, workingDirectory: String = "", timeoutSeconds: Int = 120) {
        self.command = command; self.workingDirectory = workingDirectory; self.timeoutSeconds = timeoutSeconds
    }
}

public struct NotebookCommandResult: Codable, Sendable {
    public var command: NotebookCommand
    public var output: String
    public var exitCode: Int32?
    public var error: String?
    public init(command: NotebookCommand, output: String = "", exitCode: Int32? = nil, error: String? = nil) {
        self.command = command; self.output = output; self.exitCode = exitCode; self.error = error
    }
}

extension AIEditAutonomy {
    public var approvesFileChanges: Bool { self != .review }

    /// Auto approves only these exact, argument-free inspections. Everything
    /// else receives a concrete approval prompt; shell syntax cannot escape it.
    public func approvesCommand(_ command: NotebookCommand) -> Bool {
        if self == .fullAccess { return true }
        guard self == .automatic || self == .additions else { return false }
        return ["pwd", "/bin/pwd", "/bin/ls", "/bin/ls -la"].contains(command.command)
    }
}

public enum NotebookCommandRunner {
    public static func run(_ command: NotebookCommand, defaultDirectory: URL) async throws -> NotebookCommandResult {
        guard !command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MediaError.invalid("Empty command.")
        }
        let directory = command.workingDirectory.isEmpty ? defaultDirectory : URL(fileURLWithPath: command.workingDirectory, relativeTo: defaultDirectory).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MediaError.invalid("Command working directory does not exist: " + directory.path)
        }
        let task = NotesProcess(timeoutInterval: TimeInterval(min(max(command.timeoutSeconds, 1), 600)))
        task.acceptsNonzeroExit = true
        task.captureStandardError = true
        task.outputLimit = 256_000
        task.process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.process.arguments = ["-f", "-c", command.command]
        task.process.currentDirectoryURL = directory
        task.process.standardInput = FileHandle.nullDevice
        let inherited = ProcessInfo.processInfo.environment
        var environment = inherited.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL", "PATH"].contains($0.key) }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        task.process.environment = environment
        return try await withTaskCancellationHandler {
            let output = try await Task.detached { try task.run() }.value
            try Task.checkCancellation()
            let text = String(decoding: output.prefix(64_000), as: UTF8.self)
                + (output.count > 64_000 ? "\n[Output truncated to 64000 bytes.]" : "")
            return .init(command: command, output: text, exitCode: task.process.terminationStatus)
        } onCancel: { task.cancel() }
    }
}
