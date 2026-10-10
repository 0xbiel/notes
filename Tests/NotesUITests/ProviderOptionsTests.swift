import XCTest
import SwiftUI
import LectureCore
@testable import Notes

final class ProviderOptionsTests: XCTestCase {
    @MainActor private func environment() throws -> (Workbench, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/ProviderOptions-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        try Data("# Inicio\n\nNota inventada.\n".utf8).write(to: root.appendingPathComponent("copied-course/Inicio.md"))
        try JSONSerialization.data(withJSONObject: ["originalRoot": root.appendingPathComponent("original").path]).write(to: root.appendingPathComponent("original-hashes.json"))
        let model = Workbench(workspaceRoot: root)
        XCTAssertNil(model.errorText)
        return (model, root)
    }

    /// A dictionary standing in for the Keychain.
    @MainActor private final class Secrets {
        var values: [String: String] = [:]
        func attach(_ preferences: ProviderPreferencesModel) {
            preferences.readSecret = { [self] provider, name in values[provider.rawValue + "/" + name] }
            preferences.writeSecret = { [self] value, provider, name in values[provider.rawValue + "/" + name] = value.isEmpty ? nil : value }
        }
    }

    @MainActor func testEnvironmentVariablesKeepSensitiveValuesOutOfSavedSettings() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let ai = try XCTUnwrap(model.ai)
        let preferences = ProviderPreferencesModel(ai: ai)
        let secrets = Secrets(); secrets.attach(preferences)
        preferences.draft.selectedProvider = .claudeCode
        XCTAssertTrue(preferences.addVariable(name: "ANTHROPIC_BASE_URL", value: "https://router.invalid/api", sensitive: false))
        XCTAssertTrue(preferences.addVariable(name: "ANTHROPIC_AUTH_TOKEN", value: "invented-token", sensitive: true))
        XCTAssertFalse(preferences.addVariable(name: "ANTHROPIC_BASE_URL", value: "again", sensitive: false))
        XCTAssertFalse(preferences.addVariable(name: "NOT VALID", value: "", sensitive: false))
        XCTAssertFalse(preferences.addVariable(name: "EMPTY_SECRET", value: "", sensitive: true))
        XCTAssertNotNil(preferences.error)
        XCTAssertEqual(preferences.draft.claudeCode.environment?.map(\.name), ["ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN"])
        XCTAssertEqual(secrets.values, ["claudeCode/env/ANTHROPIC_AUTH_TOKEN": "invented-token"])
        XCTAssertTrue(preferences.hasSecret(ProviderSecrets.environmentName("ANTHROPIC_AUTH_TOKEN")))

        preferences.save()
        let stored = String(decoding: try XCTUnwrap(model.workspace).readStorage("ai-provider-settings.json"), as: UTF8.self)
        XCTAssertTrue(stored.contains("ANTHROPIC_AUTH_TOKEN"))
        XCTAssertFalse(stored.contains("invented-token"))

        preferences.setVariable("ANTHROPIC_BASE_URL", value: "https://other.invalid")
        preferences.setVariable("ANTHROPIC_AUTH_TOKEN", value: "rotated-token")
        XCTAssertEqual(preferences.draft.claudeCode.environment?.first?.value, "https://other.invalid")
        XCTAssertEqual(preferences.draft.claudeCode.environment?.last?.value, "")
        XCTAssertEqual(secrets.values["claudeCode/env/ANTHROPIC_AUTH_TOKEN"], "rotated-token")

        // A second model, as another settings view would create, finds the stored secret.
        let reopened = ProviderPreferencesModel(ai: ai)
        secrets.attach(reopened)
        XCTAssertFalse(reopened.hasSecret(ProviderSecrets.environmentName("ANTHROPIC_AUTH_TOKEN")))
        reopened.refreshSecrets()
        XCTAssertTrue(reopened.hasSecret(ProviderSecrets.environmentName("ANTHROPIC_AUTH_TOKEN")))

