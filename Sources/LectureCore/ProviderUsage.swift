import Foundation

/// Tokens one provider request consumed, as the provider reported them.
/// `input` excludes cached tokens; `output` includes reasoning.
public struct ProviderTokenUsage: Codable, Sendable, Equatable {
    public var model: String
    public var input = 0
    public var cachedInput = 0
    public var cacheWrite = 0
    public var output = 0
    /// API-price cost the provider computed itself (Claude Code).
    public var reportedCost: Double?
    /// The provider reported nothing; counts come from the text length.
    public var estimated: Bool?
    public init(model: String, input: Int = 0, cachedInput: Int = 0, cacheWrite: Int = 0, output: Int = 0, reportedCost: Double? = nil, estimated: Bool? = nil) {
        self.model = model; self.input = max(0, input); self.cachedInput = max(0, cachedInput); self.cacheWrite = max(0, cacheWrite); self.output = max(0, output)
        self.reportedCost = reportedCost; self.estimated = estimated
    }
    public var tokens: Int { input + cachedInput + cacheWrite + output }

    static func count(_ value: Any?) -> Int { max(0, (value as? NSNumber)?.intValue ?? 0) }
    /// Roughly four characters per token; images are not counted.
    static func approximate(model: String, prompt: String, output: String) -> ProviderTokenUsage {
        .init(model: model, input: (prompt.utf8.count + 3) / 4, output: (output.utf8.count + 3) / 4, estimated: true)
    }
}

public struct ProviderUsageRecord: Codable, Sendable, Equatable {
    public var id: String?
    public var date: Date
    public var provider: NotesAIProvider?
    public var notebookID: String
    public var usage: ProviderTokenUsage
    public init(id: String? = UUID().uuidString, date: Date, provider: NotesAIProvider?, notebookID: String, usage: ProviderTokenUsage) {
        self.id = id; self.date = date; self.provider = provider; self.notebookID = notebookID; self.usage = usage
    }
}

/// Gathers the usage of one request from the provider's reader thread.
final class ProviderUsageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProviderTokenUsage] = []
    func add(_ usage: ProviderTokenUsage) { lock.lock(); if usage.tokens > 0 { values.append(usage) }; lock.unlock() }
    func drain() -> [ProviderTokenUsage] { lock.lock(); defer { values = []; lock.unlock() }; return values }
}

/// Usage of the requests Palladium itself sent, one JSON line each. Provider
/// sessions are ephemeral, so this is the only record; nothing is read from the
/// providers' own histories.
public struct ProviderUsageLog {
    public static let path = "usage/provider-usage.jsonl"
    private static let lock = NSLock()
    let workspace: SafeWorkspace
    public init(workspace: SafeWorkspace) { self.workspace = workspace }
    public init(store: LocalMediaStore) throws { workspace = try SafeWorkspace(root: store.root, originalRoot: store.originalRoot) }

    private static var encoder: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.sortedKeys]; return encoder }
    private static var decoder: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970; return decoder }

    public func append(_ records: [ProviderUsageRecord]) throws {
        guard !records.isEmpty else { return }
        Self.lock.lock(); defer { Self.lock.unlock() }
        var data = try existingData()
        if !data.isEmpty, data.last != 10 { data.append(10) }
        var identifiers = Set(decode(data).compactMap(\.id))
        for record in records {
            if let id = record.id, !identifiers.insert(id).inserted { continue }
            data.append(try Self.encoder.encode(record)); data.append(10)
        }
        try workspace.writeStorage(Self.path, data: data)
    }

    private func existingData() throws -> Data {
        guard FileManager.default.fileExists(atPath: workspace.storageRoot.appendingPathComponent(Self.path).path) else { return Data() }
        return try workspace.readStorage(Self.path)
    }

    private func decode(_ data: Data) -> [ProviderUsageRecord] {
        var identifiers: Set<String> = []
        return data.split(separator: 10).compactMap {
            guard let record = try? Self.decoder.decode(ProviderUsageRecord.self, from: Data($0)) else { return nil }
            if let id = record.id, !identifiers.insert(id).inserted { return nil }
            return record
        }
    }

    public func cacheHistory(_ state: NotebookProjectState, notebookID: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var data = try existingData()
        let original = data
        if !data.isEmpty, data.last != 10 { data.append(10) }
        let recorded = decode(data)
        var identifiers = Set(recorded.compactMap(\.id))
        for chat in state.chats {
            var user: NotebookMessage?
            for message in chat.messages {
                if message.role == "user" { user = message; continue }
                guard message.role == "assistant", let prompt = user else { continue }
                user = nil
                let id = "history:" + prompt.id
                guard prompt.usageTracked != true, identifiers.insert(id).inserted else { continue }
                guard !recorded.contains(where: { $0.provider != nil && $0.notebookID == notebookID && $0.date >= prompt.date && $0.date <= message.date }) else { continue }
                let record = ProviderUsageRecord(id: id, date: message.date, provider: nil, notebookID: notebookID,
                    usage: .approximate(model: "Historical chat (model unknown)", prompt: prompt.text, output: message.text))
                data.append(try Self.encoder.encode(record)); data.append(10)
            }
        }
        if data != original { try workspace.writeStorage(Self.path, data: data) }
    }

    /// Unreadable lines are skipped rather than hiding the rest.
    public func records() -> [ProviderUsageRecord] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let data = try? workspace.readStorage(Self.path) else { return [] }
        return decode(data)
    }
}

