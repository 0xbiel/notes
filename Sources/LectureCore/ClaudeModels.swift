import Foundation

/// Claude Code has no model-list command, so the catalog is bundled. Adapted
/// from T3 Code's model manifest (version 1, 2026-10-09): a model appears once
/// the installed CLI reaches its minimum version.
public struct ClaudeModel: Sendable {
    public let id: String
    public let name: String
    public var legacy = false
    public var minimumVersion: String? = nil
    public var efforts: [String] = []
    public var defaultEffort: String? = nil
    public var fastMode = false
    /// Effort names the CLI spells differently for this model.
    public var effortMap: [String: String] = [:]
    public var apiSuffix = ""

    public static let defaultID = "claude-fable-5-1"
    private static let wide = ["low", "medium", "high", "xhigh", "max"]
    private static let narrow = ["low", "medium", "high", "max"]
    public static let all: [ClaudeModel] = [
        .init(id: "claude-fable-5-1", name: "Claude Fable 5.1", minimumVersion: "2.1.257", efforts: wide, defaultEffort: "medium"),
        .init(id: "claude-opus-5-5", name: "Claude Opus 5.5", minimumVersion: "2.1.280", efforts: wide, defaultEffort: "medium", fastMode: true),
        .init(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5", minimumVersion: "2.1.284", efforts: wide, defaultEffort: "high"),
        .init(id: "claude-haiku-5-5", name: "Claude Haiku 5.5", minimumVersion: "2.1.293", efforts: wide, defaultEffort: "medium"),
        .init(id: "claude-fable-5", name: "Claude Fable 5", legacy: true, minimumVersion: "2.1.169", efforts: wide, defaultEffort: "medium"),
        .init(id: "claude-opus-5", name: "Claude Opus 5", legacy: true, minimumVersion: "2.1.219", efforts: wide, defaultEffort: "high", fastMode: true),
        .init(id: "claude-opus-4-8", name: "Claude Opus 4.8", legacy: true, minimumVersion: "2.1.154", efforts: wide, defaultEffort: "high", fastMode: true),
        .init(id: "claude-opus-4-7", name: "Claude Opus 4.7", legacy: true, minimumVersion: "2.1.111", efforts: wide, defaultEffort: "xhigh", fastMode: true, effortMap: ["xhigh": "max"]),
        .init(id: "claude-opus-4-6", name: "Claude Opus 4.6", legacy: true, efforts: narrow, defaultEffort: "high", fastMode: true, apiSuffix: "[1m]"),
        .init(id: "claude-opus-4-5", name: "Claude Opus 4.5", legacy: true, efforts: narrow, defaultEffort: "high", fastMode: true),
        .init(id: "claude-sonnet-5", name: "Claude Sonnet 5", legacy: true, efforts: wide, defaultEffort: "high"),
        .init(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", legacy: true, efforts: narrow, defaultEffort: "high", effortMap: ["max": "high"]),
        .init(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", legacy: true)
    ]

    public static func supported(by version: String?) -> [ClaudeModel] {
        all.filter { model in
            guard let minimum = model.minimumVersion else { return true }
            guard let version else { return false }
            return version.compare(minimum, options: .numeric) != .orderedAscending
        }
    }

    public static func catalog(version: String?) -> [AIProviderModel] {
        supported(by: version).map { model in
            var entry = AIProviderModel(id: model.id, name: model.name, detail: model.legacy ? "Legacy" : "", isDefault: model.id == defaultID, reasoning: model.efforts, supportsFastMode: model.fastMode)
            entry.defaultReasoningEffort = model.defaultEffort
            return entry
        }
    }

    /// The `--model` and `--effort` values for a configured selection. Custom
    /// and router models pass through unchanged.
    public static func selection(_ configuration: AIProviderConfiguration) -> (model: String?, effort: String?) {
        let known = all.first { $0.id == configuration.model }
        let effort = configuration.reasoningEffort.map { known?.effortMap[$0] ?? $0 }
        if configuration.model == "default" { return (nil, effort) }
        return (configuration.model + (known?.apiSuffix ?? ""), effort)
    }

    /// `claude --version` prints "2.1.296 (Claude Code)".
    public static func version(from output: String) -> String? {
        output.split(whereSeparator: { $0.isWhitespace }).map(String.init).first { $0.range(of: #"^\d+\.\d+\.\d+"#, options: .regularExpression) != nil }
    }
}
