import SwiftUI
import LectureCore

/// A labelled setting in the provider editor: caption, field and optional help.
private struct ProviderField<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder let control: Control
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            control
            if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private struct ProviderTextField: View {
    let title: String
    var detail: String? = nil
    var placeholder: String? = nil
    @Binding var value: String
    let identifier: String
    var monospaced = false
    var body: some View {
        ProviderField(title: title, detail: detail) {
            TextField(placeholder ?? title, text: $value).font(monospaced ? .callout.monospaced() : .callout).textFieldStyle(.plain)
                .padding(.horizontal, 11).frame(height: 34).modifier(NotebookInputSurface(radius: 9))
                .accessibilityLabel(title).accessibilityIdentifier(identifier)
        }
    }
}

/// Write-only entry for a Keychain secret. The stored value is never shown.
private struct ProviderSecretField: View {
    let placeholder: String
    let stored: Bool
    let identifier: String
    let save: (String) -> Void
    @State private var value = ""
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        HStack(spacing: 6) {
            SecureField(stored ? (language == "en" ? "Stored in Keychain" : "Guardado en el llavero") : placeholder, text: $value)
                .font(.callout).textFieldStyle(.plain).onSubmit(commit)
                .accessibilityIdentifier(identifier)
            if !value.isEmpty {
                Button(language == "en" ? "Save" : "Guardar", action: commit).buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(.tint)
            } else if stored {
                Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    .help(language == "en" ? "Stored in macOS Keychain" : "Guardado en el llavero de macOS")
            }
        }.padding(.horizontal, 11).frame(height: 34).modifier(NotebookInputSurface(radius: 9))
    }
    private func commit() {
        guard !value.isEmpty else { return }
        save(value); value = ""
    }
}