/// USD per million tokens.
public struct ProviderModelRate: Codable, Sendable, Equatable {
    public var input: Double
    public var cachedInput: Double
    public var cacheWrite: Double
    public var output: Double
    public init(input: Double, cachedInput: Double? = nil, cacheWrite: Double? = nil, output: Double) {
        self.input = input; self.cachedInput = cachedInput ?? input; self.cacheWrite = cacheWrite ?? input; self.output = output
    }
    public func cost(_ usage: ProviderTokenUsage) -> Double {
        (Double(usage.input) * input + Double(usage.cachedInput) * cachedInput + Double(usage.cacheWrite) * cacheWrite + Double(usage.output) * output) / 1_000_000
    }
}

/// Public API list prices, the same LiteLLM table T3 Code prices usage with.
public enum ProviderUsagePricing {
    public static let source = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    public static let cachePath = "usage/model-rates.json"

    public struct Cache: Codable, Sendable, Equatable {
        public var fetched: Date
        public var rates: [String: ProviderModelRate]
    }

    public static let builtIn: [String: ProviderModelRate] = [
        "claude-fable-5-1": .init(input: 10, cachedInput: 0.25, cacheWrite: 12.5, output: 50),
        "claude-opus-5-5": .init(input: 4, cachedInput: 0.2, cacheWrite: 5, output: 20),
        "claude-sonnet-5-5": .init(input: 2, cachedInput: 0.1, cacheWrite: 2.5, output: 10),
        "claude-haiku-5-5": .init(input: 0.1, cachedInput: 0.01, cacheWrite: 0.125, output: 0.5),
        "claude-fable-5": .init(input: 10, cachedInput: 1, cacheWrite: 12.5, output: 50),
        "claude-opus-5": .init(input: 5, cachedInput: 0.5, cacheWrite: 6.25, output: 25),
        "claude-opus-4-8": .init(input: 5, cachedInput: 0.5, cacheWrite: 6.25, output: 25),
        "claude-opus-4-7": .init(input: 5, cachedInput: 0.5, cacheWrite: 6.25, output: 25),
        "claude-opus-4-6": .init(input: 5, cachedInput: 0.5, cacheWrite: 6.25, output: 25),
        "claude-opus-4-5": .init(input: 5, cachedInput: 0.5, cacheWrite: 6.25, output: 25),
        "claude-sonnet-5": .init(input: 2, cachedInput: 0.2, cacheWrite: 2.5, output: 10),
        "claude-sonnet-4-6": .init(input: 3, cachedInput: 0.3, cacheWrite: 3.75, output: 15),
        "claude-haiku-4-5": .init(input: 1, cachedInput: 0.1, cacheWrite: 1.25, output: 5),
        "gpt-6-luna": .init(input: 0.1, cachedInput: 0.01, cacheWrite: 0.125, output: 0.5),
        "gpt-6-sol": .init(input: 2, cachedInput: 0.2, cacheWrite: 2.5, output: 10),
        "gpt-6.1-sol": .init(input: 2, cachedInput: 0.1, cacheWrite: 2.5, output: 10),
        "gpt-6-astra": .init(input: 10, cachedInput: 1, cacheWrite: 12.5, output: 50),
        "gpt-5.6-luna": .init(input: 0.2, cachedInput: 0.02, cacheWrite: 0.25, output: 1.2),
        "gpt-5.6-sol": .init(input: 4, cachedInput: 0.4, cacheWrite: 5, output: 20),
        "gpt-5.6-terra": .init(input: 2, cachedInput: 0.2, cacheWrite: 2.5, output: 12),
        "gemini-3.8-flash": .init(input: 0.75, cachedInput: 0.075, output: 3.75),
        "gemini-3.7-flash": .init(input: 0.75, cachedInput: 0.075, output: 3.75),
        "gemini-3.6-flash": .init(input: 0.75, cachedInput: 0.075, output: 3.75),
        "gemini-3.5-flash": .init(input: 1.5, cachedInput: 0.15, output: 9),
        "gemini-3.5-flash-lite": .init(input: 0.3, cachedInput: 0.03, output: 2.5),
        "gemini-3.1-flash-lite": .init(input: 0.25, cachedInput: 0.025, output: 1.5),
        "gemini-3.1-pro-preview": .init(input: 2, cachedInput: 0.2, output: 12),
        "gemini-3-flash-preview": .init(input: 0.5, cachedInput: 0.05, output: 3)
    ]

