import SwiftUI
import LectureCore

/// Uses the same artwork, surfaces, spacing and selection treatment as AI providers.
struct TranscriptionLogo: View {
    let provider: TranscriptionProvider
    var size: CGFloat = 26
    var body: some View {
        Group {
            if provider == .openAI { ProviderLogo(provider: .codexCLI, size: size) }
            else {
                Image(systemName: "waveform").font(.system(size: size * 0.64, weight: .medium))
                    .frame(width: size, height: size)
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: size * 0.25))
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct TranscriptionPreferences: View {
    @ObservedObject var media: MediaController
    @State private var key = ""
    @State private var keyStatus: String?
    @State private var showRuntime = false
    @AppStorage("notes.language") private var language = "es"
    @AppStorage("notes.accent") private var accent = ""
    private func t(_ es: String, _ en: String) -> String { language == "en" ? en : es }
    private var locked: Bool { media.busy || media.isRecording || media.modelOperation != nil }
    private func status(_ provider: TranscriptionProvider) -> String {
        if provider == .openAI { return media.hasAPIKey ? t("Clave guardada", "Key saved") : t("Añade tu clave API", "Add your API key") }
        return media.runtimeInstalled && media.installedModels.contains(media.transcriptionModel) ? t("Listo en este Mac", "Ready on this Mac") : t("Requiere instalación", "Setup required")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 8)], spacing: 8) {
                ForEach(TranscriptionProvider.allCases, id: \.self) { provider in
                    let selected = media.transcriptionProvider == provider
                    Button { media.transcriptionProvider = provider; showRuntime = false } label: {
                        HStack(spacing: 10) {
                            TranscriptionLogo(provider: provider, size: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(provider == .local ? "Whisper" : "OpenAI API").font(.callout.weight(.semibold))
                                Text(status(provider)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected ? NotebookAccent.color(accent) : .secondary)
                        }.padding(12).frame(minHeight: 56).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .background(NotebookAccent.color(accent).opacity(selected ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 12))
                            .modifier(NotebookInputSurface(radius: 12, borderOpacity: 0.18))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NotebookAccent.color(accent).opacity(selected ? 0.5 : 0), lineWidth: 1))
                    }.buttonStyle(.plain).disabled(locked)
                        .accessibilityIdentifier("transcription.provider." + provider.rawValue)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    TranscriptionLogo(provider: media.transcriptionProvider, size: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(media.transcriptionProvider == .local ? "Whisper" : "OpenAI API").font(.title3.weight(.semibold))
                        Text(status(media.transcriptionProvider)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { media.refreshTranscription() } label: { Image(systemName: "arrow.clockwise").foregroundStyle(.secondary).frame(width: 32, height: 32) }
                        .buttonStyle(.plain).modifier(ControlHoverBackground()).accessibilityLabel(t("Actualizar estado", "Refresh status"))
                }
                Divider().opacity(0.35)
                Text(media.transcriptionProvider == .local
                     ? t("Dicta sin conexión. El audio se procesa en este Mac.", "Dictate offline. Audio is processed on this Mac.")
                     : t("Dicta con tu cuenta de OpenAI. Se envía audio y se aplican los costes de la API.", "Dictate with your OpenAI account. Audio is uploaded and API charges apply."))
                    .font(.callout).foregroundStyle(.secondary)
                TranscriptionLanguageControl(selection: $media.transcriptionLanguage).disabled(locked)
                Text(t("Audio bajo: se aumenta el nivel antes de transcribir, hasta +18 dB sin saturar. La grabación original se conserva.", "Quiet audio is boosted before transcription, up to +18 dB without clipping. Your original recording is preserved.")).font(.caption).foregroundStyle(.secondary)
                if media.transcriptionProvider == .local { localEditor } else { apiEditor }
                if let operation = media.modelOperation {
                    HStack { if media.modelDownload == nil { ProgressView().controlSize(.small) }; Text(operation).font(.caption); Spacer(); Button(t("Cancelar", "Cancel")) { media.cancelModelOperation() }.buttonStyle(.plain) }
                }
                if let error = media.modelError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(NotebookInputSurface(radius: 14, borderOpacity: 0.22))
            Text(t("El dictado escribe en el borrador del chat. Puedes corregirlo y enviarlo cuando quieras.", "Dictation writes into the chat draft. You can edit it and send it when ready."))
                .font(.caption).foregroundStyle(.secondary)
        }.tint(NotebookAccent.color(accent)).onAppear { media.refreshTranscription() }
    }
    private var apiEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider().opacity(0.35)
            Text(t("Clave API", "API key")).font(.headline)
            SecureField(media.hasAPIKey ? t("Sustituir clave guardada", "Replace saved key") : "sk-…", text: $key)
                .font(.callout).textFieldStyle(.plain).padding(.horizontal, 11).frame(height: 34)
                .modifier(NotebookInputSurface(radius: 9)).accessibilityIdentifier("transcription.apiKey")
                .accessibilityLabel(t("Clave API de OpenAI", "OpenAI API key"))
            HStack {
                Button { saveKey(key) } label: { actionLabel(t("Guardar clave", "Save key"), symbol: "key") }
                    .buttonStyle(.plain).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if media.hasAPIKey {
                    Button(t("Eliminar clave", "Remove key")) { saveKey("") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(t("Se guarda de forma segura en el llavero de macOS.", "Stored securely in macOS Keychain.")).font(.caption).foregroundStyle(.secondary)
            if let keyStatus { Text(keyStatus).font(.caption).foregroundStyle(.secondary) }
            Divider().opacity(0.35)
            Text(t("Modelo", "Model")).font(.headline)
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(NotebookAccent.color(accent))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Whisper API").font(.callout.weight(.medium))
                    Text(t("whisper-1 · segmentos con marcas de tiempo", "whisper-1 · timestamped segments")).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(12).modifier(NotebookInputSurface(radius: 10, borderOpacity: 0.18))
        }.disabled(locked)
    }
    private var localEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            DisclosureGroup(t("Instalación", "Runtime"), isExpanded: $showRuntime) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Whisper.cpp v1.8.2", systemImage: media.runtimeInstalled ? "checkmark.circle" : "cpu").font(.callout)
                        Spacer()
                        Button { media.manageModel(nil) } label: {
                            actionLabel(media.runtimeInstalled ? t("Reinstalar", "Reinstall") : t("Instalar", "Install"), symbol: "arrow.down.circle")
                        }.buttonStyle(.plain)
                    }
                    Text(t("Necesita CMake y las herramientas de Xcode para instalar el motor.", "Requires CMake and Xcode command-line tools to install the runtime.")).font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }.font(.callout.weight(.medium))
            if !media.runtimeInstalled && !showRuntime {
                Button { showRuntime = true } label: { Label(t("Instala el motor para empezar", "Install the runtime to get started"), systemImage: "arrow.down.circle").font(.caption).foregroundStyle(NotebookAccent.color(accent)) }.buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 10) {
                option(t("Usar la GPU", "Use the GPU"), t("Transcribe varias veces más rápido con Metal. Sin ella: dos hilos de CPU, más lento pero con menos carga.", "Transcribes several times faster with Metal. Without it: two CPU threads, slower but lighter on your Mac."), isOn: $media.useGPU, id: "transcription.gpu")
                option(t("Detener al dejar de hablar", "Stop when you stop speaking"), t("El dictado termina solo tras unos segundos de silencio.", "Dictation ends by itself after a few seconds of silence."), isOn: $media.stopOnSilence, id: "transcription.stopOnSilence")
            }
            Divider().opacity(0.35)
            HStack { Text(t("Modelos", "Models")).font(.headline); Text("3").font(.caption).foregroundStyle(.secondary); Spacer() }
            VStack(spacing: 0) {
                ForEach(WhisperModel.allCases, id: \.self) { model in
                    modelRow(model)
                    if model != WhisperModel.allCases.last { Divider().opacity(0.4) }
                }
            }.clipShape(RoundedRectangle(cornerRadius: 10)).modifier(NotebookInputSurface(radius: 10, borderOpacity: 0.18))
            Text(t("Descarga una vez para usar sin conexión. Las actualizaciones se verifican antes de sustituir el modelo instalado.", "Download once to use offline. Updates are verified before replacing the installed model.")).font(.caption).foregroundStyle(.secondary)
        }.disabled(locked)
    }
    private func modelRow(_ model: WhisperModel) -> some View {
        let selected = media.transcriptionModel == model
        let installed = media.installedModels.contains(model)
        return HStack(spacing: 10) {
            Button { media.transcriptionModel = model } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? NotebookAccent.color(accent) : .secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.displayName).font(.callout.weight(.medium)).foregroundStyle(.primary)
                        if let download = media.modelDownload, download.model == model {
                            ProgressView(value: download.progress.fraction).progressViewStyle(.linear).tint(NotebookAccent.color(accent))
                                .accessibilityIdentifier("transcription.download." + model.rawValue)
                            Text(Self.describe(download.progress, language: language)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        } else {
                            Text((model == .small ? "488 MB" : model == .medium ? "1.53 GB" : "1.62 GB") + " · " + (installed ? t("Instalado", "Installed") : t("Sin descargar", "Not downloaded")))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(t("Elegir ", "Select ") + model.displayName)
                .accessibilityIdentifier("transcription.model." + model.rawValue)
            if media.modelDownload?.model == model { EmptyView() } else if installed {
                Button { media.manageModel(model) } label: { Image(systemName: "arrow.clockwise").foregroundStyle(.secondary).frame(width: 26, height: 26) }
                    .buttonStyle(.plain).modifier(ControlHoverBackground()).help(t("Actualizar modelo", "Update model")).accessibilityLabel(t("Actualizar ", "Update ") + model.displayName)
                Menu { Button(t("Desinstalar modelo", "Uninstall model")) { media.manageModel(model, remove: true) } }
                    label: { Image(systemName: "ellipsis").foregroundStyle(.secondary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(t("Opciones de ", "Options for ") + model.displayName)
            } else {
                Button { media.manageModel(model) } label: { actionLabel(t("Descargar", "Download"), symbol: "arrow.down") }
                    .buttonStyle(.plain)
            }
        }.padding(.horizontal, 12).padding(.vertical, 10)
            .background(NotebookAccent.color(accent).opacity(selected ? 0.08 : 0))
    }
    /// "312 MB de 488 MB · 64 %", or the verification step once everything has arrived.
    static func describe(_ progress: DownloadProgress, language: String) -> String {
        let english = language == "en"
        if progress.total > 0, progress.received >= progress.total { return english ? "Verifying…" : "Verificando…" }
        let formatter = ByteCountFormatter(); formatter.countStyle = .file; formatter.allowedUnits = [.useMB, .useGB]
        let received = formatter.string(fromByteCount: progress.received)
        guard progress.total > 0 else { return received }
        return received + (english ? " of " : " de ") + formatter.string(fromByteCount: progress.total) + " · " + String(Int(progress.fraction * 100)) + " %"
    }
    private func option(_ title: String, _ detail: String, isOn: Binding<Bool>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn).modifier(NotebookToggleAccent(switchStyle: true)).accessibilityIdentifier(id)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func actionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.callout).foregroundStyle(NotebookAccent.color(accent))
            .padding(.horizontal, 10).frame(height: 32).modifier(NotebookInputSurface(radius: 8))
    }
    private func saveKey(_ value: String) {
        do { try TranscriptionKeychain.save(value); key = ""; media.refreshTranscription(); keyStatus = t("Llavero actualizado", "Keychain updated") }
        catch { keyStatus = error.localizedDescription }
    }
}