/// Display name and color: what tells this provider apart in lists and pickers.
struct ProviderIdentityFields: View {
    @ObservedObject var preferences: ProviderPreferencesModel
    @AppStorage("notes.language") private var language = "es"
    private func text(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    var body: some View {
        ProviderField(title: text("Nombre visible", "Display name")) {
            HStack(spacing: 10) {
                TextField(preferences.draft.selectedProvider.shortName, text: preferences.option(\.displayName))
                    .font(.callout).textFieldStyle(.plain)
                    .padding(.horizontal, 11).frame(height: 34).modifier(NotebookInputSurface(radius: 9))
                    .accessibilityLabel(text("Nombre visible", "Display name")).accessibilityIdentifier("provider.display-name")
                HStack(spacing: 5) {
                    swatch(nil)
                    ForEach(ProviderAccent.presets, id: \.self) { swatch($0) }
                }
            }
        }
    }
    private func swatch(_ hex: String?) -> some View {
        let selected = preferences.draft.selected.accentColor == hex
        return Button { preferences.draft.selected.accentColor = hex } label: {
            ZStack {
                if let color = hex.flatMap(ProviderAccent.color) { Circle().fill(color) }
                else { Image(systemName: "circle.slash").font(.system(size: 13)).foregroundStyle(.secondary) }
            }.frame(width: 16, height: 16).padding(3)
                .overlay(Circle().strokeBorder(Color.primary.opacity(selected ? 0.55 : 0), lineWidth: 1.5))
        }.buttonStyle(.plain)
            .help(hex == nil ? text("Sin color", "No color") : text("Color del proveedor", "Provider color"))
            .accessibilityLabel(hex ?? text("Sin color", "No color"))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Account paths and launch options for an existing provider installation.
struct ProviderRuntimeFields: View {
    @ObservedObject var preferences: ProviderPreferencesModel
    @AppStorage("notes.language") private var language = "es"
    private func text(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    private var provider: NotesAIProvider { preferences.draft.selectedProvider }

    /// Installation paths reset the check; `~/` expands to the home directory.
    private func path(_ keyPath: WritableKeyPath<AIProviderConfiguration, String>) -> Binding<String> {
        Binding(get: { preferences.draft.selected[keyPath: keyPath] }, set: { updated in
            preferences.draft.selected[keyPath: keyPath] = Self.expand(updated)
            preferences.invalidateSelection()
        })
    }
    private static func expand(_ value: String) -> String {
        value.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.path + String(value.dropFirst(1)) : value
    }
    private var shadowHome: Binding<String> {
        Binding(get: { preferences.draft.selected.shadowHomePath ?? "" }, set: { updated in
            preferences.draft.selected.shadowHomePath = updated.isEmpty ? nil : Self.expand(updated)
            preferences.invalidateSelection()
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if provider == .antigravity { antigravityAccount }
            ProviderTextField(title: text("Ruta del ejecutable", "Binary path"), detail: binaryDetail, value: path(\.executablePath), identifier: "provider.executable", monospaced: true)
            if provider != .openCode {
                ProviderTextField(title: text("Panel de CLIProxyAPI (opcional)", "CLIProxyAPI dashboard (optional)"), detail: text("Para consultar los límites de las cuentas del proxy. Déjalo vacío para detectar el panel local predeterminado.", "Reads the proxy's account limits. Leave empty to detect the default local dashboard."), placeholder: "http://127.0.0.1:8318", value: preferences.option(\.proxyUsageURL), identifier: "provider.proxy-usage-url", monospaced: true)
            }
            switch provider {
            case .codexCLI:
                ProviderTextField(title: text("Ruta de CODEX_HOME", "CODEX_HOME path"), detail: text("Carpeta de configuración e inicio de sesión de Codex.", "Custom Codex home and config directory."), placeholder: "~/.codex", value: path(\.homePath), identifier: "provider.profile", monospaced: true)
                ProviderTextField(title: text("Ruta de la cuenta (shadow home)", "Shadow home path"), detail: text("Carpeta de Codex propia de una cuenta. Mantiene su auth.json separado de CODEX_HOME.", "Account-specific Codex home. Keeps auth.json separate from CODEX_HOME."), placeholder: "~/.codex-personal", value: shadowHome, identifier: "provider.shadow-home", monospaced: true)
                launchArguments(placeholder: "--config model_verbosity=\"low\"", detail: text("Opciones --config, --enable y --disable adicionales. Las opciones de aislamiento de Palladium tienen prioridad.", "Extra --config, --enable and --disable options. Palladium's isolation options take precedence."))
            case .claudeCode:
                ProviderTextField(title: text("Ruta de CLAUDE_CONFIG_DIR", "CLAUDE_CONFIG_DIR path"), detail: text("Carpeta de configuración de otra cuenta de Claude. Déjala vacía para usar la predeterminada.", "Custom Claude config directory for another account. Leave empty to use Claude Code's default."), placeholder: "~/.claude", value: path(\.homePath), identifier: "provider.profile", monospaced: true)
                ProviderTextField(title: text("Compactar automáticamente tras", "Auto-compact after"), detail: text("Compacta entre 100.000 y 1.000.000 de tokens. Déjalo vacío para el valor de Claude.", "Compact after 100,000 to 1,000,000 tokens. Leave empty to use Claude's default."), placeholder: text("p. ej. 300000", "e.g. 300000"), value: preferences.option(\.autoCompactWindow), identifier: "provider.auto-compact", monospaced: true)
                launchArguments(placeholder: "--fallback-model sonnet", detail: text("Argumentos adicionales de la CLI. Palladium gestiona el modelo, las herramientas, los permisos y el formato de salida.", "Additional CLI arguments. Palladium manages the model, tools, permissions and output format."))
            case .antigravity:
                ProviderTextField(title: text("Carpeta del perfil", "Profile folder"), detail: text("GEMINI_HOME del agente; contiene el inicio de sesión.", "The agent's GEMINI_HOME; holds the sign-in."), value: path(\.homePath), identifier: "provider.profile", monospaced: true)
                ProviderTextField(title: "localharness_external", value: path(\.harnessPath), identifier: "provider.harness", monospaced: true)
            case .openCode: EmptyView()
            }
            Button { preferences.detectInstallation() } label: {
                Label(text("Detectar instalación", "Detect installation"), systemImage: "magnifyingglass")
                    .font(.callout).padding(.horizontal, 10).frame(height: 32)
                    .modifier(NotebookInputSurface(radius: 8))
            }.buttonStyle(.plain)
            Button { preferences.chooseExecutable() } label: {
                Label(text("Elegir ejecutable…", "Choose executable…"), systemImage: "folder")
                    .font(.callout).padding(.horizontal, 10).frame(height: 32)
                    .modifier(NotebookInputSurface(radius: 8))
            }.buttonStyle(.plain).accessibilityIdentifier("provider.executable.choose")
            if ProviderRuntime.supportsInstallation(provider), !ProviderRuntime.isManaged(preferences.draft.selected) {
                Button { preferences.startRuntimeInstallation() } label: {
                    Label(text("Configurar instalación en Palladium", "Set up an installation in Palladium"), systemImage: "arrow.down.circle")
                        .font(.callout).foregroundStyle(.tint)
                }.buttonStyle(.plain).accessibilityIdentifier("provider.runtime.use-managed")
                Text(text("Descarga una instalación independiente y úsala para este proveedor.", "Download a separate installation and use it for this provider."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.font(.callout.weight(.regular))
    }

    private var binaryDetail: String {
        switch provider {
        case .codexCLI: text("Binario de Codex que usa este proveedor.", "Path to the Codex binary used by this provider.")
        case .claudeCode: text("Binario de Claude que usa este proveedor.", "Path to the Claude binary used by this provider.")
        case .antigravity: text("Ejecutable ACP de Antigravity.", "The Antigravity ACP executable.")
        case .openCode: text("Binario de OpenCode.", "Path to the OpenCode binary.")
        }
    }

    private func launchArguments(placeholder: String, detail: String) -> some View {
        ProviderTextField(title: text("Argumentos de lanzamiento", "Launch arguments"), detail: detail, placeholder: placeholder, value: preferences.option(\.launchArguments), identifier: "provider.launch-arguments", monospaced: true)
    }

    @ViewBuilder private var antigravityAccount: some View {
        let method = preferences.draft.selected.antigravityAuth
        ProviderField(title: text("Método de inicio de sesión", "Sign-in method"), detail: text("Las cuentas de Google usan tu suscripción; las claves de API y Agent Platform facturan el uso.", "Google accounts use your subscription; API keys and Agent Platform bill usage.")) {
            AIOptionSelector(title: text("Método de inicio de sesión", "Sign-in method"), symbol: "person.crop.circle", options: [
                .init(id: AntigravityAuthMethod.personal.rawValue, title: text("Cuenta de Google", "Google account")),
                .init(id: AntigravityAuthMethod.business.rawValue, title: "Gemini Enterprise"),
                .init(id: AntigravityAuthMethod.apiKey.rawValue, title: text("Clave de API de Gemini", "Gemini API key")),
                .init(id: AntigravityAuthMethod.agentPlatform.rawValue, title: "Agent Platform (Vertex AI)")
            ], selection: Binding(get: { method.rawValue }, set: { preferences.draft.selected.authMethod = $0 == AntigravityAuthMethod.personal.rawValue ? nil : $0 }))
                .accessibilityIdentifier("provider.auth-method")
        }
        if method == .apiKey || method == .agentPlatform {
            ProviderField(title: text("Clave de API", "API key"), detail: text("Clave de Gemini o de Vertex AI express. Se guarda en el llavero de macOS.", "Gemini or Vertex AI express key. Stored in macOS Keychain.")) {
                HStack(spacing: 8) {
                    ProviderSecretField(placeholder: method == .agentPlatform ? text("Opcional", "Optional") : text("Clave de API", "API key"), stored: preferences.hasSecret(ProviderSecrets.antigravityAPIKey), identifier: "provider.api-key") {
                        preferences.saveSecret($0, name: ProviderSecrets.antigravityAPIKey)
                    }
                    if preferences.hasSecret(ProviderSecrets.antigravityAPIKey) {
                        Button { preferences.saveSecret("", name: ProviderSecrets.antigravityAPIKey) } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).frame(width: 28, height: 28).modifier(ControlHoverBackground())
                            .help(text("Eliminar la clave", "Remove key")).accessibilityLabel(text("Eliminar la clave", "Remove key"))
                    }
                }
            }
        }
        if method == .business || method == .agentPlatform {
            ProviderTextField(title: text("Proyecto de GCP", "GCP project"), detail: text("Obligatorio en Gemini Enterprise. Agent Platform lo usa cuando no hay clave de API.", "Required for Gemini Enterprise. Agent Platform uses it when no API key is set."), placeholder: "my-project-id", value: preferences.option(\.gcpProject), identifier: "provider.gcp-project", monospaced: true)
            ProviderTextField(title: text("Región de GCP", "GCP location"), detail: text("Región de Gemini Enterprise o Agent Platform.", "Region for Gemini Enterprise or Agent Platform."), placeholder: "us-central1", value: preferences.option(\.gcpLocation), identifier: "provider.gcp-location", monospaced: true)
        }
    }
}

/// Per-provider variables: API keys, base URLs and other CLI settings.
struct ProviderEnvironmentFields: View {
    @ObservedObject var preferences: ProviderPreferencesModel
    @State private var name = ""
    @State private var value = ""
    @State private var sensitive = false
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    private func text(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    private var variables: [AIProviderEnvironmentVariable] { preferences.draft.selected.environment ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text("Claves de API, URL base y otros ajustes de la CLI de este proveedor.", "API keys, base URLs, and other CLI settings for this provider."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(variables) { variable in
                HStack(spacing: 8) {
                    Text(variable.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        .frame(width: 190, alignment: .leading)
                    if variable.sensitive {
                        ProviderSecretField(placeholder: text("Valor", "Value"), stored: preferences.hasSecret(ProviderSecrets.environmentName(variable.name)), identifier: "provider.environment.value." + variable.name) {
                            preferences.setVariable(variable.name, value: $0)
                        }
                    } else {
                        TextField(text("Valor (vacío permitido)", "Value (may be empty)"), text: Binding(get: { variable.value }, set: { preferences.setVariable(variable.name, value: $0) }))
                            .font(.callout.monospaced()).textFieldStyle(.plain)
                            .padding(.horizontal, 11).frame(height: 34).modifier(NotebookInputSurface(radius: 9))
                            .accessibilityIdentifier("provider.environment.value." + variable.name)
                    }
                    Image(systemName: variable.sensitive ? "lock.fill" : "lock.open").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .help(variable.sensitive ? text("Sensible, guardado en el llavero", "Sensitive, stored in Keychain") : text("Texto sin cifrar", "Plain text"))
                    Button { preferences.removeVariable(variable.name) } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).frame(width: 28, height: 28).modifier(ControlHoverBackground())
                        .help(text("Eliminar variable", "Remove variable"))
                        .accessibilityLabel(text("Eliminar ", "Remove ") + variable.name)
                }
            }
            HStack(spacing: 8) {
                TextField("VARIABLE_NAME", text: $name).font(.callout.monospaced()).textFieldStyle(.plain)
                    .padding(.horizontal, 11).frame(width: 190, height: 34).modifier(NotebookInputSurface(radius: 9))
                    .accessibilityIdentifier("provider.environment.name")
                Group {
                    if sensitive { SecureField(text("Valor", "Value"), text: $value) }
                    else { TextField(text("Valor", "Value"), text: $value) }
                }.font(.callout.monospaced()).textFieldStyle(.plain).onSubmit(add)
                    .padding(.horizontal, 11).frame(height: 34).modifier(NotebookInputSurface(radius: 9))
                    .accessibilityIdentifier("provider.environment.new-value")
                Button { sensitive.toggle() } label: {
                    Image(systemName: sensitive ? "lock.fill" : "lock.open").font(.caption)
                        .foregroundStyle(sensitive ? NotebookAccent.color(accent) : .secondary)
                }.buttonStyle(.plain).frame(width: 28, height: 28).modifier(ControlHoverBackground())
                    .help(sensitive ? text("Sensible, se guardará en el llavero", "Sensitive, will be stored in Keychain") : text("Marcar como sensible", "Mark as sensitive"))
                    .accessibilityLabel(text("Sensible", "Sensitive")).accessibilityAddTraits(sensitive ? .isSelected : [])
                    .accessibilityIdentifier("provider.environment.sensitive")
                Button(action: add) {
                    Image(systemName: "plus").foregroundStyle(.secondary)
                }.buttonStyle(.plain).frame(width: 28, height: 28).modifier(ControlHoverBackground())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help(text("Añadir variable", "Add variable")).accessibilityLabel(text("Añadir variable", "Add variable"))
                    .accessibilityIdentifier("provider.environment.add")
            }
        }.font(.callout.weight(.regular))
            .onChange(of: preferences.draft.selectedProvider) { _, _ in name = ""; value = ""; sensitive = false }
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, preferences.addVariable(name: trimmed, value: value, sensitive: sensitive) else { return }
        name = ""; value = ""; sensitive = false
    }
}