    /// Names a model may be listed under: without its provider prefix, context
    /// suffix (`[1m]`), release date or reasoning level (`-high`).
    static func candidates(_ model: String) -> [String] {
        var name = model.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        var result = [name]
        if let range = name.range(of: #"-\d{8}$"#, options: .regularExpression) { name.removeSubrange(range); result.append(name) }
        for level in ["-minimal", "-low", "-medium", "-high", "-xhigh", "-max"] where name.hasSuffix(level) { result.append(String(name.dropLast(level.count))) }
        return result
    }

    public static func rate(for model: String, rates: [String: ProviderModelRate] = builtIn) -> ProviderModelRate? {
        candidates(model).lazy.compactMap { rates[$0] }.first
    }

    /// The provider's own figure when it gave one; otherwise tokens × list price.
    public static func cost(_ usage: ProviderTokenUsage, rates: [String: ProviderModelRate] = builtIn) -> Double? {
        if let reported = usage.reportedCost, reported.isFinite, reported >= 0 { return reported }
        return rate(for: usage.model, rates: rates)?.cost(usage)
    }

    /// Keeps the first-party chat models of the three providers.
    public static func rates(fromLiteLLM data: Data) throws -> [String: ProviderModelRate] {
        guard let document = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MediaError.invalid("Tabla de precios inválida.") }
        var result: [String: ProviderModelRate] = [:]
        for (key, value) in document {
            guard let entry = value as? [String: Any], let provider = entry["litellm_provider"] as? String,
                  ["anthropic", "openai", "gemini", "vertex_ai-language-models"].contains(provider),
                  let input = (entry["input_cost_per_token"] as? NSNumber)?.doubleValue, let output = (entry["output_cost_per_token"] as? NSNumber)?.doubleValue,
                  input >= 0, output >= 0, input.isFinite, output.isFinite else { continue }
            let name = key.hasPrefix("gemini/") ? String(key.dropFirst(7)) : key
            guard !name.contains("/"), result[name] == nil || !key.contains("/") else { continue }
            func price(_ field: String) -> Double? { (entry[field] as? NSNumber).map { $0.doubleValue * 1_000_000 } }
            result[name.lowercased()] = .init(input: input * 1_000_000, cachedInput: price("cache_read_input_token_cost"), cacheWrite: price("cache_creation_input_token_cost"), output: output * 1_000_000)
        }
        guard !result.isEmpty else { throw MediaError.invalid("La tabla de precios no contiene modelos conocidos.") }
        return result
    }

    private static var coder: (JSONEncoder, JSONDecoder) {
        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .secondsSince1970; decoder.dateDecodingStrategy = .secondsSince1970
        return (encoder, decoder)
    }

    public static func cached(_ workspace: SafeWorkspace) -> Cache? {
        (try? workspace.readStorage(cachePath)).flatMap { try? coder.1.decode(Cache.self, from: $0) }
    }

    /// Downloaded prices override the built-in ones.
    public static func rates(_ workspace: SafeWorkspace) -> [String: ProviderModelRate] {
        builtIn.merging(cached(workspace)?.rates ?? [:]) { _, updated in updated }
    }