        preferences.removeVariable("ANTHROPIC_AUTH_TOKEN")
        preferences.removeVariable("ANTHROPIC_BASE_URL")
        XCTAssertNil(preferences.draft.claudeCode.environment)
        XCTAssertTrue(secrets.values.isEmpty)
    }

    @MainActor func testReasoningAndCustomModelsFollowTheProviderCapabilities() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let preferences = ProviderPreferencesModel(ai: try XCTUnwrap(model.ai))
        preferences.draft.selectedProvider = .claudeCode
        preferences.addCustomModel("openai/router-model")
        XCTAssertNil(preferences.error)
        XCTAssertEqual(preferences.draft.claudeCode.model, "openai/router-model")
        // A custom model publishes no reasoning levels, so no selector is offered.
        XCTAssertNil(preferences.reasoningModel)
        XCTAssertNil(preferences.fastModeSelection)
        preferences.draft.selectedProvider = .openCode
        preferences.addCustomModel("another/model")
        XCTAssertNotNil(preferences.error)
        XCTAssertEqual(preferences.draft.openCode.model, OpenRouterHarness.model)
        preferences.draft.selectedProvider = .antigravity
        preferences.option(\.gcpProject).wrappedValue = "invented-project"
        XCTAssertEqual(preferences.draft.antigravity.gcpProject, "invented-project")
        preferences.option(\.gcpProject).wrappedValue = ""
        XCTAssertNil(preferences.draft.antigravity.gcpProject)
    }

    /// Set NOTES_DICTATION_SCREENSHOT to a PNG path to keep the render.
    @MainActor func testDictationPreferencesShowDownloadProgressAndOptions() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let media = try XCTUnwrap(model.media)
        media.transcriptionProvider = .local
        media.modelOperation = "Descargando y verificando modelo…"
        media.modelDownload = (.small, DownloadProgress(received: 312_000_000, total: 487_601_967))
        XCTAssertEqual(TranscriptionPreferences.describe(media.modelDownload!.progress, language: "es"), "312 MB de 487,6 MB · 63 %".replacingOccurrences(of: ",", with: Locale.current.decimalSeparator ?? ","))
        XCTAssertEqual(TranscriptionPreferences.describe(.init(received: 10, total: 10), language: "en"), "Verifying…")
        let host = NSHostingView(rootView: TranscriptionPreferences(media: media).frame(width: 680).padding(24)
            .background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 300)
        if let path = ProcessInfo.processInfo.environment["NOTES_DICTATION_SCREENSHOT"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    /// Set NOTES_PROVIDERS_SCREENSHOT to a directory to keep the renders.
    @MainActor func testProvidersScreenLaysOutEveryProviderInBothAppearances() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let ai = try XCTUnwrap(model.ai)
        var settings = ai.providerSettings
        settings.selectedProvider = .claudeCode
        settings.claudeCode.displayName = "Claude Personal"
        settings.claudeCode.accentColor = ProviderAccent.presets[5]
        settings.claudeCode.environment = [.init(name: "ANTHROPIC_BASE_URL", value: "https://router.invalid/api"), .init(name: "ANTHROPIC_AUTH_TOKEN", sensitive: true)]
        settings.antigravity.accountSendingAllowed = false
        try ai.saveProviderSettings(settings)
        let output = ProcessInfo.processInfo.environment["NOTES_PROVIDERS_SCREENSHOT"].map { URL(fileURLWithPath: $0) }
        func render(_ name: String, dark: Bool, @ViewBuilder _ content: () -> some View) throws -> CGSize {
            let host = NSHostingView(rootView: content().frame(width: 680).padding(24)
                .background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            if let output {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + (dark ? "-dark" : "-light") + ".png"))
            }
            return host.fittingSize
        }
        for dark in [false, true] {
            let screen = try render("providers", dark: dark) { ProviderPreferences(ai: ai) }
            // One 56-point row per provider, then the editor.
            XCTAssertGreaterThan(screen.height, CGFloat(NotesAIProvider.allCases.count) * 56 + 200)
            for provider in NotesAIProvider.allCases {
                let preferences = ProviderPreferencesModel(ai: ai)
                preferences.readSecret = { _, _ in "stored" }
                preferences.draft.selectedProvider = provider
                if provider == .antigravity { preferences.draft.antigravity.authMethod = AntigravityAuthMethod.agentPlatform.rawValue }
                preferences.refreshSecrets()
                let fields = try render("options-" + provider.rawValue, dark: dark) {
                    VStack(alignment: .leading, spacing: 18) {
                        ProviderIdentityFields(preferences: preferences)
                        ProviderRuntimeFields(preferences: preferences)
                        ProviderEnvironmentFields(preferences: preferences)
                    }
                }
                XCTAssertGreaterThan(fields.height, 200, provider.rawValue)
            }
        }
    }
}
