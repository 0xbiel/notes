import SwiftUI
import LectureCore

/// The next setup action stays visible; file paths live in the advanced editor.
struct ProviderInstallationView: View {
    @ObservedObject var preferences: ProviderPreferencesModel
    var showAdvanced: () -> Void
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    private func text(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    private var provider: NotesAIProvider { preferences.draft.selectedProvider }
    private var configuration: AIProviderConfiguration { preferences.draft.selected }
    private var state: ProviderRuntimeState { preferences.runtimeState(for: provider) }
    private var installed: Bool { ProviderRuntime.isInstalled(configuration) }
    private var managed: Bool { ProviderRuntime.isManaged(configuration) }
    private var supported: Bool { ProviderRuntime.supportsInstallation(provider) }
    private var locked: Bool { preferences.runtimeBusy || preferences.checking || preferences.testingConnection || preferences.ai.running }
    private var updateAvailable: Bool { preferences.updateAvailable(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: state.error != nil ? "exclamationmark.circle" : (installed ? "checkmark.circle" : "arrow.down.circle"))
                    .font(.system(size: 17)).foregroundStyle(state.error != nil ? Color.orange : NotebookAccent.color(accent))
                    .frame(width: 22, height: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        Text(title).font(.callout.weight(.medium))
                        if installed, let version = preferences.installedVersion(for: provider) {
                            Text(version).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            if let operation = state.operation {
                operationView(operation)
            } else {
                actions
                if let error = state.error {
                    Label(NotebookAssistantText.display(error, language: language), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("provider.runtime.error")
                } else if state.outcome == .cancelled {
                    Text(text("Operación cancelada. Puedes volver a intentarlo cuando quieras.", "Cancelled. You can try again whenever you're ready."))
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("provider.runtime.cancelled")
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(NotebookInputSurface(radius: 10, borderOpacity: 0.18))
            .accessibilityIdentifier("provider.runtime")
    }

    private var title: String {
        if case .installing = state.operation { return text("Preparando ", "Preparing ") + configuration.name }
        if state.error != nil { return state.lastAttempt == .checkUpdates ? text("No se pudieron buscar actualizaciones", "Couldn't check for updates") : text("No se pudo completar la instalación", "Couldn't complete setup") }
        if updateAvailable { return text("Actualización disponible", "Update available") }
        if installed { return managed ? text("Instalado en Palladium", "Installed in Palladium") : text("Instalación propia", "Custom installation") }
        return supported && managed ? text("Configura ", "Set up ") + configuration.name : text("Conecta tu instalación", "Connect your installation")
    }

    private var detail: String {
        if state.operation != nil { return text("Puedes seguir explorando los otros proveedores.", "You can keep browsing the other providers.") }
        if state.error != nil {
            return installed ? text("Tu instalación actual sigue disponible.", "Your current installation is still available.") : text("Vuelve a intentarlo o elige una instalación existente.", "Try again or choose an existing installation.")
        }
        if updateAvailable, let latest = state.latestVersion {
            return text("La versión ", "Version ") + latest + text(" está lista para instalar.", " is ready to install.")
        }
        if installed {
            if let latest = state.latestVersion {
                if let current = preferences.installedVersion(for: provider), latest.compare(current, options: .numeric) != .orderedDescending {
                    return text("Tienes la versión más reciente.", "You're up to date.")
                }
                return text("Última versión disponible: ", "Latest release: ") + latest
            }
            if state.outcome == .installed { return text("Instalación completada. Ya puedes cargar modelos y probar la conexión.", "Installation complete. You can load models and test the connection.") }
            return managed ? text("Palladium gestiona la instalación y sus actualizaciones.", "Palladium manages this installation and its updates.") : text("Usa el programa que has elegido. Puedes cambiarlo en los ajustes avanzados.", "Uses the program you've chosen. You can change it in advanced settings.")
        }
        if !supported { return text("Selecciona Antigravity ACP y configura tu perfil para empezar.", "Choose Antigravity ACP and set up your profile to get started.") }
        if !managed { return text("No se encuentra el ejecutable seleccionado. Elige otro o configura una instalación en Palladium.", "The selected executable wasn't found. Choose another or set up an installation in Palladium.") }
        return text("Descarga lo necesario para empezar. Se guarda en la carpeta de Palladium.", "Download what you need to get started. Everything stays in Palladium's folder.")
    }

    @ViewBuilder private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 8) { actionButtons }
        }.disabled(locked)
    }

    @ViewBuilder private var actionButtons: some View {
        if supported, !installed || managed && updateAvailable || state.error != nil && state.lastAttempt == .install {
            Button { preferences.startRuntimeInstallation() } label: {
                actionLabel(state.error != nil ? text("Reintentar", "Try again") : (installed ? text("Actualizar", "Update") : text("Descargar e instalar", "Download & install")), symbol: installed ? "arrow.triangle.2.circlepath" : "arrow.down")
            }.buttonStyle(.plain).accessibilityIdentifier("provider.runtime.install")
        }
        if installed, supported {
            Button { preferences.startUpdateCheck() } label: {
                actionLabel(text("Buscar actualizaciones", "Check for updates"), symbol: "arrow.clockwise", primary: false)
            }.buttonStyle(.plain).accessibilityIdentifier("provider.runtime.check-updates")
        }
        if !installed {
            Button {
                if supported { preferences.chooseExecutable() } else { showAdvanced() }
            } label: {
                actionLabel(supported ? text("Usar instalación existente…", "Use existing installation…") : text("Configurar instalación…", "Configure installation…"), symbol: "folder", primary: !supported)
            }.buttonStyle(.plain).accessibilityIdentifier("provider.runtime.choose")
        }
        if installed && !managed {
            Button(action: showAdvanced) {
                actionLabel(text("Gestionar…", "Manage…"), symbol: "slider.horizontal.3", primary: false)
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private func operationView(_ operation: ProviderRuntimeState.Operation) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(operationTitle(operation)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("provider.runtime.stage")
                Spacer(minLength: 8)
                Button(text("Cancelar", "Cancel")) { preferences.cancelRuntimeOperation() }
                    .font(.caption).buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityIdentifier("provider.runtime.cancel")
            }
            if case .installing(.downloadingRuntime(let progress)) = operation, progress.total > 0 {
                ProgressView(value: progress.fraction).progressViewStyle(.linear).tint(NotebookAccent.color(accent))
                    .accessibilityLabel(text("Descargando componentes", "Downloading components"))
                    .accessibilityIdentifier("provider.runtime.download-progress")
                Text(TranscriptionPreferences.describe(progress, language: language))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func operationTitle(_ operation: ProviderRuntimeState.Operation) -> String {
        switch operation {
        case .checkingUpdates: text("Buscando actualizaciones…", "Checking for updates…")
        case .installing(.checkingVersion): text("Buscando la última versión…", "Finding the latest version…")
        case .installing(.downloadingRuntime): text("Descargando componentes…", "Downloading components…")
        case .installing(.verifyingRuntime): text("Verificando la descarga…", "Verifying the download…")
        case .installing(.installingPackage(let version)): text("Instalando la versión ", "Installing version ") + version + "…"
        case .installing(.verifyingInstallation): text("Comprobando la instalación…", "Checking the installation…")
        }
    }

    private func actionLabel(_ title: String, symbol: String, primary: Bool = true) -> some View {
        Label(title, systemImage: symbol).font(.callout).foregroundStyle(primary ? NotebookAccent.color(accent) : .secondary)
            .padding(.horizontal, 10).frame(height: 32).modifier(NotebookInputSurface(radius: 8))
            .fixedSize(horizontal: true, vertical: false)
    }
}