    /// Downloads the public price list. Only runs when the user asks for it.
    public static func download(session: URLSession = .shared) async throws -> Cache {
        var request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpShouldHandleCookies = false
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 16 * 1024 * 1024 else { throw MediaError.invalid("No se pudo descargar la tabla de precios.") }
        return Cache(fetched: Date(), rates: try rates(fromLiteLLM: data))
    }

    public static func save(_ cache: Cache, workspace: SafeWorkspace) throws {
        try workspace.writeStorage(cachePath, data: coder.0.encode(cache))
    }
}

/// Totals for one period, as the Usage preferences show them.
public struct ProviderUsageSummary: Sendable, Equatable {
    public struct Row: Sendable, Equatable, Identifiable {
        public var provider: NotesAIProvider?
        public var model: String
        public var requests = 0
        public var input = 0
        public var cachedInput = 0
        public var cacheWrite = 0
        public var output = 0
        public var cost = 0.0
        /// No list price is known for this model; its cost is not in the total.
        public var unpriced = false
        public var estimated = false
        public var id: String { (provider?.rawValue ?? "unknown") + "\u{0}" + model }
        public var tokens: Int { input + cachedInput + cacheWrite + output }
    }
    public struct Bucket: Sendable, Equatable, Identifiable {
        public var start: Date
        public var cost = 0.0
        public var tokens = 0
        public var id: Date { start }
    }

    public var rows: [Row] = []
    public var buckets: [Bucket] = []
    public var requests = 0
    public var input = 0
    public var cachedInput = 0
    public var cacheWrite = 0
    public var output = 0
    public var cost = 0.0
    public var unpricedTokens = 0
    public var estimatedTokens = 0
    public var tokens: Int { input + cachedInput + cacheWrite + output }
    /// Share of the input that was served from the provider's cache.
    public var cacheHit: Double { input + cachedInput + cacheWrite == 0 ? 0 : Double(cachedInput) / Double(input + cachedInput + cacheWrite) }

    /// `days == nil` covers everything recorded; one day is shown by the hour.
    public init(records: [ProviderUsageRecord], rates: [String: ProviderModelRate] = ProviderUsagePricing.builtIn, days: Int? = nil, now: Date = Date(), calendar: Calendar = .current) {
        let hourly = days == 1
        let unit: Calendar.Component = hourly ? .hour : .day
        func start(_ date: Date) -> Date { hourly ? calendar.dateInterval(of: .hour, for: date)?.start ?? date : calendar.startOfDay(for: date) }
        let last = start(now)
        let first: Date
        if let days { first = calendar.date(byAdding: unit, value: -(hourly ? 23 : days - 1), to: last) ?? last }
        else { first = records.map(\.date).min().map(start) ?? last }
        var grouped: [String: Row] = [:], bucketed: [Date: Bucket] = [:]
        for record in records where record.date >= first && record.date <= now {
            let usage = record.usage, price = ProviderUsagePricing.cost(usage, rates: rates)
            var row = grouped[(record.provider?.rawValue ?? "unknown") + "\u{0}" + usage.model] ?? Row(provider: record.provider, model: usage.model)
            row.requests += 1; row.input += usage.input; row.cachedInput += usage.cachedInput; row.cacheWrite += usage.cacheWrite; row.output += usage.output
            row.cost += price ?? 0
            if price == nil { row.unpriced = true; unpricedTokens += usage.tokens }
            if usage.estimated == true { row.estimated = true; estimatedTokens += usage.tokens }
            grouped[row.id] = row
            requests += 1; input += usage.input; cachedInput += usage.cachedInput; cacheWrite += usage.cacheWrite; output += usage.output; cost += price ?? 0
            let key = start(record.date)
            var bucket = bucketed[key] ?? Bucket(start: key)
            bucket.cost += price ?? 0; bucket.tokens += usage.tokens
            bucketed[key] = bucket
        }
        rows = grouped.values.sorted { ($0.cost, $0.tokens, $1.id) > ($1.cost, $1.tokens, $0.id) }
        var cursor = first
        // A long history is still drawn as one bar per day.
        while cursor <= last, buckets.count < 3_660 {
            buckets.append(bucketed[cursor] ?? Bucket(start: cursor))
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor), next > cursor else { break }
            cursor = hourly ? next : calendar.startOfDay(for: next)
        }
    }
}
