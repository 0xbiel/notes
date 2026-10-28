import XCTest
import SwiftUI
import Combine
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

    @MainActor func testUpdateChecksStayWithTheirProviderAndInvalidateWhenBinaryChanges() async throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let preferences = ProviderPreferencesModel(ai: try XCTUnwrap(model.ai))
        preferences.draft.selectedProvider = .codexCLI
        preferences.draft.codexCLI.executablePath = "/manual/codex"
        preferences.versions[.codexCLI] = "1.0.0"
        preferences.fetchLatestVersion = { [weak preferences] provider in
            XCTAssertEqual(provider, .codexCLI)
            preferences?.draft.selectedProvider = .claudeCode
            return "2.0.0"
        }
        await preferences.checkForUpdates()
        XCTAssertEqual(preferences.runtimeState(for: .codexCLI).latestVersion, "2.0.0")
        XCTAssertTrue(preferences.updateAvailable(for: .codexCLI))
        XCTAssertNil(preferences.runtimeState(for: .claudeCode).latestVersion)
        XCTAssertFalse(preferences.runtimeBusy)
        preferences.draft.codexCLI.executablePath = "/another/codex"
        XCTAssertNil(preferences.runtimeState(for: .codexCLI).latestVersion)
        XCTAssertNil(preferences.installedVersion(for: .codexCLI))
    }

    @MainActor func testDownloadProgressAndCancellationPreserveTheExistingPath() async throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let preferences = ProviderPreferencesModel(ai: try XCTUnwrap(model.ai))
        preferences.draft.selectedProvider = .codexCLI
        preferences.draft.codexCLI.executablePath = "/manual/codex"
        let published = AsyncStream<ProviderRuntimeState.Operation>.makeStream()
        let timeout = Task {
            try? await Task.sleep(for: .seconds(3))
            published.continuation.finish()
        }
        defer { timeout.cancel(); published.continuation.finish() }
        let progress = DownloadProgress(received: 12_000_000, total: 40_000_000)
        let subscription = preferences.$runtimeStates.sink { states in
            if let operation = states[.codexCLI]?.operation { published.continuation.yield(operation) }
        }
        defer { subscription.cancel() }
        preferences.performRuntimeInstall = { _, report in
            report(.downloadingRuntime(progress))
            try await Task.sleep(for: .seconds(30))
            return "/unused/codex"
        }
        preferences.startRuntimeInstallation()
        let task = try XCTUnwrap(preferences.runtimeTask)
        var receivedProgress = false
        for await operation in published.stream {
            if operation == .installing(.downloadingRuntime(progress)) { receivedProgress = true; break }
        }
        XCTAssertTrue(receivedProgress)
        // Browsing another provider must keep the first one's operation intact.
        preferences.draft.selectedProvider = .claudeCode
        XCTAssertNil(preferences.runtimeState(for: .claudeCode).operation)
        preferences.cancelRuntimeOperation()
        await task.value
        XCTAssertEqual(preferences.draft.codexCLI.executablePath, "/manual/codex")
        XCTAssertEqual(preferences.runtimeState(for: .codexCLI).outcome, .cancelled)
        XCTAssertNil(preferences.runtimeState(for: .codexCLI).error)
        XCTAssertNil(preferences.runtimeState(for: .codexCLI).operation)
        XCTAssertFalse(preferences.runtimeBusy)
    }

    @MainActor func testFailedInstallationCanRetryWithoutChangingAnotherProvider() async throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let ai = try XCTUnwrap(model.ai)
        let preferences = ProviderPreferencesModel(ai: ai)
        preferences.draft.selectedProvider = .codexCLI
        preferences.draft.codexCLI.executablePath = "/manual/codex"
        preferences.performRuntimeInstall = { _, _ in throw MediaError.invalid("Download unavailable") }
        await preferences.installRuntime()
        XCTAssertNotNil(preferences.runtimeState(for: .codexCLI).error)
        XCTAssertFalse(preferences.runtimeBusy)
        XCTAssertEqual(preferences.draft.codexCLI.executablePath, "/manual/codex")
        preferences.performRuntimeInstall = { [weak preferences] _, report in
            report(.verifyingInstallation(version: "2.0.0"))
            preferences?.draft.selectedProvider = .claudeCode
            return "/managed/codex"
        }
        await preferences.installRuntime()
        XCTAssertEqual(preferences.draft.selectedProvider, .claudeCode)
        XCTAssertEqual(ai.providerSettings.codexCLI.executablePath, "/managed/codex")
        XCTAssertEqual(preferences.runtimeState(for: .codexCLI).outcome, .installed)
        XCTAssertNil(preferences.runtimeState(for: .codexCLI).error)
        XCTAssertFalse(preferences.runtimeBusy)
    }

    @MainActor func testOpeningMissingProviderDoesNotStartAnInvisibleDownload() async throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let ai = try AIController(workspace: XCTUnwrap(model.workspace), editor: XCTUnwrap(model.editor),
                                  catalogFetch: { _ in XCTFail("Setup must use the visible download action"); return [] })
        let preferences = ProviderPreferencesModel(ai: ai)
        preferences.draft.codexCLI.executablePath = "/missing/codex"
        preferences.draft.selectedProvider = .codexCLI
        await preferences.refreshCatalogPeriodically()
        XCTAssertFalse(preferences.runtimeBusy)
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
        func render(_ name: String, dark: Bool, width: CGFloat = 680, @ViewBuilder _ content: () -> some View) throws -> CGSize {
            let host = NSHostingView(rootView: content().frame(width: width).padding(24)
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
            let screen = try render("providers", dark: dark, width: 1020) { ProviderPreferences(ai: ai).frame(height: 740) }
            XCTAssertEqual(screen.width, 1068, accuracy: 1)
            XCTAssertEqual(screen.height, 788, accuracy: 1)
            _ = try render("providers-medium", dark: dark, width: 720) { ProviderPreferences(ai: ai).frame(height: 740) }
            _ = try render("providers-compact", dark: dark, width: 540) { ProviderPreferences(ai: ai).frame(height: 740) }
            let runtime = ProviderPreferencesModel(ai: ai)
            runtime.draft.selectedProvider = .codexCLI
            runtime.draft.codexCLI.executablePath = "/missing/codex"
            let path = runtime.draft.codexCLI.executablePath
            let states: [(String, ProviderRuntimeState)] = [
                ("setup", .init(executablePath: path)),
                ("checking", .init(executablePath: path, operation: .checkingUpdates)),
                ("downloading", .init(executablePath: path, operation: .installing(.downloadingRuntime(.init(received: 12_000_000, total: 40_000_000))))),
                ("installing", .init(executablePath: path, operation: .installing(.installingPackage(version: "2.0.0")))),
                ("verifying", .init(executablePath: path, operation: .installing(.verifyingInstallation(version: "2.0.0")))),
                ("cancelled", .init(executablePath: path, outcome: .cancelled)),
                ("failed", .init(executablePath: path, error: "The download could not be completed. Check your connection and try again."))
            ]
            for (name, state) in states {
                runtime.runtimeStates[.codexCLI] = state
                let size = try render("installation-" + name, dark: dark) {
                    ProviderInstallationView(preferences: runtime, showAdvanced: {})
                }
                XCTAssertGreaterThan(size.height, 100)
                XCTAssertLessThan(size.height, 350)
                let narrow = try render("installation-" + name + "-narrow", dark: dark, width: 420) {
                    ProviderInstallationView(preferences: runtime, showAdvanced: {})
                }
                XCTAssertEqual(narrow.width, 468, accuracy: 1)
                XCTAssertLessThan(narrow.height, 450)
            }
            let binary = root.appendingPathComponent("mock-codex")
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
            runtime.draft.codexCLI.executablePath = binary.path
            runtime.versions[.codexCLI] = "1.0.0"
            for latest in ["1.0.0", "2.0.0"] {
                runtime.runtimeStates[.codexCLI] = .init(executablePath: binary.path, latestVersion: latest)
                _ = try render(latest == "1.0.0" ? "installation-current" : "installation-update", dark: dark) {
                    ProviderInstallationView(preferences: runtime, showAdvanced: {})
                }
            }
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