struct TranscriptionLanguageControl: View {
    @Binding var selection: String
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        AIOptionSelector(title: language == "en" ? "Audio language" : "Idioma del audio", symbol: "globe", options: [
            .init(id: "es", title: "Español"), .init(id: "ca", title: "Català / Valencià"), .init(id: "en", title: "English"),
            .init(id: "auto", title: language == "en" ? "Detect automatically" : "Detectar automáticamente")
        ], selection: $selection).accessibilityIdentifier("transcription.language")
    }
}

struct TranscriptionProviderPicker: View {
    @Binding var selection: TranscriptionProvider
    @State private var presented = false
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 7) {
                TranscriptionLogo(provider: selection, size: 18)
                Text(selection.title).font(.callout)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 9).frame(height: 34).modifier(NotebookInputSurface(radius: 7))
        }.buttonStyle(.plain).accessibilityLabel(language == "en" ? "Transcription provider" : "Proveedor de transcripción")
            .popover(isPresented: $presented) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(language == "en" ? "Transcription" : "Transcripción").font(.caption).foregroundStyle(.secondary).padding(8)
                    ForEach(TranscriptionProvider.allCases, id: \.self) { provider in
                        Button { selection = provider; presented = false } label: {
                            HStack(spacing: 10) {
                                TranscriptionLogo(provider: provider, size: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(provider.title).font(.callout.weight(.medium))
                                    Text(provider == .local ? (language == "en" ? "On this Mac" : "En este Mac") : (language == "en" ? "Uses your API key" : "Usa tu clave API")).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selection == provider { Image(systemName: "checkmark").font(.caption) }
                            }.padding(10).contentShape(Rectangle()).modifier(SelectorRowBackground(highlighted: selection == provider))
                        }.buttonStyle(.plain)
                    }
                }.padding(5).frame(width: 240).background(Color(nsColor: .windowBackgroundColor))
            }
    }
}

struct TranscriptionChoices: View {
    @ObservedObject var media: MediaController
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TranscriptionProviderPicker(selection: $media.transcriptionProvider)
            if media.transcriptionProvider == .local {
                AIOptionSelector(title: language == "en" ? "Local model" : "Modelo local", symbol: "waveform", options: WhisperModel.allCases.map { .init(id: $0.rawValue, title: $0.displayName) }, selection: Binding(get: { media.transcriptionModel.rawValue }, set: { if let model = WhisperModel(rawValue: $0) { media.transcriptionModel = model } }))
            } else { Text(language == "en" ? "whisper-1 · audio is uploaded to OpenAI" : "whisper-1 · se envía el audio a OpenAI").font(.caption).foregroundStyle(.secondary) }
            TranscriptionLanguageControl(selection: $media.transcriptionLanguage)
            if !media.available(for: nil) { Text(language == "en" ? "Set up your model or API key in Preferences → Dictation." : "Configura el modelo o la clave API en Preferencias → Dictado.").font(.caption).foregroundStyle(.orange) }
        }.disabled(media.busy || media.isRecording || media.modelOperation != nil)
    }
}
