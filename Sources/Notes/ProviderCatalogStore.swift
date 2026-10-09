import Foundation
import Combine
import LectureCore

struct ProviderCatalogKey: Codable, Hashable {
    let provider: NotesAIProvider
    let executable: String
    let home: String
    let harness: String
    init(_ configuration: AIProviderConfiguration) {
        provider = configuration.provider
        executable = configuration.executablePath
        home = configuration.homePath
        harness = configuration.harnessPath
    }
}

/// One catalog per provider/account, shared by every selector in this workspace.
/// Cached metadata is shown immediately; background failures never erase it.
@MainActor final class ProviderCatalogStore: ObservableObject {
    struct Entry: Codable, Equatable {
        let key: ProviderCatalogKey
        let fetchedAt: Date
        let models: [AIProviderModel]
    }
    static let refreshInterval: TimeInterval = 60 * 60
    @Published private(set) var entries: [NotesAIProvider: Entry] = [:]
    private let workspace: SafeWorkspace
    private let fetch: (AIProviderConfiguration) async throws -> [AIProviderModel]
    private var pending: [ProviderCatalogKey: Task<[AIProviderModel], Error>] = [:]
    private var requested: [NotesAIProvider: ProviderCatalogKey] = [:]
    private var failures: [ProviderCatalogKey: (Date, String)] = [:]

    init(workspace: SafeWorkspace, fetch: @escaping (AIProviderConfiguration) async throws -> [AIProviderModel]) {
        self.workspace = workspace; self.fetch = fetch
        if let data = try? workspace.readStorage("ai-model-catalogs.json"),
           let cached = try? JSONDecoder().decode([Entry].self, from: data) {
            for entry in cached { entries[entry.key.provider] = entry }
        }
    }

    func models(for configuration: AIProviderConfiguration) -> [AIProviderModel]? {
        guard let entry = entries[configuration.provider], entry.key == ProviderCatalogKey(configuration) else { return nil }
        return entry.models
    }

    @discardableResult
    func refresh(_ configuration: AIProviderConfiguration, force: Bool = false, now: Date = Date()) async throws -> [AIProviderModel] {
        let key = ProviderCatalogKey(configuration)
        requested[key.provider] = key
        guard configuration.accountSendingAllowed else { return models(for: configuration) ?? [] }
        if let task = pending[key] { return try await task.value }
        if !force, let entry = entries[key.provider], entry.key == key,
           now.timeIntervalSince(entry.fetchedAt) < Self.refreshInterval { return entry.models }
        if !force, let (failedAt, message) = failures[key], now.timeIntervalSince(failedAt) < 300 {
            if let cached = models(for: configuration) { return cached }
            throw MediaError.invalid(message)
        }
        let task = Task { [self] in
            defer { pending.removeValue(forKey: key) }
            do {
                let models = try await fetch(configuration)
                guard !models.isEmpty else { throw MediaError.invalid("El proveedor no devolvió modelos disponibles.") }
                failures.removeValue(forKey: key)
                if requested[key.provider] == key {
                    entries[key.provider] = Entry(key: key, fetchedAt: now, models: models)
                    try workspace.writeStorage("ai-model-catalogs.json", data: JSONEncoder().encode(Array(entries.values)))
                }
                return models
            } catch {
                failures[key] = (now, error.localizedDescription)
                throw error
            }
        }
        pending[key] = task
        return try await task.value
    }
}
