import AppKit
import LectureCore

struct ProviderRuntimeState: Equatable {
    enum Operation: Equatable {
        case checkingUpdates
        case installing(ProviderInstallStage)
    }
    enum Attempt: Equatable { case install, checkUpdates }
    enum Outcome: Equatable { case installed, cancelled }
    var executablePath: String
    var operation: Operation?
    var latestVersion: String?
    var lastAttempt: Attempt?
    var outcome: Outcome?
    var error: String?
}

extension ProviderPreferencesModel {
    func runtimeState(for provider: NotesAIProvider) -> ProviderRuntimeState {
        let path = draft[provider].executablePath
        guard let state = runtimeStates[provider], state.executablePath == path else { return .init(executablePath: path) }
        return state
    }

    func invalidateRuntimePaths() {
        for provider in Array(runtimeStates.keys) where runtimeStates[provider]?.executablePath != draft[provider].executablePath {
            runtimeStates.removeValue(forKey: provider)
            checks.removeValue(forKey: provider)
            versions.removeValue(forKey: provider)
        }
    }

    func installedVersion(for provider: NotesAIProvider) -> String? {
        if ProviderRuntime.isManaged(draft[provider]) { return ProviderRuntime.installedVersion(provider) }
        return versions[provider]
    }

    func updateAvailable(for provider: NotesAIProvider) -> Bool {
        guard let latest = runtimeState(for: provider).latestVersion, let installed = installedVersion(for: provider) else { return false }
        return latest.compare(installed, options: .numeric) == .orderedDescending
    }

    func startRuntimeInstallation() {
        guard !runtimeBusy, runtimeTask == nil else { return }
        runtimeTask = Task { await installRuntime() }
    }

    func startUpdateCheck() {
        guard !runtimeBusy, runtimeTask == nil else { return }
        runtimeTask = Task { await checkForUpdates() }
    }

    func cancelRuntimeOperation() { runtimeTask?.cancel() }

    func checkForUpdates() async {
        guard !runtimeBusy else { return }
        let provider = draft.selectedProvider
        let path = draft[provider].executablePath
        runtimeProvider = provider
        var state = runtimeState(for: provider)
        state.lastAttempt = .checkUpdates
        state.operation = .checkingUpdates; state.error = nil; state.outcome = nil
        runtimeStates[provider] = state
        defer { finishRuntimeOperation(provider, path: path) }
        do {
            let latest = try await fetchLatestVersion(provider)
            try Task.checkCancellation()
            guard draft[provider].executablePath == path else { return }
            runtimeStates[provider]?.latestVersion = latest
        } catch {
            recordRuntimeFailure(error, provider: provider, path: path)
        }
    }

    func installRuntime() async {
        guard !runtimeBusy, !ai.running, !checking, !testingConnection else { return }
        let provider = draft.selectedProvider
        let path = draft[provider].executablePath
        runtimeProvider = provider
        runtimeStates[provider] = .init(executablePath: path, operation: .installing(.checkingVersion), latestVersion: runtimeState(for: provider).latestVersion, lastAttempt: .install)
        defer { finishRuntimeOperation(provider, path: draft[provider].executablePath) }
        do {
            let installedPath = try await performRuntimeInstall(provider) { [weak self] stage in
                Task { @MainActor [weak self] in
                    guard let self, self.runtimeProvider == provider, self.draft[provider].executablePath == path,
                          case .installing = self.runtimeStates[provider]?.operation else { return }
                    self.runtimeStates[provider]?.operation = .installing(stage)
                }
            }
            // Installation is committed atomically; keep the resulting path even
            // if cancellation arrived just after activation.
            guard draft[provider].executablePath == path else { return }
            draft[provider].executablePath = installedPath
            runtimeStates[provider] = .init(executablePath: installedPath, outcome: .installed)
            checks.removeValue(forKey: provider); versions.removeValue(forKey: provider)
            try ai.saveProviderSettings(draft)
        } catch {
            recordRuntimeFailure(error, provider: provider, path: draft[provider].executablePath)
        }
    }

    private func recordRuntimeFailure(_ error: Error, provider: NotesAIProvider, path: String) {
        guard draft[provider].executablePath == path, runtimeStates[provider]?.executablePath == path else { return }
        if error is CancellationError || Task.isCancelled {
            runtimeStates[provider]?.outcome = .cancelled
        } else {
            runtimeStates[provider]?.error = error.localizedDescription
        }
    }

    private func finishRuntimeOperation(_ provider: NotesAIProvider, path: String) {
        if runtimeStates[provider]?.executablePath == path { runtimeStates[provider]?.operation = nil }
        runtimeProvider = nil
        runtimeTask = nil
    }

    func chooseExecutable() {
        let provider = draft.selectedProvider
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard FileManager.default.isExecutableFile(atPath: url.path) else {
                    let message = UserDefaults.standard.string(forKey: "notes.language") == "en" ? "Choose an executable file." : "Selecciona un archivo ejecutable."
                    self.runtimeStates[provider] = .init(executablePath: self.draft[provider].executablePath, error: message)
                    return
                }
                self.draft[provider].executablePath = url.path
                self.checks.removeValue(forKey: provider); self.versions.removeValue(forKey: provider)
            }
        }
    }
}
